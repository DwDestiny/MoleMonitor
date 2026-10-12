// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for BubbleCopy (docs/DESIGN_V2.md 4.10, 4.11, gate W13). A1: signature and placeholder only.
// Pos: Called from main.swift via runBubbleCopyTests(); no top-level code in this file. A1 registers it, WP-D fills it.

import Foundation

func runBubbleCopyTests() {
    section("BubbleCopyTests")
    expect(!BubbleCopy.text(for: BubbleInput()).main.isEmpty, "a quiet input has a text")
    let p = BubbleProblem(item: .disk, level: .red, reasonCode: "x", number: 18, app: nil)
    let two = BubbleCopy.text(for: BubbleInput(problems: [p, p]))
    expect(two.main.contains("18") && two.sub != nil, "a problem text has a digit and 2 problems give a second line")
}
