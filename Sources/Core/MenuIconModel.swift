// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts and the data state (docs/DESIGN.md 3.2, 3.3, 3.6, 8.1).
// Output: The menu bar icon state (posture and badge) and its accessibility text.
// Pos: Pure mapping from health to icon; no drawing. Foundation only. Owner I2.
// SKELETON: the state is always relaxed without a badge. The text is a fixed string.

import Foundation

enum MenuPosture: String, CaseIterable { case relaxed, raised, pant, hollow }   // Ears relaxed, ears raised, tongue out, hollow
struct MenuBadge: Hashable { var item: HealthItem }   // The badge shows the category only, not yellow or red
struct MenuIconState: Hashable {
    var posture: MenuPosture
    var badge: MenuBadge?
}

enum MenuIconModel {
    static func state(_ verdicts: [ItemVerdict], dataState: DataState) -> MenuIconState {
        MenuIconState(posture: .relaxed, badge: nil) // SKELETON
    }

    static func text(_ verdicts: [ItemVerdict], dataState: DataState, now: Date) -> String {
        "MoleMonitor" // SKELETON
    }
}
