#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: dist/MoleMonitor.app built by scripts/build.py on arm64 macOS.
# Output: Headless acceptance checks (self-test, signature, real sampling, CLI read-back, static preview) and the UI regression gate
#         (dist-uitest/MoleMonitor.app --ui-test: status item, popover, motion, hover, close, quit); exit code 0 means all passed.
#      `--self-test` checks the gate registry logic and the source audits (W25 to W27, run on the repo sources) on any OS and exits.
#      The registry GATES lists W01 to W30 and the old gates:
#      pending gates are shown as inactive (未激活), never counted as passed (docs/CI.md, "v2 门禁登记表").
# Pos: Runs in GitHub Actions and on a Mac. It installs nothing and changes no login item. The UI gate shows a popover on the
#      runner for a few minutes (time budget 420 s, docs/CI.md "UI 测试总时长"), with temporary data; the gate needs `python3 scripts/build.py --ui-test` first.
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

# --- Gate registry (docs/DESIGN_V2.md 13.2.1 and 13.3; method in docs/CI.md, section "v2 门禁登记表")
# Each gate has an id, a name, a status and a source that says where its result is read:
#   status "active"  : the gate runs and must pass. A missing result is a failure.
#   status "pending" : the gate is registered but not enforced. It never fails CI and it never counts as passed.
#                      The summary lists it as inactive (未激活). A result that a pending gate reports is printed as INFO only.
#   source "ui"      : an item with the same id in ui-report.json (written by `--ui-test`, harness UITestHarness.swift).
#   source "core"    : Core unit test (the "Core and CLI tests" workflow step). No evaluator here, so it cannot be active.
#   source "script"  : a script run by a later step. No evaluator here, so it cannot be active.
#   source "audit"   : a source audit that this script runs itself on Sources/ (W26, W27). It needs no build, so --self-test runs it too.
# To activate a gate, WP-F changes its status to "active" in GATES. The owner of a gate only adds a Swift check file.
GATES = [
    # Gates that exist today (13.2: kept, updated, or tightened; 13.2.1 lists the selector changes)
    *[{"id": i, "name": n, "status": "active", "source": "ui"} for i, n in [
        ("A", "status item and icon"), ("B", "open"), ("C", "entrance animation advances"), ("D", "live data flows in"),
        ("E", "main thread smoothness"), ("F", "hover interaction"), ("G", "button interaction and fallback text"),
        ("H", "close"), ("I", "open again"), ("J", "light and dark"), ("K", "quit"), ("L", "closed panel costs nothing"),
        ("M2", "problem-first order"), ("M3", "height tiers"), ("M4", "refresh and expand keep height"), ("M5", "contrast"),
        ("M6", "large type"), ("M11", "focus ring"), ("M12", "cold start first frame"), ("M13", "copy"),
        ("N1", "copy with real engine input"), ("N2", "history exists on open"), ("M14", "menu bar icon state"),
        ("M19", "panel accessibility tree has no placeholder text"), ("M22", "folded problem card colors")]],
    # Removed with the dog (U10, 2026-10-18; entries in docs/CI.md): M19V, M20, M21, DA to DE, BA to BF.
    # New gates of v2 (13.3). WP-F2 activated every W gate that has a real check reported as pass in the UI run (CI run 38341738663).
    # W13, W20 and W21 are Core unit test suites. They are read from the log of scripts/test_core.py (CORE_GATE_SUITES below).
    # W16 (UITestPanelChecks.swift since U10) was activated after WP-F2; gate L stays next to it.
    # Removed with the dog (U10): W04, W11, W12, W14, W15, W17, W18. W08 stays (UITestIconChecks.swift, menu bar icon).
    *[{"id": i, "name": n, "status": "active", "source": src} for i, n, src in [
        ("W01", "preview matrix", "ui"), ("W02", "layout and problem-first", "ui"), ("W03", "open speed and no white flash", "ui"),
        ("W05", "sidebar", "ui"), ("W06", "hover intent", "ui"),
        ("W07", "drag readout", "ui"), ("W08", "menu bar five states", "ui"), ("W09", "copy", "ui"),
        ("W10", "Esc layers and close", "ui"),
        ("W13", "bubble templates", "core"),
        ("W16", "closed panel costs nothing", "ui"),
        ("W19", "capacity triple", "ui"), ("W20", "prompt", "core"), ("W21", "memory pressure percent", "core"),
        ("W22", "value alignment", "ui")]],
    # v3 menu bar runner (docs/DESIGN_V3.md 4.2, U10): UITestIconChecks.swift.
    {"id": "W29", "name": "menu bar runner frames", "status": "active", "source": "ui"},
    {"id": "W30", "name": "menu bar runner trigger and timer", "status": "active", "source": "ui"},
    # v3 panel gates (docs/DESIGN_V3.md 3.3, 5.1, 9.2; entries in docs/CI.md, section "v3 门禁改动"). W25 also has a source audit below.
    {"id": "W24", "name": "all-green panel height <= 290 pt", "status": "active", "source": "ui"},
    {"id": "W25", "name": "corner radius set {8, full}", "status": "active", "source": "ui"},
    {"id": "W26", "name": "no ' · ' in UI strings", "status": "active", "source": "audit"},
    {"id": "W27", "name": "17 pt type only in the headline block", "status": "active", "source": "audit"},
    {"id": "W28", "name": "problem rows of one level share one tint", "status": "active", "source": "ui"},
]
GATE_EVALUATED_SOURCES = ("ui", "core", "audit")
# Core gates (source "core"): the sections of the output of scripts/test_core.py ("== <section>" lines, "FAIL (line N): ..." lines).
# A gate passes only if every listed section appears and no FAIL line follows a listed section. A missing section fails the gate.
# Mapping from DESIGN_V2.md 13.3: W13 BubbleCopy unit tests, W20 the prompt golden samples (structure, length, golden files),
# W21 the pressure percent tests (MemoryTests).
CORE_GATE_SUITES = {
    "W13": ["BubbleCopyTests"],
    "W20": ["PromptBuilder: structure (DESIGN_V2.md 8.4)", "PromptBuilder: length and compression", "Prompt: golden files"],
    "W21": ["MemoryTests"],
}


