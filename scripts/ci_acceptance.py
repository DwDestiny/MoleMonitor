#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: dist/MoleMonitor.app built by scripts/build.py on arm64 macOS.
# Output: Headless acceptance checks (self-test, signature, real sampling, CLI read-back, static preview); exit code 0 means all passed.
# Pos: Runs in GitHub Actions and on a Mac. It starts no visible UI, installs nothing and changes no login item.
from pathlib import Path
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
app = root / "dist/MoleMonitor.app"
main_bin = app / "Contents/MacOS/MoleMonitor"
cli_bin = app / "Contents/Helpers/molemonitor-cli"
failures = []


def check(ok, name, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(name)
    return ok


def run(cmd, env=None, timeout=120):
    merged = dict(os.environ)
    merged.update(env or {})
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=merged, timeout=timeout)


if platform.system() != "Darwin" or platform.machine() != "arm64":
    sys.exit("ci_acceptance.py: needs arm64 macOS.")
if not main_bin.exists() or not cli_bin.exists():
    sys.exit("ci_acceptance.py: dist/MoleMonitor.app is missing. Run scripts/build.py first.")

# 1. Bundle and signature
signature = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
check(signature.returncode == 0, "codesign verify (ad-hoc)", signature.stderr.strip())
plist = run(["/usr/bin/plutil", "-convert", "json", "-o", "-", app / "Contents/Info.plist"])
info = json.loads(plist.stdout) if plist.returncode == 0 else {}
version = re.search(r'static\s+let\s+version\s*=\s*"([^"]+)"', (root / "Sources/Core/AppInfo.swift").read_text()).group(1)
check(info.get("CFBundleShortVersionString") == version, "Info.plist version equals AppInfo.version", str(info.get("CFBundleShortVersionString")))
check(info.get("LSUIElement") in (True, 1), "Info.plist LSUIElement is true")
check(info.get("CFBundleIdentifier") == "io.github.dwdestiny.MoleMonitor", "bundle identifier", str(info.get("CFBundleIdentifier")))

# 2. Self-test
st = run([main_bin, "--self-test"])
check(st.returncode == 0 and "PASS" in st.stdout, "--self-test", (st.stdout + st.stderr).strip()[-300:])

# 3. Real headless sampling
data_dir = Path(os.environ.get("MOLEMONITOR_CI_OUT") or tempfile.gettempdir()) / "molemonitor-ci"
shutil.rmtree(data_dir, ignore_errors=True)
data_dir.mkdir(mode=0o700, parents=True)
os.chmod(data_dir, 0o700)
env = {"MOLEMONITOR_DATA_DIR": str(data_dir)}
preview = data_dir / "preview.png"
t0 = time.time()
dg = run([main_bin, "--diagnose", "--seconds", "22", "--preview", preview], env=env, timeout=180)
print(f"diagnose wall time {time.time() - t0:.1f} s, exit code {dg.returncode}", flush=True)
print("---- diagnose stderr (tail) ----\n" + dg.stderr[-600:], flush=True)
report = None
try:
    report = json.loads(dg.stdout)
except json.JSONDecodeError:
    print("---- diagnose stdout ----\n" + dg.stdout[-1500:], flush=True)
check(dg.returncode == 0 and report is not None, "--diagnose exits 0 and prints JSON")
if report:
    print(json.dumps({k: v for k, v in report.items() if k != "status"}, ensure_ascii=False, indent=2), flush=True)
    check(report.get("mode") == "headless", "diagnose mode is headless")
    check(report.get("cleaningInvoked") is False, "diagnose invoked no cleaning")
    status = report.get("status") or {}
    disk = (status.get("items") or {}).get("disk") or {}
    total = (disk.get("total") or {}).get("value")
    used = (disk.get("used") or {}).get("value")
    avail = (disk.get("available_important") or {}).get("value")
    check(isinstance(total, int) and total > 10 * 10**9, "disk total is a real number", str(total))
    check(isinstance(used, int) and 0 < used < total, "disk used is between 0 and total", str(used))
    check(isinstance(avail, int) and 0 < avail <= total, "disk available_important is plausible", str(avail))
    check(used is not None and avail is not None and total is not None and abs((total - avail) - used) < 2 * 1024**3,
          "used equals total minus available_important")
    check(disk.get("volume") == "/System/Volumes/Data", "disk volume", str(disk.get("volume")))
    check(status.get("overall", {}).get("level") in ("green", "yellow", "red"), "overall level is a real level",
          str(status.get("overall")))
    check(status.get("writer_pid", 0) > 0, "status.writer_pid is set")
    print("authorization in this environment:", report.get("authorization"), flush=True)

