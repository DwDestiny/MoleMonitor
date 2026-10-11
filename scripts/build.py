#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: Swift sources under Sources/ and the license files.
# Output: dist/MoleMonitor.app with the app, the molemonitor-cli helper and ad-hoc signatures; no download, no installation, no UI launch.
#         With --ui-test: dist-uitest/MoleMonitor.app, built with -D UITEST (adds the UI regression harness; never shipped).
# Pos: Reproducible local build; needs arm64 macOS 14+ and the Xcode command line tools.
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
swiftc = "/usr/bin/swiftc"
codesign = "/usr/bin/codesign"
target = "arm64-apple-macos14.0"
ui_test = "--ui-test" in sys.argv[1:]
unknown = [a for a in sys.argv[1:] if a != "--ui-test"]
# The test variant has its own folder, so the release build in dist/ is never touched.
app = root / ("dist-uitest/MoleMonitor.app" if ui_test else "dist/MoleMonitor.app")


def fail(message):
    sys.exit(f"build.py: {message}")


def run(command):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    result = subprocess.run([str(part) for part in command])
    if result.returncode != 0:
        fail(f"command failed with exit code {result.returncode}: {Path(str(command[0])).name}")


def read_version():
    text = (root / "Sources/Core/AppInfo.swift").read_text(encoding="utf-8")
    match = re.search(r'static\s+let\s+version\s*=\s*"(\d+\.\d+\.\d+)"', text)
    if not match:
        fail('cannot read `static let version = "x.y.z"` from Sources/Core/AppInfo.swift')
    return match.group(1)


def swift_files(folder):
    return sorted((root / folder).glob("*.swift"))


if unknown:
    fail("unknown argument: " + " ".join(unknown) + " (only --ui-test is accepted)")
if sys.platform != "darwin":
    fail("this script builds the macOS app and must run on macOS 14 or later")

version = read_version()
core = swift_files("Sources/Core")
app_files = swift_files("Sources/App")
entry = root / "Sources/MoleMonitor.swift"
sensors = root / "Sources/Sensors.swift"
cli_main = root / "Sources/cli/main.swift"
if not core:
    fail("no Swift files in Sources/Core")
if not app_files:
    fail("no Swift files in Sources/App")
for required in (entry, sensors):
    if not required.exists():
        fail(f"missing {required.relative_to(root)}")
if not cli_main.exists():
    fail("missing Sources/cli/main.swift (the CLI source); the build does not skip the CLI")

# Remove only the generated app of this project, so no stale resource stays in the bundle.
if app.exists():
    shutil.rmtree(app)
macos = app / "Contents/MacOS"
helpers = app / "Contents/Helpers"
resources = app / "Contents/Resources"
for folder in (macos, helpers, resources):
    folder.mkdir(parents=True, exist_ok=True)

# App: -parse-as-library because MoleMonitor.swift uses @main.
# Charts (Swift Charts, system framework since macOS 13) draws the problem curves, the mini lines and the disk trend in Sources/App/Panel*.swift.
run([
    swiftc, "-swift-version", "5", "-O", "-parse-as-library", "-target", target,
    *(["-D", "UITEST"] if ui_test else []),
    *core, *app_files, entry, sensors,
    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
    "-framework", "UserNotifications", "-framework", "Combine", "-framework", "Charts",
    "-o", macos / "MoleMonitor",
])

# CLI: no -parse-as-library because main.swift has top-level code; Foundation only.
cli = helpers / "molemonitor-cli"
run([
    swiftc, "-swift-version", "5", "-O", "-target", target,
    *core, cli_main,
    "-o", cli,
])

shutil.copy2(root / "LICENSE", resources / "LICENSE-MoleMonitor")
for name in ("LICENSE-SMCKit", "LICENSE-Stats"):
    shutil.copy2(root / "Vendor" / name, resources / name)
shutil.copy2(root / "Vendor/NOTICE.md", resources / "Source-Attribution.md")

info = {
    "CFBundleExecutable": "MoleMonitor",
    "CFBundleIdentifier": "io.github.dwdestiny.MoleMonitor",
    "CFBundleName": "MoleMonitor", "CFBundleDisplayName": "Mole Monitor",
    "CFBundleVersion": "1", "CFBundleShortVersionString": version,
    "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    "NSHighResolutionCapable": True,
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

# Ad-hoc signatures: helper first, then the whole app.
run([codesign, "--force", "--sign", "-", cli])
run([codesign, "--force", "--sign", "-", app])
print(app)
