// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None.
// Output: SleepBlocker, the same type that WP-A2 declares in AppUsage.swift (branch v2/wp-a2).
// Pos: COMPAT. WP-C needs the type before the A2 merge. DELETE THIS FILE when v2/wp-a2 merges, or the build has two declarations.
//      The fields and kindText match the A2 declaration exactly.

import Foundation

/// An app that holds a power assertion (DESIGN_V2.md 6.5). Display name and the two kinds only.
struct SleepBlocker: Codable, Equatable {
    var name: String
    var preventsSystemSleep: Bool
    var preventsDisplaySleep: Bool

    /// "防止系统睡眠", "防止显示器睡眠" or both joined by "、".
    var kindText: String {
        var parts = [String]()
        if preventsSystemSleep { parts.append("防止系统睡眠") }
        if preventsDisplaySleep { parts.append("防止显示器睡眠") }
        return parts.joined(separator: "、")
    }
}
