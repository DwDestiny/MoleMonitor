// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points and a data directory (docs/DESIGN.md 6.4, 8.1).
// Output: trend.json encode, decode, atomic write (0600) and tolerant load.
// Pos: Persistence of the coarse trend so a restart keeps the 2 hour curve; Foundation only. Owner I1.
// SKELETON: encode returns empty data, decode and load return no points, write does nothing.

import Foundation

enum TrendStore {
    static let fileName = "trend.json"

    static func encode(_ points: [TrendPoint]) throws -> Data {
        Data() // SKELETON
    }

    /// A wrong version, a damaged file or unequal lengths give an empty array. Points outside the window are dropped.
    /// An older file without `bat` or `ps` reads as all nil.
    static func decode(_ data: Data, now: Date, maxAge: TimeInterval = 7200) -> [TrendPoint] {
        [] // SKELETON
    }

    /// Atomic write, mode 0600.
    static func write(_ points: [TrendPoint], dir: URL) throws {
        // SKELETON: writes nothing.
    }

    static func load(dir: URL, now: Date) -> [TrendPoint] {
        [] // SKELETON
    }
}
