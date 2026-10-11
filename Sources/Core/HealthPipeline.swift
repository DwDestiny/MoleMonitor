// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points, app window stats, sleep records, the disk item and the base readings (one evaluation per 30 s tick).
// Output: The five verdicts in display order, the problems in problem order, and the current readings completed
//         with the derived values (means, swap growth and trend, awake drain, last sleep).
// Pos: The pure part of the engine (docs/DESIGN.md 6, 8.2), kept in Core so that Linux tests cover it. Owner I1.
//      The engine only gathers the inputs and publishes the output.

import Foundation

struct PipelineState: Equatable {
    var rules = RuleMemory()
    var lastLevel = [String: HealthLevel]()
    var changedAt = [String: Date]()
}

struct PipelineInput {
    var points: [TrendPoint]
    var apps: [AppWindowStat] = []
    /// Whether the process scans cover the app windows. Nil: a non-empty `apps` list counts as available.
    var appDataAvailable: Bool?
    var sleeps: [SleepRecord] = []
    var hasBattery = false
    /// The disk verdict built from the disk engine (`HealthPipeline.diskVerdict`). Nil: disk is still collecting.
    var disk: ItemVerdict?
    /// Readings that the engine measured directly (cpuPercent, battery, rates, thermal, sampledAt ...).
    var current = CurrentReadings()
    var now: Date
}

struct PipelineOutput {
    /// All items: problem items first (problem order), then the rest by fixed priority.
    var verdicts: [ItemVerdict]
    var problems: [ItemVerdict]
    var current: CurrentReadings
}

enum HealthPipeline {
    static func evaluate(_ input: PipelineInput, state: inout PipelineState) -> PipelineOutput {
        let now = input.now
        var cur = input.current
        let physical: Int64 = cur.physicalMemory ?? 0

        var list = [ItemVerdict]()
        var cpu = CPUHealth.evaluate(points: input.points, apps: input.apps, now: now, state: &state.rules,
                                     appDataAvailable: input.appDataAvailable)
        var memory = MemoryHealth.evaluate(points: input.points, physicalBytes: physical, now: now, state: &state.rules)
        var thermal = ThermalHealth.evaluate(points: input.points, now: now, state: &state.rules)
        stamp(&cpu, state: &state, now: now)
        stamp(&memory, state: &state, now: now)
        stamp(&thermal, state: &state, now: now)
        list.append(cpu)
        list.append(memory)
        list.append(thermal)
        if var power = PowerHealth.evaluate(points: input.points, sleeps: input.sleeps, hasBattery: input.hasBattery,
                                            now: now, state: &state.rules) {
            stamp(&power, state: &state, now: now)
            list.append(power)
        }
        var disk: ItemVerdict
        if let d = input.disk {
            disk = d
        } else {
            disk = ItemVerdict(item: .disk, level: .unknown, reasonCode: "collecting", headline: "统计中",
                               since: nil, levelChangedAt: nil, alert: nil)
        }
        let diskChangedAt = disk.levelChangedAt
        stamp(&disk, state: &state, now: now)
        if let diskChangedAt { disk.levelChangedAt = diskChangedAt }
        list.append(disk)

        // Derived readings.
        let run = TrendMath.run(input.points, now: now)
        let value: (TrendPoint) -> Double? = { $0.cpu }
        if !run.isEmpty {
            cur.cpuMean5m = TrendMath.mean(run, end: run.count - 1, window: 300, value: value)
            cur.cpuMean10m = TrendMath.mean(run, end: run.count - 1, window: 600, value: value)
        }
        cur.swapGrowth30m = MemoryHealth.swapGrowth30m(points: input.points, now: now)
        if physical > 0 { cur.swapTrend = MemoryHealth.swapTrend(points: input.points, physicalBytes: physical, now: now) }
        cur.awakeDrainPerHour = awakeDrain(run: run)
        if let sleep = input.sleeps.sorted(by: { $0.wokeAt < $1.wokeAt }).last { cur.lastSleep = sleep }

        // Alerts: one per problem. Disk keeps the alert of the disk engine.
        for index in list.indices where list[index].item != .disk {
            list[index].alert = HealthAlerts.alert(for: list[index], current: cur)
        }
        let ordered = ProblemOrder.all(list)
        return PipelineOutput(verdicts: ordered, problems: ProblemOrder.problems(ordered), current: cur)
    }

    /// Drain in percent per hour over the last 60 minutes on battery. Nil on power or with a short window.
    static func awakeDrain(run: [TrendPoint]) -> Double? {
        guard run.last?.power == .battery else { return nil }
        var stretch = [TrendPoint]()
        for p in run.reversed() {
            if p.power == .ac { break }
            if p.battery != nil { stretch.append(p) }
        }
        stretch.reverse()
        guard !stretch.isEmpty else { return nil }
        return PowerHealth.awakeRate(stretch, end: stretch.count - 1)
    }

    /// Sets `levelChangedAt`: the time of the last level change seen by this process. On the first evaluation the
    /// change time is unknown, so a problem uses its start time and a healthy item stays nil.
    static func stamp(_ v: inout ItemVerdict, state: inout PipelineState, now: Date) {
        let key = v.item.rawValue
        if let previous = state.lastLevel[key] {
            if previous != v.level { state.changedAt[key] = now }
        } else {
            state.changedAt[key] = v.isProblem ? v.since : nil
        }
        state.lastLevel[key] = v.level
        v.levelChangedAt = state.changedAt[key]
    }

    /// The disk verdict of the health list, built from the status item and the active disk alerts. The same function
    /// serves the engine and the CLI, so both show the same headline.
    static func diskVerdict(item d: DiskItem, alerts: [AlertItem]) -> ItemVerdict {
        var headline = "磁盘正常"
        var code = d.reasonCode
        switch d.reasonCode {
        case "growth_1d", "growth_5d":
            let key: String = d.reasonCode == "growth_1d" ? "1d" : "5d"
            let days: String = d.reasonCode == "growth_1d" ? "1" : "5"
            headline = days + " 天多占用 " + ByteText.gb(d.growth[key]?.bytes ?? 0)
        case "low_space":
            headline = "剩余空间只有 " + ByteText.gb(d.availableImportant.value ?? 0)
        case "hold", "recovering":
            headline = "回落观察"
        case "no_data":
            headline = "统计中"
            code = "collecting"
        default:
            break
        }
        let diskAlerts: [AlertItem] = alerts.filter { $0.type.hasPrefix("disk_") }
        var chosen: AlertItem?
        if d.reasonCode == "low_space" {
            chosen = diskAlerts.first { $0.type == "disk_low_space" } ?? diskAlerts.first
        } else {
            chosen = diskAlerts.first { $0.type == "disk_growth" } ?? diskAlerts.first
        }
        let isProblem = d.level == .yellow || d.level == .red
        return ItemVerdict(item: .disk, level: d.level, reasonCode: code, headline: headline,
                           since: isProblem ? d.since : nil, levelChangedAt: d.levelChangedAt,
                           alert: isProblem ? chosen : nil)
    }
}
