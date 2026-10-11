// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts (docs/DESIGN.md 2.4, 8.1).
// Output: Problem items and all items in display order; the prompt topic of an item.
// Pos: One shared order for lamps, cards, the icon badge and the prompt; Foundation only. Owner I1.
//      Keys: level (red first), duration (longer first), fixed priority.
//      Two starts less than 60 s apart count as equal. A chain of such starts forms one group, so the result
//      does not depend on the input order (a pairwise tolerance would not be transitive).

import Foundation

enum ProblemOrder {
    static let sameStartTolerance: TimeInterval = 60

    /// Only yellow and red, sorted by level, duration, fixed priority.
    static func problems(_ verdicts: [ItemVerdict]) -> [ItemVerdict] {
        let items = verdicts.filter { $0.isProblem }
        var out = [ItemVerdict]()
        for level in [HealthLevel.red, HealthLevel.yellow] {
            out.append(contentsOf: orderSameLevel(items.filter { $0.level == level }))
        }
        return out
    }

    /// All items: problem items first (sorted), then normal items by fixed priority.
    static func all(_ verdicts: [ItemVerdict]) -> [ItemVerdict] {
        let rest = verdicts.filter { !$0.isProblem }.sorted { $0.item.fixedPriority < $1.item.fixedPriority }
        return problems(verdicts) + rest
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

    private static func orderSameLevel(_ items: [ItemVerdict]) -> [ItemVerdict] {
        // Earlier start first. An item without a start time counts as the newest.
        let byStart: [ItemVerdict] = items.sorted { a, b in
            switch (a.since, b.since) {
            case let (x?, y?): return x != y ? x < y : a.item.fixedPriority < b.item.fixedPriority
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.item.fixedPriority < b.item.fixedPriority
            }
        }
        var groups = [[ItemVerdict]]()
        for v in byStart {
            if var last = groups.last, let lastStart = last.last?.since, let start = v.since,
               start.timeIntervalSince(lastStart) < sameStartTolerance {
                last.append(v)
                groups[groups.count - 1] = last
            } else if let last = groups.last, last.last?.since == nil, v.since == nil {
                groups[groups.count - 1].append(v)
            } else {
                groups.append([v])
            }
        }
        var out = [ItemVerdict]()
        for g in groups { out.append(contentsOf: g.sorted { $0.item.fixedPriority < $1.item.fixedPriority }) }
        return out
    }
}
