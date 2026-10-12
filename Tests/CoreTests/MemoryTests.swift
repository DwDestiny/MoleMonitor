// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for MemoryBreakdown and the memory pressure percent (docs/DESIGN_V2.md 5.4, 6.3). A1: breakdown only.
// Pos: Called from main.swift via runMemoryTests(); no top-level code in this file. A1 registers it, WP-A (A2) fills it.

import Foundation

func runMemoryTests() {
    section("MemoryTests")
    let full = MemoryBreakdown(app: 20 * GB, wired: 6 * GB, compressed: 4 * GB, total: 64 * GB)
    expect(full.used == 30 * GB, "used = app + wired + compressed")
    expect(full.available == 34 * GB, "available = total - used")
    expect(MemoryBreakdown(app: 1, wired: nil, compressed: 1, total: 10).used == nil, "a missing part gives no used value")
    expect(MemoryBreakdown(app: 1, wired: 1, compressed: 1, total: nil).available == nil, "a missing total gives no available value")
    expect(MemoryBreakdown(app: 9, wired: 9, compressed: 9, total: 10).available == 0, "available is never negative")
    var c = CurrentReadings()
    expect(c.memoryPressurePercent == nil && c.memory == nil && c.diskTotal == nil, "new readings start as not measured")
    c.memoryPressurePercent = 0
    expect(c.memoryPressurePercent == 0, "a measured zero stays zero")
}
