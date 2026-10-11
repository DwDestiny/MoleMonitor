#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: dist/MoleMonitor.app built by scripts/build.py on arm64 macOS.
# Output: Headless acceptance checks (self-test, signature, real sampling, CLI read-back, static preview) and the UI regression gate
#         (dist-uitest/MoleMonitor.app --ui-test: status item, popover, motion, hover, close, quit); exit code 0 means all passed.
# Pos: Runs in GitHub Actions and on a Mac. It installs nothing and changes no login item. The UI gate shows a popover on the
#      runner for about 30 seconds, with temporary data; the gate needs `python3 scripts/build.py --ui-test` first.
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
PREVIEW_CASES = ("allGreen", "cpuYellow", "diskRed", "powerYellow", "multi", "collecting", "stale")
# Panel height tiers in points (docs/DESIGN.md 2.11): quiet 332, one problem 560, several problems 620.
PREVIEW_HEIGHT_PT = {"allGreen": 332, "collecting": 332, "stale": 332,
                     "cpuYellow": 560, "diskRed": 560, "powerYellow": 560, "multi": 620}
preview_names = [f"preview-{case}-{scheme}{suffix}.png"
                 for suffix in ("", "-empty") for case in PREVIEW_CASES for scheme in ("light", "dark")]
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
    probe = report.get("liveProbe") or {}
    print("live probe:", json.dumps(probe), flush=True)
    check(probe.get("samplingWhileOpen") is True, "live sampling runs while the panel is open")
    check(probe.get("cpuPointsWhileOpen", 0) >= 2, "live CPU series has points while open", str(probe.get("cpuPointsWhileOpen")))
    cpu_now = probe.get("lastCpuPercent")
    check(isinstance(cpu_now, (int, float)) and 0 <= cpu_now <= 100, "live CPU percent is in 0..100", str(cpu_now))
    print("live net points while open:", probe.get("netPointsWhileOpen"), "(informational: depends on runner interfaces)", flush=True)
    check(probe.get("samplingAfterClose") is False, "no live timer after the panel closes")
    check(probe.get("netPointsAfterClose") == 0 and probe.get("cpuPointsAfterClose") == 0, "live buffers are empty after close")

    # Real readings of the new engine (status.json fields and diagnosticSnapshot), docs/DESIGN.md 8.2
    items = status.get("items") or {}
    memory = items.get("memory") or {}
    thermal = items.get("thermal") or {}
    check(memory.get("pressure") in ("normal", "warning", "critical"), "items.memory.pressure is a real value", str(memory.get("pressure")))
    check(thermal.get("state") in ("nominal", "fair", "serious", "critical"), "items.thermal.state is a real value", str(thermal.get("state")))
    check((memory.get("swap_used") or {}).get("status") == "ok", "items.memory.swap_used.status is ok", str(memory.get("swap_used")))
    top_apps = status.get("top_apps") or {}
    check(len(top_apps.get("apps") or []) >= 1, "top_apps.apps has at least one app", str(len(top_apps.get("apps") or [])))
    check(((top_apps.get("coverage") or {}).get("readable") or 0) > 0, "top_apps.coverage.readable is above 0", str(top_apps.get("coverage")))
    check(bool((status.get("env") or {}).get("chip")), "env.chip is not empty", str((status.get("env") or {}).get("chip")))
    check(isinstance((status.get("prompt_prefs") or {}).get("include_app_names"), bool), "prompt_prefs.include_app_names is a boolean",
          str(status.get("prompt_prefs")))
    opened, closed, final = (report.get(k) or {} for k in ("diagnosticOpen", "diagnosticClosed", "diagnosticFinal"))
    check(opened.get("panelOpen") is True and opened.get("timerCount") == 2, "diagnostic: 2 timers while the panel is open",
          str((opened.get("panelOpen"), opened.get("timerCount"))))
    check(opened.get("processScanPeriod") == 4, "diagnostic: process scan every 4 s while the panel is open", str(opened.get("processScanPeriod")))
    check((opened.get("trendFinePoints") or 0) >= 1, "diagnostic: fine trend points exist while the panel is open", str(opened.get("trendFinePoints")))
    check(closed.get("panelOpen") is False and closed.get("timerCount") == 1, "diagnostic: 1 timer after the panel closes",
          str((closed.get("panelOpen"), closed.get("timerCount"))))
    check(closed.get("trendFinePoints") == 0, "diagnostic: fine trend points are gone after close", str(closed.get("trendFinePoints")))
    for label, snap in (("closed", closed), ("final", final)):
        levels = [line.get("level") for line in snap.get("items") or []]
        calm = bool(levels) and all(level == "green" for level in levels)
        # The runner disk may be yellow, so a non-green set only has to use a throttled period.
        allowed = (300,) if calm else (180, 300)
        check(snap.get("processScanPeriod") in allowed, f"diagnostic ({label}): process scan period fits the item levels",
              f"{snap.get('processScanPeriod')} levels={levels}")
    check(len(final.get("topApps") or []) >= 1 and (final.get("processesReadable") or 0) > 0, "diagnostic: top apps and readable processes",
          f"{len(final.get('topApps') or [])} apps, readable {final.get('processesReadable')}")

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

