// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Data directory contents (status.json, disk NDJSON), the current time, a pid-alive check.
// Output: The report for `molemonitor-cli --status`: status.json plus read_at, age_seconds, app_running, fresh.
// Pos: CLI decision logic (docs/PROJECT.md 8.4, 8.5); read-only, no file writes, no threads.

import Foundation

/// status.json content with four extra top-level fields. `recomputed` is true when the disk and network
/// items were rebuilt from the NDJSON history because the app is not running or the data is old.
struct StatusReport: Encodable {
    var status: StatusFile
    var readAt: Date
    var ageSeconds: Double?
    var appRunning: Bool
    var fresh: Bool
    var recomputed: Bool

    enum ExtraKeys: String, CodingKey {
        case readAt = "read_at"
        case ageSeconds = "age_seconds"
        case appRunning = "app_running"
        case fresh, recomputed
    }

    func encode(to encoder: Encoder) throws {
        try status.encode(to: encoder)
        var c = encoder.container(keyedBy: ExtraKeys.self)
        try c.encode(readAt, forKey: .readAt)
        try c.encode(ageSeconds.map { ($0 * 10).rounded() / 10 }, forKey: .ageSeconds)
        try c.encode(appRunning, forKey: .appRunning)
        try c.encode(fresh, forKey: .fresh)
        try c.encode(recomputed, forKey: .recomputed)
    }

    var freshness: StatusStore.Freshness {
        StatusStore.Freshness(fresh: fresh, ageSeconds: ageSeconds ?? 0, appRunning: appRunning)
    }
}

enum StatusReportBuilder {
    /// Printed with exit code 4 when there is no status file and no disk record.
    static let neverRunJSON = "{\"app_running\":false,\"fresh\":false,\"overall\":{\"level\":\"unknown\","
        + "\"summary\":\"MoleMonitor 尚未运行过\"},\"schema_version\":1}"
    static let neverRunText = "MoleMonitor 尚未运行过"

    static let historyDays = 35

    /// Returns nil when nothing exists (exit 4). Otherwise the report; exit 0 when fresh, else 3.
    /// `todayStart` is local midnight, given by the caller.
    static func build(dir: URL, now: Date, todayStart: Date, pidAlive: (Int32) -> Bool) -> (report: StatusReport, exitCode: Int32)? {
        let prev = try? StatusStore.read(from: MoleMonitorPaths.statusURL(dir: dir))
        if let prev {
            let f = StatusStore.freshness(of: prev, now: now, pidAlive: pidAlive)
            if f.fresh {
                return (StatusReport(status: prev, readAt: now, ageSeconds: f.ageSeconds, appRunning: true,
                                     fresh: true, recomputed: false), 0)
            }
        }
        let samples = DiskHistory.load(dir: dir, now: now, days: historyDays).samples
        if samples.isEmpty && prev == nil { return nil }

        let previousLevel = prev?.items.disk.level ?? .green
        let verdict = DiskHealth.evaluate(samples: samples, now: now, previous: previousLevel)
        let lastSample = samples.filter { $0.realUsed != nil }.map { $0.t }.max() ?? samples.last?.t
        let since = prev?.items.disk.since ?? lastSample ?? now
        let changedAt: Date? = (prev?.items.disk.level == verdict.level) ? prev?.items.disk.levelChangedAt : lastSample
        let disk = DiskItem.make(samples: samples, now: now, verdict: verdict,
                                 since: verdict.level == .green ? nil : since, levelChangedAt: changedAt)
        var alerts = [AlertItem]()
        if let a = DiskAlertPolicy.growthAlert(verdict: verdict, since: since, state: DiskAlertState()) { alerts.append(a) }
        if let a = DiskAlertPolicy.lowSpaceAlert(verdict: verdict, since: since, state: DiskAlertState(), now: now) { alerts.append(a) }
        let writtenAt = prev?.writtenAt ?? lastSample ?? now
        var items = StatusFile.Items(disk: disk, network: NetworkItem.make(samples: samples, now: now, todayStart: todayStart))
        var overall = StatusFile.Overall(level: HealthLevel.worst([verdict.level]), summary: verdict.reason)
        // Items of the redesign come from the last status.json of the app: the CLI cannot measure them.
        // Their alerts and the new fields are carried over as they were written.
        if let prev, prev.items.memory != nil || prev.items.cpu != nil || prev.items.thermal != nil || prev.items.power != nil {
            items.memory = prev.items.memory
            items.cpu = prev.items.cpu
            items.thermal = prev.items.thermal
            items.power = prev.items.power
            alerts.append(contentsOf: prev.activeAlerts.filter { !$0.type.hasPrefix("disk_") })
        }
        var file = StatusFile(appVersion: prev?.appVersion ?? AppInfo.version, writtenAt: writtenAt,
                              writerPid: prev?.writerPid ?? 0, overall: overall, items: items, activeAlerts: alerts,
                              notifications: prev?.notifications ?? .init(authorization: "unavailable"))
        file.topApps = prev?.topApps
        file.env = prev?.env
        file.promptPrefs = prev?.promptPrefs
        if items.memory != nil || items.cpu != nil || items.thermal != nil || items.power != nil {
            overall = StatusExtras.overall(verdicts: StatusExtras.verdicts(from: file), diskSummary: verdict.reason)
            file.overall = overall
        }
        let running = prev.map { pidAlive($0.writerPid) } ?? false
        let report = StatusReport(status: file, readAt: now, ageSeconds: now.timeIntervalSince(writtenAt),
                                  appRunning: running, fresh: false, recomputed: true)
        return (report, 3)
    }
}
