// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Verdicts, current readings, top apps and the environment from the engine; a StatusFile read by the CLI.
// Output: The new status.json fields (items memory/cpu/thermal/power, top_apps, env, prompt_prefs, overall roll-up)
//         and the way back: the CLI builds a PromptInput from a StatusFile (docs/DESIGN.md 7.8, 8.1).
// Pos: Contract helpers between the app and `molemonitor-cli prompt`; Foundation only. Owner I1.
//      Additive only: schema_version stays 1, and a file without the new fields still decodes.

import Foundation

extension Measured: Equatable where T: Equatable {
    static func == (a: Measured<T>, b: Measured<T>) -> Bool {
        a.value == b.value && a.unit == b.unit && a.status == b.status && a.sampledAt == b.sampledAt
    }
}

/// One of the four new items in status.json. One struct with optional fields: each item uses the ones it needs.
struct HealthItemStatus: Codable, Equatable {
    struct LastSleep: Codable, Equatable {
        var sleptAt: Date
        var wokeAt: Date
        var hours: Double
        var before: Double
        var after: Double
        var drainPerHour: Double?

        enum CodingKeys: String, CodingKey {
            case hours, before, after
            case sleptAt = "slept_at"
            case wokeAt = "woke_at"
            case drainPerHour = "drain_per_hour"
        }
    }

    var level: HealthLevel
    var reasonCode: String
    var headline: String
    var since: Date?
    var levelChangedAt: Date?
    // Memory.
    var pressure: MemoryPressure?
    var swapUsed: Measured<Int64>?
    var swapGrowth30m: Measured<Int64>?
    var swapTrend: SwapTrend?
    // CPU.
    var mean5m: Measured<Double>?
    var mean10m: Measured<Double>?
    var trend2h: CPUSummary?
    // Thermal.
    var state: ThermalLevel?
    // Power.
    var batteryPercent: Double?
    var powerSource: String?
    var lastSleep: LastSleep?
    var awakeDrainPerHour: Double?

    enum CodingKeys: String, CodingKey {
        case level, headline, since, pressure, state
        case reasonCode = "reason_code"
        case levelChangedAt = "level_changed_at"
        case swapUsed = "swap_used"
        case swapGrowth30m = "swap_growth_30m"
        case swapTrend = "swap_trend"
        case mean5m = "mean_5m"
        case mean10m = "mean_10m"
        case trend2h = "trend_2h"
        case batteryPercent = "battery_percent"
        case powerSource = "power_source"
        case lastSleep = "last_sleep"
        case awakeDrainPerHour = "awake_drain_per_hour"
    }
}

struct TopAppEntry: Codable, Equatable {
    var name: String
    var bundleID: String?
    var cpuPercent: Double?
    var memoryBytes: Int64?
    var memoryBasis: String
    var processCount: Int
    var isSystem: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case cpuPercent = "cpu_percent"
        case memoryBytes = "memory_bytes"
        case memoryBasis = "memory_basis"
        case processCount = "process_count"
        case isSystem = "is_system"
    }
}

struct TopAppsStatus: Codable, Equatable {
    var sampledAt: Date
    /// "5m" (a mean over up to 5 minutes), "live" (the 4 second scans of an open card) or "once".
    var basis: String
    var apps: [TopAppEntry]
    var coverage: ProcessCoverage?

    enum CodingKeys: String, CodingKey {
        case basis, apps, coverage
        case sampledAt = "sampled_at"
    }
}

struct EnvStatus: Codable, Equatable {
    var model: String?
    var chip: String?
    var memoryBytes: Int64?
    var os: String

    enum CodingKeys: String, CodingKey {
        case model, chip, os
        case memoryBytes = "memory_bytes"
    }
}

struct PromptPrefs: Codable, Equatable {
    var includeAppNames: Bool

    enum CodingKeys: String, CodingKey {
        case includeAppNames = "include_app_names"
    }
}

enum StatusExtras {
    static let maxTopApps = 16
    static let topPerKey = 8

    // MARK: Writer side