# 6. M1 and M3: static previews. 7 cases x light and dark x full and empty data = 28 files, 328 pt wide at scale 2.
#    Height by case is one of the three tiers. Every file is a non-empty PNG, and no two files are equal.
def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


import hashlib

sizes = {}
digests = {}
for name in preview_names:
    path = data_dir / name
    data = path.read_bytes() if path.exists() else b""
    size = png_size(data)
    check(size is not None and len(data) > 8000, f"M1 preview {name} is a PNG", f"{len(data)} bytes")
    if size:
        sizes[name] = size
        digests.setdefault(hashlib.sha256(data).hexdigest(), []).append(name)
        case = name.split("-")[1]
        print(f"  {name}: {size[0]}x{size[1]} px, {len(data)} bytes", flush=True)
        check(size[0] == 656, f"M3 preview {name} is 328 pt wide", str(size[0]))
        check(abs(size[1] - 2 * PREVIEW_HEIGHT_PT[case]) <= 2, f"M3 preview {name} has the tier height {PREVIEW_HEIGHT_PT[case]} pt", str(size[1]))
duplicates = [names for names in digests.values() if len(names) > 1]
check(len(preview_names) == 28 and not duplicates, "M1 the 28 previews are pairwise different", str(duplicates))
if report:
    check(not report.get("staticPreviewError"), "no preview error", str(report.get("staticPreviewError")))
quiet_heights = {sizes[n][1] for n in sizes if n.split("-")[1] in ("allGreen", "collecting", "stale")}
problem_heights = {sizes[n][1] for n in sizes if n.split("-")[1] not in ("allGreen", "collecting", "stale")}
check(bool(quiet_heights) and bool(problem_heights) and max(quiet_heights) + 400 <= min(problem_heights),
      "M3 the quiet card is at least 200 pt smaller than any problem card", f"{quiet_heights} {problem_heights}")

# 7. Release binary has no test code; the UI regression variant has it (positive control)
release_bytes = main_bin.read_bytes()
for marker in (b"UITestHarness", b"--ui-test", b"UITestFrameStore"):
    check(marker not in release_bytes, f"release binary does not contain {marker.decode()}")
# Source audit of the panel files. The runtime accessibility tree of SwiftUI is not always readable on a VM, so this is a separate,
# weaker check: every action Button (not a menu item with a text title) needs an accessibilityIdentifier(...) and an
# accessibilityLabel with Chinese text before the next Button or within 60 lines.
panel_files = sorted((root / "Sources/App").glob("Panel*.swift"))
button_total = 0
bad_buttons = []
for file in panel_files:
    lines = file.read_text(encoding="utf-8").splitlines()
    starts = [i for i, line in enumerate(lines) if re.search(r"\bButton\(", line) and not re.search(r'\bButton\("', line)]
    for index, i in enumerate(starts):
        end = min(starts[index + 1] if index + 1 < len(starts) else len(lines), i + 60)
        block = "\n".join(lines[i:end])
        has_id = re.search(r'accessibilityIdentifier\(', block)
        has_label = re.search(r'accessibilityLabel\(.*[\u4e00-\u9fff]', block) or re.search(r'\.help\(.*[\u4e00-\u9fff]', block)
        button_total += 1
        if not (has_id and has_label):
            bad_buttons.append(f"{file.name}:{i + 1}")
check(button_total >= 6 and not bad_buttons, "source audit: every Button in Panel*.swift has an identifier and a Chinese label",
      f"buttons found {button_total}, without both: {bad_buttons}")
check(not (root / "Sources/App/Panel.swift").exists(), "source audit: the old Panel.swift is gone")
timer_hits = []
for file in panel_files:
    text = re.sub(r"//.*", "", file.read_text(encoding="utf-8"))
    if re.search(r"\bTimer\b|TimelineView|Timer\.publish", text):
        timer_hits.append(file.name)