def core_gate_results(log_text):
    """Return {gate id: (ok, detail)} read from the text of the Core test log. Pure function, tested by --self-test."""
    sections = {}
    current = None
    total_failed = None
    for line in log_text.splitlines():
        line = line.strip()
        if line.startswith("== "):
            current = line[3:]
            sections.setdefault(current, 0)
        elif line.startswith("FAIL (line") and current is not None:
            sections[current] += 1
        elif line.startswith("Result:"):
            m = re.match(r"Result: (\d+) passed, (\d+) failed", line)
            if m:
                total_failed = int(m.group(2))
    results = {}
    for gate_id, names in CORE_GATE_SUITES.items():
        missing = [n for n in names if n not in sections]
        failed = {n: sections[n] for n in names if sections.get(n)}
        if missing:
            results[gate_id] = (False, f"suite not in the Core test log: {missing}")
        elif failed:
            results[gate_id] = (False, f"failed assertions: {failed}")
        elif total_failed is None:
            results[gate_id] = (False, "the Core test log has no Result line")
        else:
            results[gate_id] = (True, f"suites {names} present, 0 failed assertions in them (whole run: {total_failed} failed)")
    return results
gate_by_id = {g["id"]: g for g in GATES}
gate_results = {}  # gate id -> "pass" | "fail" | "skip"; only gates that ran have an entry


def gate_ids(source, status=None):
    return [g["id"] for g in GATES if g["source"] == source and (status is None or g["status"] == status)]


def gate_record(gate_id, result):
    if gate_by_id.get(gate_id, {}).get("status") == "active":
        # One id can be reported twice (W06 has a model part and a window part). A failure is never overwritten by a later pass.
        if gate_results.get(gate_id) != "fail":
            gate_results[gate_id] = result


