// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for CapacityText (docs/DESIGN_V2.md 6.3, gates W19, W21). A1: SidebarItem only; WP-C adds CapacityText.
// Pos: Called from main.swift via runCapacityTests(); no top-level code in this file. A1 registers it, WP-C fills it.

import Foundation

func runCapacityTests() {
    section("CapacityTests")
    expect(SidebarItem.allCases.count == 7, "six items and the anomaly log")
    expect(SidebarItem.allCases.map { $0.label }.contains("异常记录"), "anomaly log label")
}
