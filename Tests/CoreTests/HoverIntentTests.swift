// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for HoverIntent (docs/DESIGN_V2.md 10.6, gate W06). A1: constants only.
// Pos: Called from main.swift via runHoverIntentTests(); no top-level code in this file. A1 registers it, WP-B fills it.

import Foundation

func runHoverIntentTests() {
    section("HoverIntentTests")
    expect(HoverIntent.openDelay == 0.350, "open delay is 350 ms")
    expect(HoverIntent.leaveCloseDelay == 1.0, "leave delay is 1.0 s")
    var h = HoverIntent()
    expect(h.handle(.escape, at: 0).isEmpty && h.nextDeadline == nil, "skeleton emits nothing")
}
