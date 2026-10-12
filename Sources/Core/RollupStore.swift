// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Rollup files rollup-YYYY-MM.ndjson in the data directory (docs/DESIGN_V2.md 12.2 D1).
// Output: RollupWindow (one 5 minute window) and RollupStore.read, which returns the windows in a time range.
// Pos: A1 contract skeleton: the types and the read signature are final, the read returns an empty result until A2 fills it in. Foundation only. Owner WP-A.

import Foundation

/// One 5 minute window. Units follow the file keys: swap in MB, rx and tx in KB/s. Nil means missing, not zero.
struct RollupWindow: Codable, Equatable {
    /// `t`: end of the window (UTC).
    var end: Date
    /// `n`: coarse points in the window (10 for a full window).
    var pointCount: Int
    /// `cpu`: mean and peak, percent.
    var cpuMean: Double?
    var cpuPeak: Double?
    /// `pp`: memory pressure percent, mean and peak. Absent when the pressure percent was missing.
    var pressureMean: Double?
    var pressurePeak: Double?
    /// `sw`: swap used at the end of the window, MB.
    var swapMB: Int64?
    /// `mp`: highest pressure level in the window.
    var pressure: MemoryPressure?
    /// `th`: highest thermal state in the window.
    var thermal: ThermalLevel?
    /// `bat`: battery percent at the end of the window. Absent without a battery.
    var batteryPercent: Double?
    /// `ps`: power source.
    var power: PowerSource?
    /// `rx`, `tx`: mean rates, KB/s.
    var rxKBps: Double?
    var txKBps: Double?
}

/// Result of a read. Damaged lines are skipped and counted, as for `disk-*.ndjson`.
struct RollupReadResult: Equatable {
    var windows: [RollupWindow]
    var skippedLines: Int
    static let empty = RollupReadResult(windows: [], skippedLines: 0)
}

enum RollupStore {
    static let filePrefix = "rollup-"
    static let version = 1
    /// Window length in seconds.
    static let windowSeconds: TimeInterval = 300

    /// The windows whose end time lies in `from ... to`, ascending. Skeleton: always empty (filled in A2).
    static func read(dir: URL, from: Date, to: Date) -> RollupReadResult {
        .empty
    }
}