    /// The status.json item of one verdict, with the readings that belong to it.
    static func itemStatus(for v: ItemVerdict, current c: CurrentReadings, cpuSummary: CPUSummary?) -> HealthItemStatus {
        var s = HealthItemStatus(level: v.level, reasonCode: v.reasonCode, headline: v.headline,
                                 since: v.since, levelChangedAt: v.levelChangedAt)
        let at = c.sampledAt
        switch v.item {
        case .memory:
            s.pressure = c.pressure
            s.swapUsed = measuredBytes(c.swapUsed, at: at)
            s.swapGrowth30m = measuredBytes(c.swapGrowth30m, at: at)
            s.swapTrend = c.swapTrend
        case .cpu:
            s.mean5m = measuredPercent(c.cpuMean5m, at: at)
            s.mean10m = measuredPercent(c.cpuMean10m, at: at)
            s.trend2h = cpuSummary
        case .thermal:
            s.state = c.thermal
        case .power:
            s.batteryPercent = c.batteryPercent
            if let source = c.powerSource { s.powerSource = source == .battery ? "battery" : "ac" }
            if let sleep = c.lastSleep {
                let seconds = sleep.wokeAt.timeIntervalSince(sleep.sleptAt)
                let rate: Double? = seconds > 0 ? (sleep.batteryBefore - sleep.batteryAfter) / (seconds / 3600) : nil
                s.lastSleep = HealthItemStatus.LastSleep(sleptAt: sleep.sleptAt, wokeAt: sleep.wokeAt, hours: seconds / 3600,
                                                         before: sleep.batteryBefore, after: sleep.batteryAfter,
                                                         drainPerHour: rate)
            }
            s.awakeDrainPerHour = c.awakeDrainPerHour
        case .disk:
            break
        }
        return s
    }

    private static func measuredBytes(_ v: Int64?, at: Date?) -> Measured<Int64> {
        if let v { return .ok(v, unit: "bytes", at: at) }
        return .absent(unit: "bytes", status: .collecting)
    }

    private static func measuredPercent(_ v: Double?, at: Date?) -> Measured<Double> {
        if let v { return .ok((v * 10).rounded() / 10, unit: "percent", at: at) }
        return .absent(unit: "percent", status: .collecting)
    }

    /// Union of the top 8 by CPU and the top 8 by memory, at most 16 entries (DESIGN.md 8.1).
    /// Nil when there are no apps, so the field stays out of the file until the first scan is done.
    static func topApps(_ apps: [AppUsage], coverage: ProcessCoverage?, sampledAt: Date, basis: String) -> TopAppsStatus? {
        guard !apps.isEmpty else { return nil }
        var chosen = [AppUsage]()
        var seen = Set<String>()
        let byCPU: [AppUsage] = AppRanking.top(apps, by: .cpu, count: topPerKey)
        let byMemory: [AppUsage] = AppRanking.top(apps, by: .memory, count: topPerKey)
        for app in byCPU + byMemory where !seen.contains(app.key) {
            seen.insert(app.key)
            chosen.append(app)
        }
        var entries = [TopAppEntry]()
        for app in chosen.prefix(maxTopApps) {
            entries.append(TopAppEntry(name: app.name, bundleID: app.bundleID, cpuPercent: app.cpuPercent,
                                       memoryBytes: app.memoryBytes, memoryBasis: app.memoryBasis,
                                       processCount: app.processCount, isSystem: app.isSystem))
        }
        return TopAppsStatus(sampledAt: sampledAt, basis: basis, apps: entries, coverage: coverage)
    }

    static func env(_ e: PromptEnvironment) -> EnvStatus {
        EnvStatus(model: e.model, chip: e.chip, memoryBytes: e.memoryBytes, os: e.os)
    }

    /// Worst level of all items, with the one-line reason of the first problem (or the disk summary while all is well).
    static func overall(verdicts: [ItemVerdict], diskSummary: String) -> StatusFile.Overall {
        let level = HealthLevel.worst(verdicts.map { $0.level })
        let problems = ProblemOrder.problems(verdicts)
        if let first = problems.first {
            return StatusFile.Overall(level: level, summary: first.item.label + "：" + first.headline)
        }
        return StatusFile.Overall(level: level, summary: diskSummary)
    }

    // MARK: Reader side (CLI)

    /// The item that owns an alert type.
    static func item(forAlertType type: String) -> HealthItem? {
        if type.hasPrefix("disk_") { return .disk }
        if type.hasPrefix("memory_") { return .memory }
        if type.hasPrefix("cpu_") { return .cpu }
        if type == "thermal" { return .thermal }
        if type.hasPrefix("power_") { return .power }
        return nil
    }