check(not timer_hits, "source audit: no Timer or TimelineView in the panel files", str(timer_hits))
# The placeholder text of the skeleton is gone from every view the panel and the menu bar use.
skeleton_hits = []
for file in sorted((root / "Sources/App").glob("*.swift")) + [root / "Sources/MoleMonitor.swift"]:
    text = re.sub(r"//.*", "", file.read_text(encoding="utf-8"))
    if re.search(r'"[^"\n]*SKELETON[^"\n]*"', text):
        skeleton_hits.append(file.name)
check(not skeleton_hits, "source audit: no SKELETON string literal in the app sources", str(skeleton_hits))
# The release binary does not draw the placeholder either.
check(b"SKELETON" not in release_bytes, "release binary does not contain the SKELETON placeholder text")
ui_app = root / "dist-uitest/MoleMonitor.app"
ui_bin = ui_app / "Contents/MacOS/MoleMonitor"
skipped_ui = []
if not ui_bin.exists():
    check(False, "dist-uitest/MoleMonitor.app exists (run scripts/build.py --ui-test)")
else:
    ui_bytes = ui_bin.read_bytes()
    check(b"UITestHarness" in ui_bytes and b"--ui-test" in ui_bytes, "UI test variant contains the harness (positive control)")
    check(run(["/usr/bin/codesign", "--verify", "--deep", "--strict", ui_app]).returncode == 0, "UI test variant codesign verify (ad-hoc)")

    # 8. UI regression gate: real AppDelegate, NSStatusItem, NSPopover and MonitorEngine on a seeded red history
    base = Path(os.environ.get("MOLEMONITOR_CI_OUT") or tempfile.gettempdir())
    ui_out = base / "molemonitor-ui"
    ui_data = base / "molemonitor-ui-data"
    for folder in (ui_out, ui_data):
        shutil.rmtree(folder, ignore_errors=True)
    ui_out.mkdir(parents=True)
    ui_data.mkdir(mode=0o700)
    os.chmod(ui_data, 0o700)
    t0 = time.time()
    ui_stdout, ui_stderr, ui_code = "", "", None
    try:
        ui = run([ui_bin, "--ui-test", "--ui-test-out", ui_out], env={"MOLEMONITOR_DATA_DIR": str(ui_data)}, timeout=170)
        ui_stdout, ui_stderr, ui_code = ui.stdout, ui.stderr, ui.returncode
    except subprocess.TimeoutExpired as e:
        def text(x):
            return x.decode("utf-8", "replace") if isinstance(x, bytes) else (x or "")
        ui_stdout, ui_stderr = text(e.stdout), text(e.stderr)
    print(f"ui-test wall time {time.time() - t0:.1f} s, exit code {ui_code}", flush=True)
    print("---- ui-test stdout ----\n" + ui_stdout[-6000:], flush=True)
    print("---- ui-test stderr (tail) ----\n" + ui_stderr[-1500:], flush=True)
    check(ui_code is not None, "UI test finished within 170 s")
    report_path = ui_out / "ui-report.json"
    ui_report = json.loads(report_path.read_text()) if report_path.exists() else None
    check(ui_report is not None, "UI test wrote ui-report.json")
    if ui_report:
        by_id = {item["id"]: item for item in ui_report["items"]}
        for letter in list("ABCDEFGHIJKL") + ["M2", "M3", "M4", "M5", "M6", "M11", "M12", "M13", "N1", "N2", "M14", "M19"]:
            check(letter in by_id, f"UI item {letter} reported")
        for item in ui_report["items"]:
            label = f"UI {item['id']} {item['name']}"
            if item["status"] == "skipped":
                skipped_ui.append(item)
                print(f"SKIP  {label}  [{item['note']}]", flush=True)
            elif item["status"] == "pending":
                pass
            else:
                ok = item["status"] == "pass"
                print(f"{'PASS' if ok else 'FAIL'}  {label}  {item['note']}", flush=True)
                if not ok:
                    failures.append(label)
        # K: the process must have quit through the button with exit code 0 and written status.json at exit
        quit_item = by_id.get("K")
        if quit_item and quit_item["status"] == "pending":
            check(ui_code == 0, "UI K quit button ends the process with exit code 0", str(ui_code))
            status_file = ui_data / "status.json"
            before = ui_report.get("statusMtimeBeforeQuit")
            written = status_file.exists() and before is not None and status_file.stat().st_mtime > before
            check(written, "UI K status.json is written at exit", f"mtime before quit {before}")
        elif quit_item is None or quit_item["status"] != "pass":
            check(False, "UI K quit button", str((quit_item or {}).get("note")))
        print("ui frames:", ", ".join(ui_report.get("frames", [])), flush=True)
        print("ui info:", json.dumps(ui_report.get("info", {}), ensure_ascii=False), flush=True)
        for key in ("mainThreadIntervalsMs", "renderMs"):
            print(key, json.dumps(ui_report.get(key)), flush=True)
    if skipped_ui:
        print("\n!!!! UI REGRESSION SKIPPED ITEMS (not failures, not passes) !!!!", flush=True)
        for item in skipped_ui:
            print(f"  {item['id']} {item['name']}: {item['note']}", flush=True)

