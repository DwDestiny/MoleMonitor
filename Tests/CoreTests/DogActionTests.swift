// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for DogAction and DogActionInput (docs/DESIGN_V2.md 4.3, 4.4, gate W13). A1: type shape only.
// Pos: Called from main.swift via runDogActionTests(); no top-level code in this file. A1 registers it, WP-D fills it.

import Foundation

func runDogActionTests() {
    section("DogActionTests")
    expect(DogAction.allCases.count == 10, "ten actions in the first release")
    expect(DogAction.lieIdle.rawValue == "lie_idle" && DogAction.sitGray.rawValue == "sit_gray", "raw values are the strip names")
    expect(DogActionInput().dataState == .fresh && DogActionInput().oneShot == nil, "default input is fresh without a one-shot")
}
