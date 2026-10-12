// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: events.json in the data directory (docs/DESIGN_V2.md 12.2 D2).
// Output: EventRecord (one problem stretch), EventLog (read, atomic write, limits) and EventTracker (level changes -> records).
// Pos: Storage behind the anomaly log (DESIGN_V2.md 7.4, 12.2 D2); Foundation only. Owner WP-A.
//      Only the display name of an app is kept. No path, no argument, no user name.

import Foundation

/// One problem stretch of one item.
struct EventRecord: Codable, Equatable {
    var item: HealthItem
    /// Level at the start and the worst level of the stretch.
    var first: HealthLevel
    var peak: HealthLevel
    var reasonCode: String
    var start: Date
    /// Nil while the problem goes on.
    var end: Date?
    var peakValue: Double?
    var unit: String?
    /// Display name only. Nil when the prompt setting "include app names" is off.
    var app: String?
    /// True when the end time was estimated (the app was not running when the problem ended).
    var endEstimated: Bool
}

enum EventLog {
    static let fileName = "events.json"
    static let version = 1
    /// At most 200 records, 30 days and 50 KB.
    static let maxRecords = 200
    static let maxDays = 30
    static let maxBytes = 50_000

    // MARK: Record format (DESIGN_V2.md 12.2 D2)

    private static func level(_ s: String?) -> HealthLevel? {
        guard let s, let l = HealthLevel(rawValue: s), l == .yellow || l == .red else { return nil }
        return l
    }

    static func object(_ r: EventRecord) -> [String: Any] {
        var o: [String: Any] = [
            "v": version, "item": r.item.rawValue, "first": r.first.rawValue, "peak": r.peak.rawValue,
            "reason": r.reasonCode, "start": UTCTime.iso(r.start), "endEstimated": r.endEstimated,
        ]
        o["end"] = r.end.map { UTCTime.iso($0) } ?? NSNull()
        o["peakValue"] = (r.peakValue.flatMap { $0.isFinite ? $0 : nil }) ?? NSNull()
        o["unit"] = r.unit ?? NSNull()
        o["app"] = r.app ?? NSNull()
        return o
    }

