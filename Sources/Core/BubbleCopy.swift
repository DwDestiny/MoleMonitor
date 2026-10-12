// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: BubbleInput: data state, CPU, the problems in order, the night flag and the event (docs/DESIGN_V2.md 4.10, 4.11).
// Output: BubbleText: the main line and the optional second line. BubbleCopy.text(for:) builds them.
// Pos: A1 contract skeleton: the signature is final, the text is a placeholder until WP-D writes the full template table. Foundation only. A1 creates it, WP-D owns it after the A1 merge.

import Foundation

/// One problem as the bubble needs it. `number` is the evidence number of the template (percent, bytes, minutes, ...).
struct BubbleProblem: Equatable {
    var item: HealthItem
    var level: HealthLevel
    var reasonCode: String
    var number: Double?
    /// App display name. Nil when the prompt setting "include app names" is off.
    var app: String?
}

/// A one-time event that replaces the state text for 2.5 s (DESIGN_V2.md 4.8, 4.11).
enum BubbleEvent: Equatable {
    case none
    case petTap(Int)            // Index of the rotating tap texts
    case longPress
    case tooManyTaps
    case petCount(Int)          // Session count, 10 or more
    case copySucceeded(inspection: Bool)
    case copyFailed
    case morning
    case friday
    case noBattery
}

struct BubbleInput: Equatable {
    var dataState: DataState
    var cpuPercent: Double?
    var isNight: Bool
    /// Problems in `ProblemOrder`. The first one is the headline.
    var problems: [BubbleProblem]
    var event: BubbleEvent

    init(dataState: DataState = .fresh, cpuPercent: Double? = nil, isNight: Bool = false,
         problems: [BubbleProblem] = [], event: BubbleEvent = .none) {
        self.dataState = dataState
        self.cpuPercent = cpuPercent
        self.isNight = isNight
        self.problems = problems
        self.event = event
    }
}

struct BubbleText: Equatable {
    /// At most 24 width units (DESIGN_V2.md 0.4). A problem text holds at least one digit.
    var main: String
    /// "还有 N 项需要处理" when there are 2 or more problems.
    var sub: String?
}

enum BubbleCopy {
    /// Placeholder text. The signature is final. WP-D replaces the body with the full template table (4.11).
    static func text(for input: BubbleInput) -> BubbleText {
        let sub: String? = input.problems.count >= 2 ? "还有 \(input.problems.count - 1) 项需要处理" : nil
        if let first = input.problems.first {
            let n = first.number.map { String(Int($0.rounded())) } ?? "—"
            return BubbleText(main: "\(first.item.label) \(n)，需要留意", sub: sub)
        }
        return BubbleText(main: "一切正常，我先趴会儿", sub: nil)
    }
}
