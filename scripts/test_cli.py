#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: Sources/Core/*.swift, Sources/cli/main.swift, Tests/CliTests/make_status/main.swift.
# Output: Builds molemonitor-cli in a temp directory, runs it on fixed data directories, checks output,
#         exit codes, read-only behaviour and timing; non-zero exit code means failure.
# Pos: Local check for the CLI (works on Linux and macOS).
from datetime import datetime, timedelta, timezone
from pathlib import Path
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
failures = 0
checks = 0


def find_compiler():
    env = os.environ.get("SWIFTC")
    if env:
        return env
    local = Path.home() / ".local/bin/swiftc-local"
    if local.exists():
        return str(local)
    found = shutil.which("swiftc")
    if found:
        return found
    sys.exit("No Swift compiler found: set SWIFTC, install swiftc-local, or install swiftc.")


def check(cond, msg):
    global failures, checks
    checks += 1
    if not cond:
        failures += 1
        print(f"FAIL: {msg}")


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def snapshot(d):
    out = {}
    for p in sorted(Path(d).rglob("*")):
        st = p.stat()
        h = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "dir"
        out[str(p.relative_to(d))] = (h, st.st_mtime_ns)
    return out


def dead_pid():
    pid = 4000000
    while True:
        try:
            os.kill(pid, 0)
            pid += 1
        except ProcessLookupError:
            return pid
        except PermissionError:
            pid += 1


GB = 10**9
TOTAL = 1000 * GB


def write_samples(d, now):
    """200 -> 150 -> 450 GB within 5 days, one reboot, one corrupt line."""
    boot1 = now - timedelta(days=9)
    boot2 = now - timedelta(days=2)
    pts = [(4.8 * 24, 200, 1000, 100, boot1), (4.0 * 24, 200, 2000, 200, boot1), (3.0 * 24, 150, 3000, 300, boot1),
           (2.5 * 24, 150, 4000, 400, boot1), (1.5 * 24, 160, 500, 50, boot2), (6, 300, 900, 90, boot2),
           (3, 450, 1300, 130, boot2), (0.2, 450, 1500, 150, boot2)]
    lines = {}
    for hours, used, rx, tx, boot in pts:
        t = now - timedelta(hours=hours)
        row = {"v": 1, "t": iso(t), "src": "timer", "ok": True, "vol": "/System/Volumes/Data", "total": TOTAL,
               "avail_important": TOTAL - used * GB, "avail": TOTAL - used * GB - 5 * GB, "used": used * GB,
               "net_rx": rx * 10**6, "net_tx": tx * 10**6, "boot": iso(boot)}
        lines.setdefault(t.strftime("%Y-%m"), []).append(json.dumps(row))
    key = (now - timedelta(hours=3)).strftime("%Y-%m")
    lines[key].insert(1, "{broken json")
    Path(d).mkdir(parents=True, exist_ok=True)
    for month, rows in lines.items():
        Path(d, f"disk-{month}.ndjson").write_text("\n".join(rows) + "\n")


def measured(value, at, unit="bytes", status="ok"):
    return {"value": value, "unit": unit, "status": status, "sampled_at": iso(at) if at else None}


def write_status(d, now, written_at, pid):
    at = now - timedelta(minutes=12)
    growth = lambda w, b, n: {"window": w, "bytes": b, "net_bytes": n, "from_min_at": iso(now - timedelta(days=2)),
                              "covered_hours": 115.0, "status": "ok"}
    doc = {
        "schema_version": 1, "app_version": "0.2.0", "written_at": iso(written_at), "writer_pid": pid,
        "overall": {"level": "yellow", "summary": "手写的旧状态"},
        "items": {
            "disk": {"level": "yellow", "reason_code": "growth_5d", "reason": "旧原因", "since": iso(at),
                     "level_changed_at": iso(at), "volume": "/System/Volumes/Data",
                     "total": measured(TOTAL, at), "used": measured(400 * GB, at),
                     "available_important": measured(600 * GB, at), "available_now": measured(595 * GB, at),
                     "purgeable_estimate": measured(5 * GB, at),
                     "growth": {"1d": growth("1d", 10 * GB, 10 * GB), "5d": growth("5d", 100 * GB, 90 * GB)},
                     "history_days": 5.0, "last_sample_at": iso(at)},
            "network": {"traffic": {"today": {"rx": 1, "tx": 2, "covered_hours": 5.0, "status": "ok"},
                                    "5d": {"rx": 3, "tx": 4, "covered_hours": 100.0, "status": "ok"}},
                        "note": "物理网卡合计，不含 VPN 隧道"},
        },
        "active_alerts": [], "notifications": {"authorization": "authorized"},
    }
    Path(d).mkdir(parents=True, exist_ok=True)
    Path(d, "status.json").write_text(json.dumps(doc, ensure_ascii=False, indent=2))


