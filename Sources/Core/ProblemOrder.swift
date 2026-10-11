// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts (docs/DESIGN.md 2.4, 8.1).
// Output: Problem items and all items in display order; the prompt topic of an item.
// Pos: One shared order for lamps, cards, the icon badge and the prompt; Foundation only. Owner I1.
// SKELETON: no sorting. Problem items keep the input order. I1 adds the level, duration and priority keys.

import Foundation

enum ProblemOrder {
    /// Only yellow and red, sorted by level, duration, fixed priority.
    static func problems(_ verdicts: [ItemVerdict]) -> [ItemVerdict] {
        verdicts.filter { $0.level == .yellow || $0.level == .red } // SKELETON: input order
    }

    /// All items: problem items first (sorted), then normal items by fixed priority.
    static func all(_ verdicts: [ItemVerdict]) -> [ItemVerdict] {
        let problemItems = problems(verdicts)
        let rest = verdicts.filter { !($0.level == .yellow || $0.level == .red) }
        return problemItems + rest // SKELETON: input order
    }

    static func topic(for item: HealthItem) -> PromptTopic? {
        switch item {
        case .disk: return .disk
        case .memory: return .memory
        case .cpu: return .cpu
        case .thermal: return .thermal
        case .power: return .power
        }
    }
}