# 4. Files on disk
files = sorted(p.name for p in data_dir.iterdir())
print("data dir files:", files, flush=True)
status_path = data_dir / "status.json"
check(status_path.exists(), "status.json exists")
if status_path.exists():
    check(stat.S_IMODE(status_path.stat().st_mode) == 0o600, "status.json mode 0600",
          oct(stat.S_IMODE(status_path.stat().st_mode)))
history = list(data_dir.glob("disk-*.ndjson"))
check(len(history) == 1, "one disk NDJSON file", str(history))
if history:
    rows = [json.loads(line) for line in history[0].read_text().splitlines() if line.strip()]
    check(len(rows) >= 1, "NDJSON has at least one row", str(len(rows)))
    if rows:
        print("first NDJSON row:", json.dumps(rows[0], ensure_ascii=False), flush=True)
        check(rows[0].get("src") == "launch", "first row source is launch", str(rows[0].get("src")))
        check(rows[0].get("net_rx") is not None and rows[0].get("net_tx") is not None,
              "network counters are present (not null)", str({k: rows[0].get(k) for k in ("net_rx", "net_tx", "err")}))
        check(stat.S_IMODE(history[0].stat().st_mode) == 0o600, "NDJSON mode 0600")
check(stat.S_IMODE(data_dir.stat().st_mode) == 0o700, "data dir mode 0700")

# 5. CLI read-back against the data the app just wrote (the writer process has exited, so exit code 3 is expected)
before = {p.name: (p.stat().st_mtime_ns, p.stat().st_size) for p in data_dir.iterdir()}
cs = run([cli_bin, "--status"], env=env)
check(cs.returncode == 3, "CLI --status exits 3 after the app exited", f"exit {cs.returncode}")
try:
    cli_json = json.loads(cs.stdout)
except json.JSONDecodeError:
    cli_json = {}
check(cli_json.get("app_running") is False and cli_json.get("fresh") is False, "CLI reports app_running=false, fresh=false")
cli_disk = (cli_json.get("items") or {}).get("disk") or {}
check((cli_disk.get("total") or {}).get("value") == total, "CLI total equals the app's total")
cb = run([cli_bin, "--status", "--brief"], env=env)
check(cb.returncode == 3 and len(cb.stdout.strip().splitlines()) == 1, "CLI --brief prints one line", cb.stdout.strip())
print("brief:", cb.stdout.strip(), flush=True)
ch = run([cli_bin, "--disk-history", "--days", "1"], env=env)
check(ch.returncode == 0 and isinstance(json.loads(ch.stdout or "null"), list), "CLI --disk-history prints a JSON array")
check(run([cli_bin, "--schema"]).returncode == 0, "CLI --schema exits 0")
check(run([cli_bin, "--bogus"]).returncode == 2, "CLI unknown argument exits 2")
after = {p.name: (p.stat().st_mtime_ns, p.stat().st_size) for p in data_dir.iterdir()}
check(before == after, "CLI left the data directory unchanged")
timings = []
for _ in range(30):
    s = time.perf_counter()
    run([cli_bin, "--status", "--brief"], env=env)
    timings.append((time.perf_counter() - s) * 1000)
timings.sort()
p50, p95 = timings[len(timings) // 2], timings[int(len(timings) * 0.95) - 1]
print(f"CLI --status --brief on this runner: p50={p50:.1f} ms p95={p95:.1f} ms (30 runs, includes process spawn)", flush=True)
check(p50 <= 50, "CLI p50 under 50 ms (runner VM, informational limit)", f"{p50:.1f}")

# 6. Static preview
png = preview.read_bytes() if preview.exists() else b""
check(png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 4000, "static preview PNG is written", f"{len(png)} bytes")
if report:
    check(not report.get("staticPreviewError"), "no preview error", str(report.get("staticPreviewError")))

print()
if failures:
    print(f"ACCEPTANCE FAILED: {len(failures)} check(s): " + "; ".join(failures))
    sys.exit(1)
print("ACCEPTANCE PASSED")