    /// All five verdicts of a status file in display order. An item that an older file does not have is
    /// unknown with reason "missing". Alerts come from `active_alerts`.
    static func verdicts(from status: StatusFile) -> [ItemVerdict] {
        var out = [ItemVerdict]()
        var byItem = [HealthItem: AlertItem]()
        for a in status.activeAlerts {
            guard let item = item(forAlertType: a.type) else { continue }
            if byItem[item] == nil { byItem[item] = a }
        }
        var disk = HealthPipeline.diskVerdict(item: status.items.disk, alerts: status.activeAlerts)
        disk.alert = byItem[.disk] ?? disk.alert
        out.append(disk)
        let others: [(HealthItem, HealthItemStatus?)] = [(.memory, status.items.memory), (.cpu, status.items.cpu),
                                                          (.thermal, status.items.thermal), (.power, status.items.power)]
        for (item, s) in others {
            guard let s else {
                out.append(ItemVerdict(item: item, level: .unknown, reasonCode: "missing", headline: "暂无读数",
                                       since: nil, levelChangedAt: nil, alert: nil))
                continue
            }
            out.append(ItemVerdict(item: item, level: s.level, reasonCode: s.reasonCode, headline: s.headline,
                                   since: s.since, levelChangedAt: s.levelChangedAt, alert: byItem[item]))
        }
        return ProblemOrder.all(out)
    }

    static func current(from status: StatusFile) -> CurrentReadings {
        var c = CurrentReadings()
        c.sampledAt = status.writtenAt
        c.physicalMemory = status.env?.memoryBytes
        c.diskAvailable = status.items.disk.availableImportant.value
        if let m = status.items.memory {
            c.pressure = m.pressure
            c.swapUsed = m.swapUsed?.value
            c.swapGrowth30m = m.swapGrowth30m?.value
            c.swapTrend = m.swapTrend
        }
        if let u = status.items.cpu {
            c.cpuMean5m = u.mean5m?.value
            c.cpuMean10m = u.mean10m?.value
        }
        c.thermal = status.items.thermal?.state
        if let p = status.items.power {
            c.batteryPercent = p.batteryPercent
            if let source = p.powerSource { c.powerSource = source == "ac" ? .ac : .battery }
            if let s = p.lastSleep {
                c.lastSleep = SleepRecord(sleptAt: s.sleptAt, wokeAt: s.wokeAt, batteryBefore: s.before,
                                          batteryAfter: s.after, onBatteryBeforeSleep: true)
            }
            c.awakeDrainPerHour = p.awakeDrainPerHour
        }
        return c
    }

    static func apps(from status: StatusFile) -> [AppUsage] {
        guard let top = status.topApps else { return [] }
        var out = [AppUsage]()
        for e in top.apps {
            let key: String = e.bundleID ?? ("proc:" + e.name)
            out.append(AppUsage(key: key, name: e.name, bundleID: e.bundleID, cpuPercent: e.cpuPercent,
                                memoryBytes: e.memoryBytes, memoryBasis: e.memoryBasis,
                                processCount: e.processCount, isSystem: e.isSystem))
        }
        return out
    }

    /// The prompt input of `molemonitor-cli prompt`. The apps basis names the time of the scan, because the
    /// CLI reads a file that can be older than the app state (DESIGN.md 7.8).
    static func promptInput(status: StatusFile, freshness: StatusStore.Freshness, cliPath: String, dataDir: String,
                            timeZone: TimeZone) -> PromptInput {
        let minutes = Int(max(0, freshness.ageSeconds) / 60)
        var fresh = PromptFreshness.fresh
        if !freshness.appRunning {
            fresh = .notRunning(minutes: minutes)
        } else if !freshness.fresh {
            fresh = .stale(minutes: minutes)
        }
        let environment = PromptEnvironment(model: status.env?.model, chip: status.env?.chip,
                                            memoryBytes: status.env?.memoryBytes, os: status.env?.os ?? "未知",
                                            appVersion: status.appVersion, cliPath: cliPath, dataDir: dataDir)
        var basis = "近 5 分钟"
        if let top = status.topApps { basis = "采样于 " + TextFormat.clock(top.sampledAt, timeZone: timeZone) }
        var growth = [String: DiskGrowth]()
        for (key, value) in status.items.disk.growth { growth[key] = value }
        return PromptInput(env: environment, sampledAt: status.writtenAt, freshness: fresh, verdicts: verdicts(from: status),
                           current: current(from: status), apps: apps(from: status), appsBasis: basis,
                           cpuSummary: status.items.cpu?.trend2h, diskGrowth: growth)
    }
}
