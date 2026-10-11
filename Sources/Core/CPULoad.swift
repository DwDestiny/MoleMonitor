// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Per-core CPU tick counters (user, system, idle, nice) from two readings.
// Output: Whole-machine CPU use in percent (0 to 100), or nil when the two readings cannot be compared.
// Pos: Pure logic for the live CPU chart; the Mac-only reader is Sources/App/LiveSampler.swift.

import Foundation

/// Tick counters of one core. Mach gives 32-bit counters; they are kept in 64 bits here.
struct CPUTicks: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

enum CPULoad {
    /// Busy ticks over total ticks of all cores between `prev` and `now`, times 100.
    /// Nil when the core counts differ or are zero, when any counter went down (wrap-around or reset),
    /// or when no tick passed (total difference 0). A measured idle machine gives 0, not nil.
    static func percent(prev: [CPUTicks], now: [CPUTicks]) -> Double? {
        guard !prev.isEmpty, prev.count == now.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (a, b) in zip(prev, now) {
            guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
            busy += (b.user - a.user) + (b.system - a.system) + (b.nice - a.nice)
            total += (b.user - a.user) + (b.system - a.system) + (b.nice - a.nice) + (b.idle - a.idle)
        }
        guard total > 0 else { return nil }
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }
}