print()
if failures:
    print(f"ACCEPTANCE FAILED: {len(failures)} check(s): " + "; ".join(failures))
    sys.exit(1)
print("ACCEPTANCE PASSED")

# --- dog animation checks (I2)
# Independent block, owner I2 (docs/DESIGN.md 9.2, stage 2). It runs after the summary above and changes none of the checks
# above; a failure here exits 1 on its own. It runs the UI test build with `--dog-gallery <dir> --dog-checks`
# (Sources/App/UITestDogChecks.swift: one small window and one popover with a DogView for about 25 s, temporary output only)
# and reads <dir>/dog-report.json: DA 60 to 80 frames in 3 s with the card open, DB 0 frame callbacks in 3 s after close,
# DC leg speed under the natural limit across gait switches, DD menu switch <= 8 frames, <= 600 ms, no timer after it,
# DE Reduce Motion gives no frames and no timer. DF: the release binary has none of the dog test code.
def _dog_animation_checks():
    dog_failures = []

    def dog_check(ok, name, detail=""):
        print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else ""), flush=True)
        if not ok:
            dog_failures.append(name)

    print("\n---- dog animation checks (I2) ----", flush=True)
    release = main_bin.read_bytes()
    for marker in (b"DogFrameProbe", b"UITestDogChecks", b"--dog-checks"):
        dog_check(marker not in release, f"DF release binary does not contain {marker.decode()}")
    dog_ui_bin = root / "dist-uitest/MoleMonitor.app/Contents/MacOS/MoleMonitor"
    if not dog_ui_bin.exists():
        dog_check(False, "dog: dist-uitest/MoleMonitor.app exists")
        return dog_failures
    dog_check(b"DogFrameProbe" in dog_ui_bin.read_bytes(), "DF UI test variant contains the dog probe (positive control)")
    dog_out = Path(os.environ.get("MOLEMONITOR_CI_OUT") or tempfile.gettempdir()) / "molemonitor-dog"
    dog_out.mkdir(parents=True, exist_ok=True)
    report_path = dog_out / "dog-report.json"
    if report_path.exists():
        report_path.unlink()
    t0 = time.time()
    try:
        dog_run = run([dog_ui_bin, "--dog-gallery", dog_out, "--dog-checks"], timeout=120)
        print(f"dog checks wall time {time.time() - t0:.1f} s, exit code {dog_run.returncode}", flush=True)
        print("---- dog checks stdout ----\n" + dog_run.stdout[-3000:], flush=True)
        if dog_run.stderr.strip():
            print("---- dog checks stderr (tail) ----\n" + dog_run.stderr[-1000:], flush=True)
    except subprocess.TimeoutExpired:
        dog_check(False, "dog checks finished within 120 s")
    dog_report = json.loads(report_path.read_text()) if report_path.exists() else None
    dog_check(dog_report is not None, "dog checks wrote dog-report.json")
    if dog_report:
        by_id = {item["id"]: item for item in dog_report.get("items", [])}
        for item_id in ("DA", "DB", "DC", "DD", "DE"):
            item = by_id.get(item_id)
            if item is None:
                dog_check(False, f"dog {item_id} reported")
                continue
            dog_check(item["status"] == "pass", f"dog {item_id} {item['name']}", item["note"])
            print(f"      values {json.dumps(item.get('values', {}), sort_keys=True)}", flush=True)
        print("dog info:", json.dumps(dog_report.get("info", {}), sort_keys=True), flush=True)
    return dog_failures


_dog_failures = _dog_animation_checks()
print()
if _dog_failures:
    print(f"DOG ANIMATION CHECKS FAILED: {len(_dog_failures)} check(s): " + "; ".join(_dog_failures))
    sys.exit(1)
print("DOG ANIMATION CHECKS PASSED")
