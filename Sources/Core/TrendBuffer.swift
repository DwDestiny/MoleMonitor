// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points from the engine (one per 30 s coarse, one per 2 s fine while the card is open).
// Output: TrendSeries split at gaps, and the 2 hour CPU summary (docs/DESIGN.md 6.3, 8.1).
// Pos: In-memory ring buffer behind the trend strip and the problem charts; Foundation only. Owner I1.
// SKELETON: the buffer stores nothing and returns empty values.

import Foundation

struct TrendPoint: Codable, Equatable {
    var t: Date
    var cpu: Double?
    var rx: Double?
    var tx: Double?
    var swapUsed: Int64?
    var battery: Double?            // Battery percent. Nil when the Mac has no battery.
    var pressure: MemoryPressure?
    var thermal: ThermalLevel?
    var power: PowerSource?
}

struct CPUSummary: Codable, Equatable {
    var mean: Double
    var peak: Double
}

struct TrendSeries: Equatable {
    /// Segments split at gaps. Each segment is in ascending time order.
    var segments: [[TrendPoint]]
    var latest: TrendPoint? { segments.last?.last }
    static let empty = TrendSeries(segments: [])
}

struct TrendBuffer {
    static let coarseInterval: TimeInterval = 30
    static let coarseCapacity = 240
    static let fineInterval: TimeInterval = 2
    static let fineCapacity = 150

    mutating func appendCoarse(_ p: TrendPoint) {
        // SKELETON: stores nothing.
    }

    mutating func appendFine(_ p: TrendPoint) {
        // SKELETON: stores nothing.
    }

    mutating func clearFine() {
        // SKELETON: nothing to clear.
    }

    var coarse: [TrendPoint] { [] } // SKELETON

    /// Merges the coarse and fine parts, splits at gaps. The default window is 2 hours.
    func series(now: Date, window: TimeInterval = 7200) -> TrendSeries {
        .empty // SKELETON
    }

    static func segments(_ points: [TrendPoint], maxGap: TimeInterval) -> [[TrendPoint]] {
        [] // SKELETON
    }

    /// 2 hour CPU mean and peak for the prompt and status.json.
    func cpuSummary(now: Date) -> CPUSummary? {
        nil // SKELETON
    }
}
