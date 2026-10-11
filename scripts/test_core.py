#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: Sources/Core/*.swift and Tests/CoreTests/*.swift (main.swift holds the only top-level code).
# Output: Compiles the Core tests into a temp directory and runs them; non-zero exit code means failure.
# Pos: Local check for the Foundation-only Core module (works on Linux and macOS).
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent


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


sources = sorted(str(p) for p in (root / "Sources/Core").glob("*.swift"))
tests = sorted(str(p) for p in (root / "Tests/CoreTests").glob("*.swift"))
if not sources or not (root / "Tests/CoreTests/main.swift").exists():
    sys.exit("Core sources or Tests/CoreTests/main.swift not found.")

with tempfile.TemporaryDirectory(prefix="molemonitor-core-") as tmp:
    binary = Path(tmp) / "core-tests"
    compiler = find_compiler()
    print(f"Compiler: {compiler}", flush=True)
    build = subprocess.run([compiler, *sources, *tests, "-o", str(binary)])
    if build.returncode != 0:
        sys.exit(f"Compile failed with exit code {build.returncode}.")
    # Golden prompt files live in Tests/CoreTests/Golden. UPDATE_GOLDEN=1 rewrites them.
    env = dict(os.environ)
    env.setdefault("GOLDEN_DIR", str(root / "Tests/CoreTests/Golden"))
    run = subprocess.run([str(binary)], env=env)
    sys.exit(run.returncode)