def gate_summary(results=None, sources=None):
    """Return (lines, counts). Active gates without a result count as failed; pending gates are inactive, never passed."""
    results = gate_results if results is None else results
    counts = {"pass": 0, "fail": 0, "skip": 0, "inactive": 0}
    inactive = []
    for g in GATES:
        if sources is not None and g["source"] not in sources:
            continue
        if g["status"] == "pending":
            counts["inactive"] += 1
            inactive.append(f"{g['id']} {g['name']}")
        else:
            counts[results.get(g["id"], "fail")] += 1
    lines = [f"GATE REGISTRY: {counts['pass']} passed / {counts['fail']} failed / {counts['inactive']} inactive (未激活)"
             f"{' / ' + str(counts['skip']) + ' skipped' if counts['skip'] else ''}"]
    if inactive:
        lines.append("INACTIVE gates (未激活, not passed, not failed): " + "; ".join(inactive))
    return lines, counts


# --- Source audits and layout numbers (read from Sources/, no build needed; --self-test runs them too)
SWIFT_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
# W26 (DESIGN_V3.md 9.2): no " · " join in an interface string. Prompt.swift holds the prompt body and stays out for good.
# The files in DOT_JOIN_PENDING still hold hits that P4 and P6 clean up (docs/CI.md, "W26 待清理清单"). P6 empties this dict.
DOT_JOIN_EXEMPT = {"Sources/Core/Prompt.swift"}
DOT_JOIN_PENDING = {
    "Sources/Core/HealthRules.swift", "Sources/Core/Brief.swift", "Sources/Core/PreviewScenario.swift",
    "Sources/Core/SidebarContent.swift",   # listed in DESIGN_V3.md 9.2
    "Sources/App/PanelTokens.swift", "Sources/Core/NotificationPlanner.swift",   # found by W26 on 2026-10-18, not in 9.2
}
# W27 (DESIGN_V3.md 4.1, 2.1): 17 pt type (PanelType.lead, leadMono, rowValue) only in the headline block, the sidebar title
# and the value of a problem row. On an all-green panel only the headline block shows 17 pt.
# PanelWindow.swift holds the 17 pt title of the sidebar detail view (a sidebar title, DESIGN_V3.md 6).
LARGE_TYPE_FILES = {"Sources/App/PanelHero.swift", "Sources/App/PanelSidebar.swift", "Sources/App/PanelWindow.swift"}
RADIUS_FILES = ("PanelRows.swift", "PanelAnomaly.swift", "PanelFooter.swift", "PanelHero.swift", "PanelRoot.swift")


def read_swift_sources(base):
    """{relative path: text} of every Swift file under Sources/."""
    return {str(f.relative_to(base)): f.read_text(encoding="utf-8") for f in sorted((base / "Sources").rglob("*.swift"))}


def code_lines(text):
    """(line number, line) of the lines that are not comment lines."""
    return [(i, l) for i, l in enumerate(text.splitlines(), 1) if not l.strip().startswith("//")]


def audit_dot_join(files, pending=None):
    """Hits of a string literal that contains ' · ' (also written \\u{00B7}). Returns (enforced hits, waived hits)."""
    pending = DOT_JOIN_PENDING if pending is None else pending
    hits, waived = [], []
    for path, text in files.items():
        if path in DOT_JOIN_EXEMPT:
            continue
        for number, line in code_lines(text):
            for literal in SWIFT_STRING.findall(line):
                if " · " in literal or " \\u{00B7} " in literal or " \\u{B7} " in literal:
                    (waived if path in pending else hits).append(f"{path}:{number}")
    return hits, waived


def audit_large_type(files):
    """Hits of 17 pt type outside the places that DESIGN_V3.md allows."""
    hits = []
    for path, text in files.items():
        name = Path(path).name
        if not (path.startswith("Sources/App/Panel") and name.startswith("Panel")) or name == "PanelTokens.swift":
            continue
        quiet_start = next((n for n, l in code_lines(text) if "struct QuietRowView" in l), None)
        for number, line in code_lines(text):
            if re.search(r"PanelType\.(lead|leadMono)\b", line) and path not in LARGE_TYPE_FILES:
                hits.append(f"{path}:{number} PanelType.lead outside the headline block")
            if re.search(r"PanelType\.rowValue\b", line):
                inside_problem_row = name == "PanelRows.swift" and quiet_start is not None and number < quiet_start
                if not inside_problem_row and path not in LARGE_TYPE_FILES:
                    hits.append(f"{path}:{number} PanelType.rowValue outside a problem row")
            if re.search(r"\bsize:\s*17\b", line) and path not in LARGE_TYPE_FILES:
                hits.append(f"{path}:{number} a literal 17 pt font")
    return hits


