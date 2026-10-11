// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points, app windows, sleep records and the current time (docs/DESIGN.md 8.1, 6.8).
// Output: One ItemVerdict per health item, with hysteresis state kept in RuleMemory.
// Pos: CPU, memory, thermal and power rules; pure functions, Foundation only. Owner I1.
// SKELETON: every function returns a fixed placeholder verdict. No rule is implemented yet.

import Foundation

struct RuleMemory: Codable, Equatable {
    // SKELETON: I1 adds the hysteresis state and the problem start time of each health item.
}

private func skeletonVerdict(_ item: HealthItem) -> ItemVerdict {
    // SKELETON: unknown level, no start time.
    ItemVerdict(item: item, level: .unknown, reasonCode: "skeleton", headline: "", since: nil,
                levelChangedAt: nil, alert: nil)
}

enum CPUHealth {
    static func evaluate(points: [TrendPoint], apps: [AppWindowStat], now: Date,
                         state: inout RuleMemory) -> ItemVerdict {
        skeletonVerdict(.cpu) // SKELETON
    }
}

enum MemoryHealth {
    static func evaluate(points: [TrendPoint], physicalBytes: Int64, now: Date,
                         state: inout RuleMemory) -> ItemVerdict {
        skeletonVerdict(.memory) // SKELETON
    }

    static func swapTrend(points: [TrendPoint], physicalBytes: Int64, now: Date) -> SwapTrend? {
        nil // SKELETON
    }
}

enum ThermalHealth {
    static func evaluate(points: [TrendPoint], now: Date, state: inout RuleMemory) -> ItemVerdict {
        skeletonVerdict(.thermal) // SKELETON
    }
}

/// A record from one battery reading before sleep and one after. It is not created when one reading is missing.
struct SleepRecord: Codable, Equatable {
    var sleptAt: Date
    var wokeAt: Date
    var batteryBefore: Double
    var batteryAfter: Double
    var onBatteryBeforeSleep: Bool
}

enum PowerHealth {
    /// A Mac without a battery returns nil and the power item does not appear.
    /// Sleep drain follows PROJECT.md 3.6. Awake drain is in DESIGN.md 6.8.
    static func evaluate(points: [TrendPoint], sleeps: [SleepRecord], hasBattery: Bool,
                         now: Date, state: inout RuleMemory) -> ItemVerdict? {
        nil // SKELETON
    }
}
