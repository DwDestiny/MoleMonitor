// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Sleep records (battery before and after a sleep) from the engine; sleeps.json in the data directory.
// Output: The newest records, restored after a restart; a snapshot type for `--diagnose` and the tests of other modules.
// Pos: Small persistence for the sleep drain rule (docs/DESIGN.md 6.8); Foundation only. Owner I1.
//      A record is 5 numbers. At most 8 records and 7 days are kept. A garbled file gives an empty list.

import Foundation

enum SleepStore {
    static let fileName = "sleeps.json"
    static let maxRecords = 8
    static let maxAge: TimeInterval = 7 * 86400

    /// Appends `record` to `list`, drops old entries and keeps the newest `maxRecords`.
    static func adding(_ record: SleepRecord, to list: [SleepRecord], now: Date) -> [SleepRecord] {
        var all = list
        all.append(record)
        all = all.filter { now.timeIntervalSince($0.wokeAt) <= maxAge }
        all.sort { $0.wokeAt < $1.wokeAt }
        return Array(all.suffix(maxRecords))
    }

    static func write(_ list: [SleepRecord], dir: URL) throws {
        let data = try CoreJSON.encoder().encode(list)
        try AtomicFile.write(data, to: dir.appendingPathComponent(fileName))
    }

    static func load(dir: URL, now: Date) -> [SleepRecord] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let list = try? CoreJSON.decoder().decode([SleepRecord].self, from: data) else { return [] }
        let valid = list.filter { $0.wokeAt > $0.sleptAt && $0.wokeAt <= now.addingTimeInterval(60) && now.timeIntervalSince($0.wokeAt) <= maxAge }
        return Array(valid.sorted { $0.wokeAt < $1.wokeAt }.suffix(maxRecords))
    }
}

/// What `--diagnose` prints about the data layer (docs/DESIGN.md 8.2): real readings, the top apps and the timer count.
/// Added by I1 for I3, who merges it into the diagnose report.
struct DiagnosticSnapshot: Codable, Equatable {
    struct ItemLine: Codable, Equatable {
        var item: String
        var level: String
        var reasonCode: String
        var headline: String
    }

    var sampledAt: Date?
    var cpuPercent: Double?
    var cpuMean5m: Double?
    var memoryPressure: String?
    var swapUsedBytes: Int64?
    var thermalState: String?
    var batteryPercent: Double?
    var powerSource: String?
    var physicalMemoryBytes: Int64?
    var items: [ItemLine]
    var topApps: [AppUsage]
    var appsBasis: String
    var processesReadable: Int?
    var processesUnreadable: Int?
    var trendCoarsePoints: Int
    var trendFinePoints: Int
    /// Dispatch timers alive now: 1 with the card closed, 2 while the 2 second timer runs.
    var timerCount: Int
    /// Seconds between two process scans for the current state: 300, 180 or 4.
    var processScanPeriod: Double
    var panelOpen: Bool
}
