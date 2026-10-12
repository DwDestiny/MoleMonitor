// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for RollupStore and EventLog (docs/DESIGN_V2.md 12.2 D1, D2). A1: empty reads only.
// Pos: Called from main.swift via runStorageTests(); no top-level code in this file. A1 registers it, WP-A (A2) fills it.

import Foundation

func runStorageTests() {
    section("StorageTests")
    let dir = FileManager.default.temporaryDirectory
    let r = RollupStore.read(dir: dir, from: now.addingTimeInterval(-3600), to: now)
    expect(r == RollupReadResult.empty, "rollup read is empty in the skeleton")
    expect(EventLog.read(dir: dir, days: 7, now: now).isEmpty, "event read is empty in the skeleton")
}