    /// Nil for a record with a wrong version, an unknown item or level, a bad time or an end before the start.
    static func record(_ o: [String: Any]) -> EventRecord? {
        guard (o["v"] as? NSNumber)?.intValue == version,
              let item = (o["item"] as? String).flatMap({ HealthItem(rawValue: $0) }),
              let first = level(o["first"] as? String), let peak = level(o["peak"] as? String),
              let reason = o["reason"] as? String, !reason.isEmpty,
              let start = (o["start"] as? String).flatMap({ UTCTime.parseISO($0) }) else { return nil }
        var end: Date?
        if let text = o["end"] as? String {
            guard let e = UTCTime.parseISO(text), e >= start else { return nil }
            end = e
        } else if !(o["end"] is NSNull) && o["end"] != nil {
            return nil
        }
        let value = (o["peakValue"] as? NSNumber).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil }
        return EventRecord(item: item, first: first, peak: peak, reasonCode: reason, start: start, end: end, peakValue: value,
                           unit: o["unit"] as? String, app: o["app"] as? String,
                           endEstimated: (o["endEstimated"] as? Bool) ?? false)
    }

    // MARK: Read

    /// The records that overlap the last `days` days, newest first (by start time). A record overlaps when it is still
    /// open or ended inside the range. A missing, unreadable or damaged file gives an empty list, never a crash.
    static func read(dir: URL, days: Int, now: Date) -> [EventRecord] {
        readAll(dir: dir).records.filter { overlaps($0, days: days, now: now) }
    }

    static func overlaps(_ r: EventRecord, days: Int, now: Date) -> Bool {
        let from = now.addingTimeInterval(-Double(max(days, 0)) * 86400)
        return (r.end ?? now) >= from && r.start <= now
    }

    /// All stored records, newest first, and the number of damaged entries that were skipped.
    static func readAll(dir: URL) -> (records: [EventRecord], skipped: Int) {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return ([], 0) }
        var out = [EventRecord]()
        var skipped = 0
        for entry in list {
            if let o = entry as? [String: Any], let r = record(o) { out.append(r) } else { skipped += 1 }
        }
        out.sort { $0.start > $1.start }
        return (out, skipped)
    }

    // MARK: Write

    /// The records that stay: newest 200 by start, no record that ended more than 30 days ago, and at most `maxBytes` when
    /// written. Open records always stay while the size allows. Newest first.
    static func limited(_ records: [EventRecord], now: Date) -> [EventRecord] {
        let from = now.addingTimeInterval(-Double(maxDays) * 86400)
        var list = records.filter { ($0.end ?? now) >= from }.sorted { $0.start > $1.start }
        if list.count > maxRecords { list = Array(list.prefix(maxRecords)) }
        while list.count > 1, (try? JSONSerialization.data(withJSONObject: list.map { object($0) }).count) ?? 0 > maxBytes {
            list.removeLast()
        }
        return list
    }

    /// Writes the limited list to events.json: temp file 0600 in the same directory, then rename(2). Directory 0700.
    static func write(_ records: [EventRecord], dir: URL, now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let list = limited(records, now: now).map { object($0) }
        let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
        let url = dir.appendingPathComponent(fileName)
        let tmp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            try h.write(contentsOf: data)
            if rename(tmp.path, url.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

/// Turns level changes into records (DESIGN_V2.md 12.2 D2). One open record per item. Called once per evaluation.
/// State is the record list; the engine loads it at launch and writes it when `observe` returns true.
struct EventTracker {
    /// Newest first.
    private(set) var records: [EventRecord]
    /// The time of the last status.json of the previous run. The first observation closes a stale open record with it.
    private var launchEstimate: Date?

    init(records: [EventRecord], previousStatusAt: Date?) {
        self.records = records.sorted { $0.start > $1.start }
        self.launchEstimate = previousStatusAt
    }

    /// Evidence for one verdict: the peak value and unit of the record, from the readings of the same evaluation.
    static func evidence(for v: ItemVerdict, current c: CurrentReadings, diskGrowth: [String: Int64]) -> (value: Double?, unit: String?) {
        func gb(_ bytes: Int64?) -> Double? { bytes.map { (Double($0) / 1e8).rounded() / 10 } }
        switch v.item {
        case .disk:
            if v.reasonCode == "low_space" { return (gb(c.diskAvailable), "GB") }
            let key = v.reasonCode == "growth_1d" ? "1d" : (v.reasonCode == "growth_5d" ? "5d" : nil)
            return (key.flatMap { diskGrowth[$0] }.flatMap { gb($0) }, "GB")
        case .memory:
            if v.reasonCode.hasPrefix("pressure") { return (c.memoryPressurePercent.map(Double.init), "%") }
            return (gb(c.swapUsed), "GB")
        case .cpu:
            if v.reasonCode == "cpu_mean_10m" { return (c.cpuMean10m.map { ($0 * 10).rounded() / 10 }, "%") }
            if v.reasonCode == "app_saturated" { return (nil, nil) }
            return (c.cpuMean5m.map { ($0 * 10).rounded() / 10 }, "%")
        case .thermal:
            return (nil, nil)
        case .power:
            if v.reasonCode == "sleep_drain", let s = c.lastSleep {
                let hours = s.wokeAt.timeIntervalSince(s.sleptAt) / 3600
                if hours > 0 { return (((s.batteryBefore - s.batteryAfter) / hours * 10).rounded() / 10, "%/h") }
                return (nil, nil)
            }
            return (c.awakeDrainPerHour.map { ($0 * 10).rounded() / 10 }, "%/h")
        }
    }

    /// Updates the records from the current verdicts. Returns true when a record was added or changed.
    /// - A yellow or red item without an open record opens one (start = `since`, else `now`).
    /// - An open record keeps its worst level, and takes the reason and value of the worst moment.
    /// - A green item closes its open record. Unknown, stale and not-applicable levels leave it open: no data is no proof.
    /// - `appNames` maps an item to an app display name. Pass an empty dictionary when the setting "include app names" is off.
    mutating func observe(verdicts: [ItemVerdict], current: CurrentReadings, diskGrowth: [String: Int64],
                          appNames: [HealthItem: String], now: Date) -> Bool {
        var changed = false
        let estimate = launchEstimate
        launchEstimate = nil
        for v in verdicts {
            let openIndex = records.firstIndex { $0.item == v.item && $0.end == nil }
            if v.isProblem {
                let e = EventTracker.evidence(for: v, current: current, diskGrowth: diskGrowth)
                guard let index = openIndex else {
                    records.insert(EventRecord(item: v.item, first: v.level, peak: v.level, reasonCode: v.reasonCode,
                                               start: min(v.since ?? now, now), end: nil, peakValue: e.value, unit: e.unit,
                                               app: appNames[v.item], endEstimated: false), at: 0)
                    changed = true
                    continue
                }
                var r = records[index]
                let worse = v.level.severity > r.peak.severity
                let higher = (e.value ?? -Double.infinity) > (r.peakValue ?? -Double.infinity) && e.unit == r.unit
                if worse {
                    r.peak = v.level
                    r.reasonCode = v.reasonCode
                }
                if worse || higher, let value = e.value { r.peakValue = value; r.unit = e.unit }
                if r.app == nil, let name = appNames[v.item] { r.app = name }
                if r != records[index] { records[index] = r; changed = true }
            } else if v.level == .green, let index = openIndex {
                var r = records[index]
                if let estimate, estimate >= r.start, estimate < now {
                    r.end = estimate
                    r.endEstimated = true
                } else {
                    r.end = max(now, r.start)
                }
                records[index] = r
                changed = true
            }
        }
        if changed { records.sort { $0.start > $1.start } }
        return changed
    }
}
