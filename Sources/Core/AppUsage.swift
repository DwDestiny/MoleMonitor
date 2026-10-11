// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Process samples from two scans (docs/DESIGN.md 6.6, 8.1).
// Output: Per-app CPU and memory usage and the top list.
// Pos: Pure app ranking logic behind "占用 App"; Foundation only. Owner I1.
// SKELETON: AppRanking returns empty lists.

import Foundation

struct ProcessSample: Equatable {
    var pid: Int32
    var startAbs: UInt64
    var name: String
    var appKey: String          // Bundle id or "proc:<name>"
    var displayName: String
    var bundleID: String?
    var cpuTimeNs: UInt64
    var footprint: UInt64?
    var rss: UInt64?
    var isSystem: Bool
}

struct AppUsage: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var bundleID: String?
    var cpuPercent: Double?
    var memoryBytes: Int64?
    var memoryBasis: String     // "footprint" or "rss"
    var processCount: Int
    var isSystem: Bool
    var id: String { key }
}

struct ProcessCoverage: Codable, Equatable {
    var readable: Int
    var unreadable: Int
}

enum AppSortKey { case cpu, memory }

/// Window means of one app for the single-app CPU rule (PROJECT.md 3.2): yellow at a 30 minute mean of 90 %
/// (one core = 100 %), exit below a 10 minute mean of 50 %. Not listed in DESIGN.md 8.1 at skeleton time;
/// added because `CPUHealth.evaluate` needs it.
struct AppWindowStat: Codable, Equatable {
    var key: String
    var name: String
    var mean10m: Double?
    var mean30m: Double?
}

enum AppRanking {
    static let defaultIgnore: Set<String> = [] // SKELETON: I1 fills the default ignore list (PROJECT.md 3.2).

    static func usage(previous: [ProcessSample], current: [ProcessSample], seconds: Double,
                      ignore: Set<String>) -> [AppUsage] {
        [] // SKELETON
    }

    static func top(_ apps: [AppUsage], by key: AppSortKey, count: Int = 5) -> [AppUsage] {
        [] // SKELETON
    }
}
