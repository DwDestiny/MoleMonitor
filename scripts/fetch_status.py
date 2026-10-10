#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 DwDestiny
# Input: Fixed official Mole release asset or an existing local cache.
# Output: SHA-256 verified Vendor/mole-status; never installs or executes it.
# Pos: Upstream download boundary for reproducible source builds.
from pathlib import Path
import hashlib
import os
import tempfile
import urllib.request

VERSION = "V1.59.1"
ASSET = "status-darwin-arm64"
URL = f"https://github.com/tw93/Mole/releases/download/{VERSION}/{ASSET}"
SHA256 = "04c412f3dec65781b9e69e8a20bcdaa2d217f27cf0eda52843aea910ade39ef6"
MAX_BYTES = 50 * 1024 * 1024


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def ensure_status(root):
    vendor = root / "Vendor"
    vendor.mkdir(parents=True, exist_ok=True)
    target = vendor / "mole-status"
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file() or digest(target) != SHA256:
            raise RuntimeError("Mole cache failed validation; inspect Vendor/mole-status before retrying.")
        target.chmod(target.stat().st_mode | 0o111)
        return target

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".mole-status-", dir=vendor, delete=False) as output:
            temporary = Path(output.name)
            request = urllib.request.Request(URL, headers={"User-Agent": "MoleMonitor-source-build"})
            with urllib.request.urlopen(request, timeout=30) as response:
                if not response.geturl().startswith("https://"):
                    raise RuntimeError("Mole download did not remain on HTTPS.")
                total = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise RuntimeError("Mole download exceeded the expected size limit.")
                    output.write(chunk)
        if digest(temporary) != SHA256:
            raise RuntimeError("Mole download SHA-256 mismatch; refusing to use it.")
        temporary.chmod(0o755)
        os.replace(temporary, target)
        return target
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    print(ensure_status(Path(__file__).resolve().parent.parent))