def main():
    compiler = find_compiler()
    print(f"Compiler: {compiler}", flush=True)
    core = sorted(str(p) for p in (root / "Sources/Core").glob("*.swift"))
    cli_main = root / "Sources/cli/main.swift"
    helper = root / "Tests/CliTests/make_status/main.swift"
    if not core or not cli_main.exists() or not helper.exists():
        sys.exit("CLI sources not found.")
    with tempfile.TemporaryDirectory(prefix="molemonitor-cli-") as tmp:
        tmp = Path(tmp)
        cli = tmp / "molemonitor-cli"
        mk = tmp / "make-status"
        for out, extra in ((cli, cli_main), (mk, helper)):
            b = subprocess.run([compiler, *core, str(extra), "-o", str(out)])
            if b.returncode != 0:
                sys.exit(f"Compile failed for {out.name} with exit code {b.returncode}.")

        def run(data_dir, *args):
            env = dict(os.environ, MOLEMONITOR_DATA_DIR=str(data_dir))
            return subprocess.run([str(cli), *args], capture_output=True, text=True, env=env)

        now = datetime.now(timezone.utc).replace(microsecond=0)
        me = os.getpid()

        # 1. Fresh status: alive pid, 30 s old.
        d_fresh = tmp / "fresh"
        write_samples(d_fresh, now)
        write_status(d_fresh, now, now - timedelta(seconds=30), me)
        before = snapshot(d_fresh)
        r = run(d_fresh, "--status")
        check(r.returncode == 0, f"fresh exit code 0 (got {r.returncode})")
        j = json.loads(r.stdout)
        for k in ("schema_version", "app_version", "written_at", "writer_pid", "overall", "items", "active_alerts",
                  "notifications", "read_at", "age_seconds", "app_running", "fresh", "recomputed"):
            check(k in j, f"fresh --status has key {k}")
        check(j["fresh"] is True and j["app_running"] is True and j["recomputed"] is False, "fresh flags")
        check(0 <= j["age_seconds"] < 120, f"age_seconds sane ({j['age_seconds']})")
        check(j["overall"]["summary"] == "手写的旧状态", "fresh output keeps status.json content")
        check(j["items"]["disk"]["growth"]["5d"]["bytes"] == 100 * GB, "fresh output does not recompute")
        check(r.stdout.strip().startswith("{\n"), "pretty printed")
        check("/home/" not in r.stdout and "/Users/" not in r.stdout, "no home path in output")
        r2 = run(d_fresh, "--brief", "--status")
        check(r2.returncode == 0 and r2.stdout.startswith("磁盘 黄") and "\n" not in r2.stdout.strip(), f"brief fresh ({r2.stdout!r})")
        check(snapshot(d_fresh) == before, "CLI does not change the fresh data directory")

        # 2. Dead writer pid: recompute from NDJSON.
        d_dead = tmp / "dead"
        write_samples(d_dead, now)
        write_status(d_dead, now, now - timedelta(seconds=30), dead_pid())
        before = snapshot(d_dead)
        r = run(d_dead, "--status")
        check(r.returncode == 3, f"dead pid exit code 3 (got {r.returncode})")
        j = json.loads(r.stdout)
        check(j["app_running"] is False and j["fresh"] is False and j["recomputed"] is True, "dead pid flags")
        g = j["items"]["disk"]["growth"]["5d"]
        check(g["bytes"] == 300 * GB, f"5d growth 300 GB (got {g['bytes']})")
        check(g["net_bytes"] == 250 * GB, f"5d net change 250 GB (got {g['net_bytes']})")
        check(j["items"]["disk"]["level"] == "red", f"recomputed level red (got {j['items']['disk']['level']})")
        check(j["items"]["disk"]["used"]["value"] == 450 * GB, "recomputed used 450 GB")
        check(any(a["type"] == "disk_growth" for a in j["active_alerts"]), "recomputed growth alert")
        net = j["items"]["network"]["traffic"]["5d"]
        check(net["status"] in ("ok", "insufficient_window") and net["rx"] is not None, f"network 5d recomputed ({net})")
        # Reboot splits traffic: pairs (1000->2000),(2000->3000),(3000->4000) then skip, (500->900),(900->1300),(1300->1500).
        check(net["rx"] == (1000 + 1000 + 1000 + 400 + 400 + 200) * 10**6, f"network rx skips reboot pair (got {net['rx']})")
        check(j["overall"]["level"] == "red", "recomputed overall level")
        b = run(d_dead, "--status", "--brief")
        check(b.returncode == 3 and b.stdout.startswith("磁盘 红（5 天 +300 GB）") and "App 未运行" in b.stdout, f"brief dead ({b.stdout!r})")
        check(snapshot(d_dead) == before, "CLI does not change the dead-pid data directory")

        # 3. Alive pid but old status: expired, app running.
        d_old = tmp / "old"
        write_samples(d_old, now)
        write_status(d_old, now, now - timedelta(hours=1), me)
        r = run(d_old, "--status")
        j = json.loads(r.stdout)
        check(r.returncode == 3 and j["app_running"] is True and j["fresh"] is False and j["recomputed"] is True,
              "old status with live pid: exit 3, app_running true")
        b = run(d_old, "--status", "--brief")
        check(b.returncode == 3 and "数据已过期" in b.stdout, f"brief expired ({b.stdout!r})")

        # 4. No status file, only history.
        d_hist = tmp / "hist"
        write_samples(d_hist, now)
        r = run(d_hist, "--status")
        j = json.loads(r.stdout)
        check(r.returncode == 3 and j["app_running"] is False and j["recomputed"] is True, "history only: exit 3")
        check(j["items"]["disk"]["growth"]["5d"]["bytes"] == 300 * GB, "history only: growth recomputed")
        check(not (d_hist / "status.json").exists(), "CLI did not create status.json")

        # 5. Nothing at all; missing directory must not be created.
        d_none = tmp / "never-created"
        r = run(d_none, "--status")
        check(r.returncode == 4, f"empty exit code 4 (got {r.returncode})")
        j = json.loads(r.stdout)
        check(j == {"schema_version": 1, "app_running": False, "fresh": False,
                    "overall": {"level": "unknown", "summary": "MoleMonitor 尚未运行过"}}, "empty JSON content")
        b = run(d_none, "--status", "--brief")
        check(b.returncode == 4 and "尚未运行过" in b.stdout, "empty brief")
        h = run(d_none, "--disk-history")
        check(h.returncode == 4 and json.loads(h.stdout) == [], "empty disk-history exit 4")
        check(not d_none.exists(), "CLI did not create the data directory")

        # 6. disk-history.
        before = snapshot(d_hist)
        r = run(d_hist, "--disk-history")
        rows = json.loads(r.stdout)
        check(r.returncode == 0 and len(rows) == 30, f"disk-history default 30 rows (got {len(rows)})")
        for k in ("date", "min_used", "max_used", "growth", "samples"):
            check(all(k in row for row in rows), f"disk-history rows have {k}")
        check(any(row["max_used"] == 450 * GB for row in rows), "disk-history has the 450 GB day")
        check(sum(row["samples"] for row in rows) == 8, f"disk-history counts 8 good samples (got {sum(row['samples'] for row in rows)})")
        check(len(json.loads(run(d_hist, "--disk-history", "--days", "7").stdout)) == 7, "--days 7")
        check(len(json.loads(run(d_hist, "--days", "100", "--disk-history").stdout)) == 60, "--days 100 clamps to 60")
        check(run(d_hist, "--disk-history", "--days", "0").returncode == 2, "--days 0 is an error")
        check(run(d_hist, "--disk-history", "--days", "x").returncode == 2, "--days x is an error")
        check(run(d_hist, "--disk-history", "--days").returncode == 2, "--days without value is an error")
        check(snapshot(d_hist) == before, "CLI does not change the history directory")

        # 7. Static commands and argument errors.
        s = run(d_none, "--schema")
        sj = json.loads(s.stdout)
        check(s.returncode == 0 and "definitions" in sj and "not_recorded" in sj, "--schema parses")
        for k in ("real_used", "growth", "net_change", "network_interfaces"):
            check(k in sj["definitions"], f"schema definitions has {k}")
        v = run(d_none, "--version")
        check(v.returncode == 0 and v.stdout.startswith("molemonitor-cli "), f"--version ({v.stdout!r})")
        hp = run(d_none, "--help")
        check(hp.returncode == 0 and "用法" in hp.stdout, "--help")
        for bad in (["--bogus"], [], ["--status", "--schema"], ["--brief"], ["--days", "3"], ["--status", "extra"]):
            r = run(d_none, *bad)
            check(r.returncode == 2 and r.stdout == "" and "用法" in r.stderr, f"bad args {bad} exit 2 with usage on stderr")

        # 8. Interoperability: a real StatusFile written by Core is read back by the CLI.
        d_io = tmp / "interop"
        d_io.mkdir()
        w = subprocess.run([str(mk), str(d_io / "status.json"), str(me), iso(now - timedelta(seconds=20))],
                           capture_output=True, text=True)
        check(w.returncode == 0, f"make-status ran ({w.stderr})")
        r = run(d_io, "--status")
        check(r.returncode == 0, f"interop exit 0 (got {r.returncode}, {r.stderr})")
        j = json.loads(r.stdout)
        check(j["fresh"] is True and j["items"]["disk"]["growth"]["5d"]["bytes"] == 300 * GB, "interop growth 300 GB")
        check(j["items"]["disk"]["growth"]["5d"]["net_bytes"] == 250 * GB, "interop net 250 GB")
        check(j["schema_version"] == 1 and j["writer_pid"] == me, "interop identity fields")
        b = run(d_io, "--status", "--brief")
        check(b.returncode == 0 and b.stdout.startswith("磁盘 红（5 天 +300 GB）"), f"interop brief ({b.stdout!r})")
        check(os.stat(d_io / "status.json").st_mode & 0o777 == 0o600, "Core writes status.json with mode 0600")

        # 9. Timing: 50 runs of --status --brief and --status on the fresh directory.
        for label, args in (("--status", ["--status"]), ("--status --brief", ["--status", "--brief"]),
                            ("--disk-history", ["--disk-history"]), ("--version", ["--version"])):
            ts = []
            for _ in range(50):
                t0 = time.perf_counter()
                run(d_fresh, *args)
                ts.append((time.perf_counter() - t0) * 1000)
            ts.sort()
            p50, p95 = statistics.median(ts), ts[int(len(ts) * 0.95) - 1]
            print(f"measure {label}: p50={p50:.1f} ms p95={p95:.1f} ms (50 runs, includes process spawn)")
            if label == "--status":
                check(p95 < 100, f"--status p95 under 100 ms sanity bound (got {p95:.1f})")
        ts = []
        env = dict(os.environ, MOLEMONITOR_DATA_DIR=str(d_dead))
        for _ in range(50):
            t0 = time.perf_counter()
            subprocess.run([str(cli), "--status"], capture_output=True, env=env)
            ts.append((time.perf_counter() - t0) * 1000)
        ts.sort()
        print(f"measure --status recompute path: p50={statistics.median(ts):.1f} ms p95={ts[int(len(ts)*0.95)-1]:.1f} ms")

    print(f"{checks - failures}/{checks} checks passed")
    sys.exit(1 if failures else 0)


main()
