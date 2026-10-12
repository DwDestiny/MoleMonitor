// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the five menu bar icon states (docs/DESIGN_V2.md 9.2, gate W08). A1: kind mapping only.
// Pos: Called from main.swift via runMenuIconTests(); no top-level code in this file. A1 registers it, WP-E fills it.

import Foundation

func runMenuIconTests() {
    section("MenuIconTests")
    expect(MenuIconKind.allCases.count == 5, "five states")
    let green = HealthItem.allCases.map { ItemVerdict(item: $0, level: .green, reasonCode: "x", headline: "x", since: nil, levelChangedAt: nil, alert: nil) }
    expect(MenuIconModel.kind(green, dataState: .fresh) == .normal, "all green is normal")
    expect(MenuIconModel.kind(green, dataState: .collecting) == .collecting, "collecting")
    expect(MenuIconModel.kind(green, dataState: .stale(now)) == .stale, "stale")
    var yellow = green
    yellow[0].level = .yellow
    yellow[0].since = now
    expect(MenuIconModel.kind(yellow, dataState: .fresh) == .caution, "yellow is caution")
    yellow[0].level = .red
    expect(MenuIconModel.kind(yellow, dataState: .fresh) == .alert, "red is alert")
}