def audit_radius(files):
    """W25: the corner radius values are 8 (PanelRadius.control) or full (Capsule, Circle). Returns (hits, number of uses)."""
    hits = []
    uses = 0
    tokens = files.get("Sources/App/PanelTokens.swift", "")
    body = re.search(r"enum PanelRadius \{(.*?)\n\}", tokens, re.S)
    values = re.findall(r"static let (\w+):\s*CGFloat\s*=\s*([0-9.]+)", body.group(1)) if body else []
    if [v for _, v in values] != ["8"] and [float(v) for _, v in values] != [8.0]:
        hits.append(f"PanelRadius holds {values}, expected only 8")
    for path, text in files.items():
        if Path(path).name not in RADIUS_FILES or not path.startswith("Sources/App/"):
            continue
        for number, line in code_lines(text):
            for m in re.finditer(r"cornerRadius:\s*([^,)]+)", line):
                uses += 1
                value = m.group(1).strip()
                if value not in ("PanelRadius.control", "8", "8.0"):
                    hits.append(f"{path}:{number} cornerRadius {value}")
            if re.search(r"\.cornerRadius\(|cornerSize:|UnevenRoundedRectangle|RoundedCorner", line):
                hits.append(f"{path}:{number} a radius form that the audit does not know")
    return hits, uses


def panel_metrics(base):
    """The numbers of PanelMetrics, read from Sources/Core/PanelLayout.swift (the layout formula is checked against them)."""
    text = (base / "Sources/Core/PanelLayout.swift").read_text(encoding="utf-8")
    body = re.search(r"enum PanelMetrics \{(.*?)\n\}", text, re.S).group(1)
    body = "\n".join(l for l in body.splitlines() if not l.strip().startswith("//"))
    return {k: float(v) for k, v in re.findall(r"\b([A-Za-z]+) = ([0-9]+(?:\.[0-9]+)?)\b", body)}


def panel_height_pt(m, problems, has_battery=True):
    """DESIGN_V3.md 3.3, written out here (not read from PanelLayout.height): the panel height in pt."""
    items = 6 if has_battery else 5
    expanded = min(int(m["maxProblemRows"]), max(0, problems))
    quiet_rows = (items - expanded + int(m["quietColumns"]) - 1) // int(m["quietColumns"])
    rows = quiet_rows * m["quietRow"]
    if expanded:
        rows += expanded * m["problemRow"] + (expanded - 1) * m["problemRowGap"]
        if quiet_rows:
            rows += m["problemToQuietGap"]   # 8 pt between the last problem row and the quiet grid (FABLE round 1, item 10)
    return (m["topPadding"] + m["hero"] + m["heroGap"] + rows + m["rowsToRecordGap"] + m["recordRow"]
            + m["recordToFooterGap"] + m["footer"] + m["bottomPadding"])


# Problem rows of each preview case (the anomaly count of PreviewScenario; Tests/CoreTests/LayoutTests.swift checks it). Every case has a battery.
PREVIEW_PROBLEMS = {"allGreen": 0, "cpuYellow": 1, "diskRed": 1, "powerYellow": 1, "multi": 4, "collecting": 0, "stale": 0}
ALL_GREEN_MAX_HEIGHT_PT = 290   # W24, DESIGN_V3.md 3.3


