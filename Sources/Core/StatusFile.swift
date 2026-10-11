// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk verdict, samples and alerts built by the app; status.json written by the app.
// Output: status.json model, atomic write, tolerant read, freshness check.
// Pos: Contract between the app and the CLI (docs/PROJECT.md 6.3, 8.3, 8.4); schema_version 1, additive only.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct StatusFile: Codable {
    static let schemaVersion = 1

    struct Overall: Codable {
        var level: HealthLevel
        var summary: String
    }

    struct Items: Codable {
        var disk: DiskItem
        var network: NetworkItem
        /// Added with the problem-first redesign (DESIGN.md 8.1). Absent in files of older apps: readers must accept nil.
        var memory: HealthItemStatus?
        var cpu: HealthItemStatus?
        var thermal: HealthItemStatus?
        var power: HealthItemStatus?
    }

    struct Notifications: Codable {
        /// authorized | denied | not_determined | unavailable
        var authorization: String
    }

    var schemaVersion: Int = StatusFile.schemaVersion
    var appVersion: String
    var writtenAt: Date
    var writerPid: Int32
    var overall: Overall
    var items: Items
    var activeAlerts: [AlertItem]
    var notifications: Notifications
    /// Added with the redesign. All three are optional: an old file decodes with nil, and the writer leaves out nil.
    var topApps: TopAppsStatus?
    var env: EnvStatus?
    var promptPrefs: PromptPrefs?

    enum CodingKeys: String, CodingKey {
        case overall, items, notifications, env
        case topApps = "top_apps"
        case promptPrefs = "prompt_prefs"
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case writtenAt = "written_at"
        case writerPid = "writer_pid"
        case activeAlerts = "active_alerts"
    }
}

struct DiskItem: Codable {
    var level: HealthLevel
    var reasonCode: String
    var reason: String
    var since: Date?
    var levelChangedAt: Date?
    var volume: String
    var total: Measured<Int64>
    /// Real used = total - available_important.
    var used: Measured<Int64>
    var availableImportant: Measured<Int64>
    var availableNow: Measured<Int64>
    /// available_important - available_now; only when both exist and the difference is >= 0.
    var purgeableEstimate: Measured<Int64>
    var growth: [String: DiskGrowth]
    var historyDays: Double
    var lastSampleAt: Date?

    enum CodingKeys: String, CodingKey {
        case level, reason, since, volume, total, used, growth
        case reasonCode = "reason_code"
        case levelChangedAt = "level_changed_at"
        case availableImportant = "available_important"
        case availableNow = "available_now"
        case purgeableEstimate = "purgeable_estimate"
        case historyDays = "history_days"
        case lastSampleAt = "last_sample_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level, forKey: .level)
        try c.encode(reasonCode, forKey: .reasonCode)
        try c.encode(reason, forKey: .reason)
        try c.encode(since, forKey: .since)
        try c.encode(levelChangedAt, forKey: .levelChangedAt)
        try c.encode(volume, forKey: .volume)
        try c.encode(total, forKey: .total)
        try c.encode(used, forKey: .used)
        try c.encode(availableImportant, forKey: .availableImportant)
        try c.encode(availableNow, forKey: .availableNow)
        try c.encode(purgeableEstimate, forKey: .purgeableEstimate)
        try c.encode(growth, forKey: .growth)
        try c.encode(historyDays, forKey: .historyDays)
        try c.encode(lastSampleAt, forKey: .lastSampleAt)
    }

    /// Builds the item from samples. Non-ok fields get value null and an honest status.
    static func make(samples: [DiskSample], now: Date, verdict: DiskVerdict, since: Date?, levelChangedAt: Date?,
                     thresholds: DiskThresholds = DiskThresholds()) -> DiskItem {
        let past = samples.filter { $0.t <= now }
        let latestOK = past.filter { $0.realUsed != nil }.max { $0.t < $1.t }
        var absent: ValueStatus = .collecting
        if latestOK == nil { absent = past.isEmpty ? .collecting : .failed }
        else if let l = latestOK, now.timeIntervalSince(l.t) > thresholds.maxSampleAge { absent = .stale }
        let fresh = (latestOK != nil && absent == .collecting) ? latestOK : nil
        func field(_ v: Int64?) -> Measured<Int64> {
            if let f = fresh, let v { return .ok(v, unit: "bytes", at: f.t) }
            if fresh != nil { return .absent(unit: "bytes", status: .missing, at: fresh?.t) }
            return .absent(unit: "bytes", status: absent)
        }
        var purgeable = field(nil)
        if let f = fresh, let ai = f.availImportant, let a = f.avail, ai - a >= 0 {
            purgeable = .ok(ai - a, unit: "bytes", at: f.t)
        }
        var growth = [DiskWindow.day1.key: verdict.growth1d, DiskWindow.day5.key: verdict.growth5d]
        growth[DiskWindow.day30.key] = DiskGrowth.compute(samples: samples, now: now, window: .day30)
        let first = past.min { $0.t < $1.t }
        return DiskItem(level: verdict.level, reasonCode: verdict.reasonCode, reason: verdict.reason,
                        since: since, levelChangedAt: levelChangedAt,
                        volume: latestOK?.vol ?? verdict.volume,
                        total: field(fresh?.total), used: field(fresh?.realUsed),
                        availableImportant: field(fresh?.availImportant), availableNow: field(fresh?.avail),
                        purgeableEstimate: purgeable, growth: growth,
                        historyDays: first.map { now.timeIntervalSince($0.t) / 86400 } ?? 0,
                        lastSampleAt: latestOK?.t)
    }
}

struct NetworkItem: Codable {
    var traffic: [String: TrafficTotals]
    var note: String

    static let defaultNote = "物理网卡合计，不含 VPN 隧道"

    /// `todayStart` is local midnight, given by the caller (Core does not read the time zone).
    static func make(samples: [DiskSample], now: Date, todayStart: Date) -> NetworkItem {
        NetworkItem(traffic: [
            "today": TrafficTotals.compute(samples: samples, since: todayStart, now: now),
            "5d": TrafficTotals.compute(samples: samples, since: now.addingTimeInterval(-5 * 86400), now: now),
        ], note: defaultNote)
    }
}

enum StatusStore {
    static let freshSeconds: Double = 420

    /// Writes a same-directory temp file (0600), then rename(2) over status.json. No half-written file is left.
    static func write(_ s: StatusFile, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = CoreJSON.encoder()
        enc.outputFormatting.insert(.prettyPrinted)
        let data = try enc.encode(s)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            try h.write(contentsOf: data)
            if rename(tmp.path, url.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    static func read(from url: URL) throws -> StatusFile {
        let data = try Data(contentsOf: url)
        return try CoreJSON.decoder().decode(StatusFile.self, from: data)
    }

    struct Freshness {
        var fresh: Bool
        var ageSeconds: Double
        var appRunning: Bool
    }

    /// fresh = writer process alive and age <= 420 s. A timestamp more than 60 s in the future is not fresh.
    static func freshness(of s: StatusFile, now: Date, pidAlive: (Int32) -> Bool) -> Freshness {
        let age = now.timeIntervalSince(s.writtenAt)
        let running = pidAlive(s.writerPid)
        return Freshness(fresh: running && age <= freshSeconds && age >= -60, ageSeconds: age, appRunning: running)
    }

    /// kill(pid, 0). EPERM means the process exists. pid <= 0 is never alive (kill(0, ...) would signal a group).
    static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
