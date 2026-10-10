#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: Swift sources, verified upstream status download, and licenses.
# Output: dist/MoleMonitor.app; no installation or UI launch.
# Pos: Reproducible local build.
from pathlib import Path
import subprocess
import plistlib
import shutil
from fetch_status import ensure_status

root = Path(__file__).resolve().parent.parent
status_binary = ensure_status(root)
app = root / "dist/MoleMonitor.app"
macos = app / "Contents/MacOS"
resources = app / "Contents/Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "/usr/bin/swiftc", "-swift-version", "5", "-O", "-parse-as-library",
    "-target", "arm64-apple-macos14.0",
    str(root / "Sources/MoleMonitor.swift"), str(root / "Sources/Sensors.swift"),
    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
    "-o", str(macos / "MoleMonitor"),
], check=True)
shutil.copy2(status_binary, resources / "mole-status")
shutil.copy2(root / "LICENSE", resources / "LICENSE-MoleMonitor")
shutil.copy2(root / "Vendor/LICENSE-Mole", resources / "LICENSE-Mole")
for name in ("LICENSE-SMCKit", "LICENSE-Stats"):
    shutil.copy2(root / "Vendor" / name, resources / name)
shutil.copy2(root / "Vendor/NOTICE.md", resources / "Source-Attribution.md")
info = {
    "CFBundleExecutable": "MoleMonitor",
    "CFBundleIdentifier": "io.github.dwdestiny.MoleMonitor",
    "CFBundleName": "MoleMonitor", "CFBundleDisplayName": "Mole Monitor",
    "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
    "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    "NSHighResolutionCapable": True,
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(resources / "mole-status")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