def gate_self_test():
    """Local self-test of the registry logic (runs on any OS): python3 scripts/ci_acceptance.py --self-test"""
    problems = []
    ids = [g["id"] for g in GATES]
    if len(ids) != len(set(ids)):
        problems.append("duplicate gate id")
    for n in (1, 2, 3, 5, 6, 7, 8, 9, 10, 13, 16, 19, 20, 21, 22):
        if f"W{n:02d}" not in gate_by_id:
            problems.append(f"W{n:02d} is not registered")
    for g in GATES:
        if g["status"] not in ("active", "pending"):
            problems.append(f"{g['id']}: bad status {g['status']}")
        if g["source"] not in ("ui", "core", "script", "audit"):
            problems.append(f"{g['id']}: bad source {g['source']}")
        if g["status"] == "active" and g["source"] not in GATE_EVALUATED_SOURCES:
            problems.append(f"{g['id']}: active gate has no evaluator for source {g['source']}")
    # A pending gate is never counted as passed and does not fail the summary.
    _, c = gate_summary({g["id"]: "pass" for g in GATES if g["status"] == "active"})
    if c["fail"] != 0 or c["inactive"] != sum(1 for g in GATES if g["status"] == "pending"):
        problems.append(f"all-pass summary is wrong: {c}")
    if c["pass"] != sum(1 for g in GATES if g["status"] == "active"):
        problems.append("a pending gate was counted as passed")
    # An active gate with no result counts as failed.
    _, c = gate_summary({})
    if c["fail"] != sum(1 for g in GATES if g["status"] == "active"):
        problems.append("an active gate without result is not counted as failed")
    # The legacy lists must keep the exact set the gate has always required.
    expected_ui = list("ABCDEFGHIJKL") + ["M2", "M3", "M4", "M5", "M6", "M11", "M12", "M13", "N1", "N2", "M14", "M19", "M22"]
    expected_ui += [f"W{n:02d}" for n in (1, 2, 3, 5, 6, 7, 8, 9, 10, 16, 19, 22)]
    expected_ui += ["W29", "W30"]   # v3 menu bar runner (DESIGN_V3.md 4.2)
    expected_ui += ["W24", "W25", "W28"]   # v3 panel gates (DESIGN_V3.md 3.3, 5.1)
    if gate_ids("audit", "active") != ["W26", "W27"]:
        problems.append("active audit gate list changed")
    if gate_ids("ui", "active") != expected_ui:
        problems.append("active ui gate list changed")
    good = "== BubbleCopyTests\n== MemoryTests\n== PromptBuilder: structure (DESIGN_V2.md 8.4)\n== PromptBuilder: length and compression\n== Prompt: golden files\nResult: 10 passed, 0 failed\n"
    if not all(ok for ok, _ in core_gate_results(good).values()):
        problems.append("core gate reader: a good log does not pass")
    bad = core_gate_results(good.replace("== MemoryTests\n", "== MemoryTests\nFAIL (line 3): x\n"))
    if bad["W21"][0] or not bad["W13"][0]:
        problems.append("core gate reader: a failed assertion is not attributed to its suite")
    if core_gate_results(good.replace("== BubbleCopyTests\n", ""))["W13"][0]:
        problems.append("core gate reader: a missing suite passes")
    if core_gate_results("")["W20"][0]:
        problems.append("core gate reader: an empty log passes")
    # The audits: positive controls on synthetic text, then the real sources.
    hits, waived = audit_dot_join({"Sources/App/A.swift": 'let x = "a · b"', "Sources/Core/Prompt.swift": 'let y = "a · b"',
                                   "Sources/Core/Brief.swift": 'let z = "a · b"', "Sources/App/B.swift": '// "a · b"\nlet q = "ab"'})
    if hits != ["Sources/App/A.swift:1"] or waived != ["Sources/Core/Brief.swift:1"]:
        problems.append(f"W26 audit logic is wrong: {hits} {waived}")
    if not audit_large_type({"Sources/App/PanelFoo.swift": "Text(x).font(PanelType.lead)"}):
        problems.append("W27 audit logic: a stray PanelType.lead is not found")
    if audit_large_type({"Sources/App/PanelHero.swift": "Text(x).font(PanelType.lead)"}):
        problems.append("W27 audit logic: the headline block is flagged")
    radius_ok = {"Sources/App/PanelTokens.swift": "enum PanelRadius {\n    static let control: CGFloat = 8\n}\n",
                 "Sources/App/PanelRows.swift": "RoundedRectangle(cornerRadius: PanelRadius.control)"}
    if audit_radius(radius_ok)[0] or not audit_radius(dict(radius_ok, **{"Sources/App/PanelRows.swift": "RoundedRectangle(cornerRadius: 12)"}))[0]:
        problems.append("W25 audit logic is wrong")
    if (root / "Sources").exists():
        sources = read_swift_sources(root)
        hits, waived = audit_dot_join(sources)
        if hits:
            problems.append(f"W26 hits in the sources: {hits[:6]}")
        hits = audit_large_type(sources)
        if hits:
            problems.append(f"W27 hits in the sources: {hits[:6]}")
        hits, uses = audit_radius(sources)
        if hits or uses < 6:
            problems.append(f"W25 source audit: {hits[:6]} ({uses} uses)")
        metrics = panel_metrics(root)
        green = panel_height_pt(metrics, 0)
        if green != 264 or green > ALL_GREEN_MAX_HEIGHT_PT or panel_height_pt(metrics, 1) != 344 or panel_height_pt(metrics, 4) != 468:
            problems.append(f"panel height formula: 0 problems {green}, 1 problem {panel_height_pt(metrics, 1)}, 4 problems {panel_height_pt(metrics, 4)}")
    for line in problems:
        print("FAIL  gate self-test: " + line)
    if not problems:
        print(f"PASS  gate self-test: {len(GATES)} gates, {sum(1 for g in GATES if g['status'] == 'pending')} pending")
    return not problems


