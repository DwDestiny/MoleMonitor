// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None.
// Output: App version string shared by the app, the CLI and status.json.
// Pos: Single source of the version; scripts/build.py reads it for Info.plist.

enum AppInfo {
    static let version = "0.2.0"
}