if "--self-test" in sys.argv[1:]:
    sys.exit(0 if gate_self_test() else 1)


def check(ok, name, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(name)
    return ok


def run(cmd, env=None, timeout=120):
    merged = dict(os.environ)
    merged.update(env or {})
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=merged, timeout=timeout)


def run_streaming(cmd, env=None, timeout=120, echo=("GATE ", "registered check ")):
    """Runs cmd and keeps its full stdout and stderr. Lines that start with an `echo` prefix are printed at once (flushed),
    so the CI log shows the last gate that ended even when the run stops at the timeout. Returns (stdout, stderr, code);
    code is None when the timeout killed the process."""
    import threading
    merged = dict(os.environ)
    merged.update(env or {})
    proc = subprocess.Popen([str(c) for c in cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=merged,
                            errors="replace")
    out, err = [], []

    def read_out():
        for line in proc.stdout:
            out.append(line)
            if line.startswith(echo):
                print("ui-test: " + line.rstrip("\n"), flush=True)

    def read_err():
        for line in proc.stderr:
            err.append(line)

    readers = [threading.Thread(target=read_out, daemon=True), threading.Thread(target=read_err, daemon=True)]
    for t in readers:
        t.start()
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        code = None
    for t in readers:
        t.join(timeout=5)
    return "".join(out), "".join(err), code


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
# The bundle holds no Bichon bitmap or sprite strip any more (U10, 2026-10-18).
check(not (app / "Contents/Resources/DogArt").exists() and not (app / "Contents/Resources/DogSprites").exists(),
      "bundle has no Resources/DogArt and no Resources/DogSprites")
check(not (root / "Resources").exists(), "source tree has no Resources folder")

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
# Panel height of each preview in points: PanelLayout.height (DESIGN_V3.md 3.3) from the problem count of the case, with the numbers read
# from PanelMetrics (panel_metrics, panel_height_pt). 264 pt all green, +64 pt per problem row (+4 pt gap), at most 3 rows.
PM = panel_metrics(root)
PREVIEW_HEIGHT_PT = {case: panel_height_pt(PM, count) for case, count in PREVIEW_PROBLEMS.items()}
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

# 6. M1 and M3: static previews. 7 cases x light and dark x full and empty data = 28 main column files, 352 pt wide at scale 2.
#    The height of a file follows its problem count (v3, DESIGN_V3.md 3.3, docs/CI.md "M3"). Every file is a non-empty PNG.
#    Two files are never equal, except the pair "stale full" and "stale empty" (docs/CI.md "M1 and W01"): the stale panel shows no problem
#    row, no curve and no record count, so the full and the empty data render the same pixels. This is the design, not a defect.
def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


import hashlib

sizes = {}
digests = {}
case_heights = {}
for name in preview_names:
    path = data_dir / name
    data = path.read_bytes() if path.exists() else b""
    size = png_size(data)
    check(size is not None and len(data) > 8000, f"M1 preview {name} is a PNG", f"{len(data)} bytes")
    if size:
        sizes[name] = size
        digests.setdefault(hashlib.sha256(data).hexdigest(), []).append(name)
        case = name.split("-")[1]
        case_heights.setdefault(case, set()).add(size[1])
        print(f"  {name}: {size[0]}x{size[1]} px, {len(data)} bytes", flush=True)
        check(size[0] == 704, f"M3 preview {name} is 352 pt wide", str(size[0]))
        check(abs(size[1] - 2 * PREVIEW_HEIGHT_PT[case]) <= 2,
              f"M3 preview {name} has the height {PREVIEW_HEIGHT_PT[case]:g} pt (PanelLayout.height, {PREVIEW_PROBLEMS[case]} problem rows)", str(size[1]))
        if case == "allGreen":
            check(size[1] / 2 <= ALL_GREEN_MAX_HEIGHT_PT, f"W24 preview {name} is at most {ALL_GREEN_MAX_HEIGHT_PT} pt high", str(size[1] / 2))


def stale_twin(names):
    """True for the pair (stale full, stale empty) of one color scheme."""
    return len(names) == 2 and all(n.startswith("preview-stale-") for n in names) \
        and sorted(n.replace("-empty", "") for n in names)[0] == sorted(n.replace("-empty", "") for n in names)[1]


duplicates = [names for names in digests.values() if len(names) > 1 and not stale_twin(names)]
check(len(preview_names) == 28 and not duplicates, "M1 the 28 previews are pairwise different (stale full and stale empty may be equal)", str(duplicates))
if report:
    check(not report.get("staticPreviewError"), "no preview error", str(report.get("staticPreviewError")))
check(bool(case_heights) and all(len(h) == 1 for h in case_heights.values()),
      "M3 the files of one case have one height (light, dark, full and empty)", str(case_heights))

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
# DESIGN_V2.md 13.2: the audit covers Panel*.swift (with PanelWindow.swift and its UITEST hooks). DogSpriteView.swift was deleted (U10).
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
# W25 (source part), W26, W27: audits of Sources/ (docs/CI.md "v3 门禁改动").
swift_sources = read_swift_sources(root)
_hits, _waived = audit_dot_join(swift_sources)
check(not _hits, "W26 audit: no ' · ' in UI strings", str(_hits))
gate_record("W26", "fail" if _hits else "pass")
print(f"      W26 waived hits (to clean up, docs/CI.md): {len(_waived)} in {sorted({h.split(':')[0] for h in _waived})}", flush=True)
_hits = audit_large_type(swift_sources)
check(not _hits, "W27 audit: 17 pt type only in the headline block, the sidebar title and problem-row values", str(_hits))
gate_record("W27", "fail" if _hits else "pass")
_hits, _uses = audit_radius(swift_sources)
check(not _hits and _uses >= 6, "W25 audit: corner radius is PanelRadius.control (8) in the main column files", f"{_hits} ({_uses} uses)")
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
    # Time budget of the whole UI run, not a quality limit: v2 adds about 20 gates (docs/CI.md, "UI 测试总时长").
    ui_budget = 420
    ui_stdout, ui_stderr, ui_code = run_streaming([ui_bin, "--ui-test", "--ui-test-out", ui_out],
                                                  env={"MOLEMONITOR_DATA_DIR": str(ui_data)}, timeout=ui_budget)
    print(f"ui-test wall time {time.time() - t0:.1f} s, exit code {ui_code}", flush=True)
    print("---- ui-test stdout ----\n" + ui_stdout[-6000:], flush=True)
    print("---- ui-test stderr (tail) ----\n" + ui_stderr[-1500:], flush=True)
    check(ui_code is not None, f"UI test finished within {ui_budget} s")
    report_path = ui_out / "ui-report.json"
    ui_report = json.loads(report_path.read_text()) if report_path.exists() else None
    check(ui_report is not None, "UI test wrote ui-report.json")
    if ui_report:
        by_id = {item["id"]: item for item in ui_report["items"]}
        # DESIGN_V2 13.2.1: W02 replaces the old layout gates M2, M3 and M22 (same checks, v2 selectors).
        if "W02" in by_id:
            for old_id in ("M2", "M3", "M22"):
                alias = dict(by_id["W02"], id=old_id, name=f"{old_id} replaced by W02 (13.2.1)")
                ui_report["items"] = [i for i in ui_report["items"] if i["id"] != old_id] + [alias]
                by_id[old_id] = alias
        for letter in gate_ids("ui", "active"):
            check(letter in by_id, f"UI item {letter} reported")
        for item in ui_report["items"]:
            label = f"UI {item['id']} {item['name']}"
            pending_gate = gate_by_id.get(item["id"], {}).get("status") == "pending"
            if item["status"] == "skipped":
                skipped_ui.append(item)
                gate_record(item["id"], "skip")
                print(f"SKIP  {label}  [{item['note']}]", flush=True)
            elif item["status"] == "pending":
                pass
            elif pending_gate:
                # A registered but inactive gate: shown, never counted as passed, never a failure.
                print(f"INFO  {label} (未激活, not enforced) reported {item['status']}  {item['note']}", flush=True)
            else:
                ok = item["status"] == "pass"
                gate_record(item["id"], "pass" if ok else "fail")
                print(f"{'PASS' if ok else 'FAIL'}  {label}  {item['note']}", flush=True)
                if not ok:
                    failures.append(label)
        # K: the process must have quit through the button with exit code 0 and written status.json at exit
        quit_item = by_id.get("K")
        if quit_item and quit_item["status"] == "pending":
            quit_ok = check(ui_code == 0, "UI K quit button ends the process with exit code 0", str(ui_code))
            status_file = ui_data / "status.json"
            before = ui_report.get("statusMtimeBeforeQuit")
            written = status_file.exists() and before is not None and status_file.stat().st_mtime > before
            written_ok = check(written, "UI K status.json is written at exit", f"mtime before quit {before}")
            gate_record("K", "pass" if quit_ok and written_ok else "fail")
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

# Core gates W13, W20, W21: read from the log of scripts/test_core.py (the workflow tees it to MOLEMONITOR_CORE_LOG).
core_log = os.environ.get("MOLEMONITOR_CORE_LOG")
core_text = Path(core_log).read_text(encoding="utf-8", errors="replace") if core_log and Path(core_log).exists() else ""
if not core_text:
    print("NOTE  MOLEMONITOR_CORE_LOG is not set or the file is missing: the Core gates W13, W20, W21 fail "
          "(run `python3 scripts/test_core.py | tee <file>` and set MOLEMONITOR_CORE_LOG=<file>)", flush=True)
for gate_id, (ok, detail) in core_gate_results(core_text).items():
    gate_record(gate_id, "pass" if ok else "fail")
    check(ok, f"core gate {gate_id} {gate_by_id[gate_id]['name']}", detail)
    if ok:
        print(f"      {detail}", flush=True)

print()
print("(summary of the gates read from ui-report.json and the Core test log; the release binary audit follows below)", flush=True)
for line in gate_summary(sources=("ui", "core", "script", "audit"))[0]:
    print(line, flush=True)
if failures:
    print(f"ACCEPTANCE FAILED: {len(failures)} check(s): " + "; ".join(failures))
    sys.exit(1)
print("ACCEPTANCE PASSED")

# --- release binary audit (DF)
# The release binary has none of the UI test code. The UI test variant has it (positive control).
def _release_binary_checks():
    failures_df = []

    def df_check(ok, name, detail=""):
        print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else ""), flush=True)
        if not ok:
            failures_df.append(name)

    print("\n---- release binary audit (DF) ----", flush=True)
    release = main_bin.read_bytes()
    for marker in (b"DogFrameProbe", b"UITestPanelChecks", b"UITestIconChecks"):
        df_check(marker not in release, f"DF release binary does not contain {marker.decode()}")
    ui_bin = root / "dist-uitest/MoleMonitor.app/Contents/MacOS/MoleMonitor"
    if not ui_bin.exists():
        df_check(False, "DF: dist-uitest/MoleMonitor.app exists")
        return failures_df
    df_check(b"DogFrameProbe" in ui_bin.read_bytes(), "DF UI test variant contains the test probe (positive control)")
    return failures_df


_df_failures = _release_binary_checks()
print()
_final_lines, _final_counts = gate_summary()
for line in _final_lines:
    print(line, flush=True)
if _df_failures:
    print(f"RELEASE BINARY AUDIT FAILED: {len(_df_failures)} check(s): " + "; ".join(_df_failures))
    sys.exit(1)
print("RELEASE BINARY AUDIT PASSED")
