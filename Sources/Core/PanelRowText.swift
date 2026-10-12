// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, current readings, the data state, the trend and the disk series (docs/DESIGN_V2.md 2.8, 5.3, 5.5, 7.2, 7.3, 8.1).
// Output: PanelRowState (one breakdown row as plain texts and a dot), AnomalyBar (one anomaly row), PanelFooterState,
//         PanelAreaState (the line of the anomaly area when it is not a list) and the mini curve data.
// Pos: All texts of the main column in one pure place, so Linux tests check them (gates W02, W19, W21). Foundation only. Owner WP-C.
//      A measured zero, a missing value, a collecting value and a stale value look different (DESIGN_V2.md 2.8, 5.3).
//      A number with a unit appears in a row and never in an anomaly bar (7.3).

import Foundation

// MARK: - Dots and rows

/// The state dot of a row (DESIGN_V2.md 3.5). The shape carries the meaning, the color repeats it.
enum PanelDot: String, Equatable {
    case red, yellow
    case normal            // Gray filled circle: measured and healthy
    case neutralHollow     // Network: no health level
    case collecting, stale, missing, failed
}

enum PanelStatusKind: Equatable {
    case measured, collecting, stale, missing
}

struct PanelRowState: Equatable, Identifiable {
    var item: SidebarItem
    var name: String
    var dot: PanelDot
    var level: HealthLevel
    /// 11 pt prefix of the value: "压力", "可用", "swap", or a clock time when the value is stale.
    var valuePrefix: String?
    /// 17 pt value: "23%", "+314 GB", "正常", "—", "采集中".
    var value: String
    var note: String
    var status: PanelStatusKind
    var id: String { item.rawValue }

    var isProblem: Bool { dot == .red || dot == .yellow }

    /// The measurement as one string, prefix included: "压力 64%". Used by the duplicate check of gate W02.
    var measurement: String {
        if let valuePrefix { return valuePrefix + " " + value }
        return value
    }

    /// Spoken label: "磁盘，异常，+314 GB，已用 875 / 995 GB".
    var accessibilityLabel: String {
        let state: String
        switch dot {
        case .red: state = "异常"
        case .yellow: state = "留意"
        case .normal, .neutralHollow: state = "正常"
        case .collecting: state = "采集中"
        case .stale: state = "数据已过期"
        case .missing: state = "无数据"
        case .failed: state = "读取失败"
        }
        return name + "，" + state + "，" + measurement + "，" + note
    }
}

struct PanelRowsInput {
    var verdicts: [ItemVerdict]
    var current: CurrentReadings
    var dataState: DataState
    var diskGrowth: [String: DiskGrowth]
    var topApps: [AppUsage]
    var now: Date
    var timeZone: TimeZone

    init(verdicts: [ItemVerdict], current: CurrentReadings, dataState: DataState, diskGrowth: [String: DiskGrowth] = [:],
         topApps: [AppUsage] = [], now: Date, timeZone: TimeZone = TimeZone.current) {
        self.verdicts = verdicts
        self.current = current
        self.dataState = dataState
        self.diskGrowth = diskGrowth
        self.topApps = topApps
        self.now = now
        self.timeZone = timeZone
    }
}

enum PanelRows {
    static let dash = "\u{2014}"

    /// The battery row exists unless the power verdict says "not applicable" (a desktop Mac).
    static func hasBattery(_ verdicts: [ItemVerdict]) -> Bool {
        guard let v = verdicts.first(where: { $0.item == .power }) else { return true }
        return v.level != .notApplicable
    }

    /// One row per entry of `order`.
    static func make(order: [SidebarItem], input: PanelRowsInput) -> [PanelRowState] {
        order.compactMap { item in item == .anomalyLog ? nil : row(item, input) }
    }

    /// Thermal state word of the panel (DESIGN_V2.md 5.3): 正常, 偏高, 严重, 临界.
    static func thermalWord(_ t: ThermalLevel?) -> String {
        guard let t else { return dash }
        switch t {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "严重"
        case .critical: return "临界"
        }
    }

    // MARK: Row

    static func row(_ item: SidebarItem, _ input: PanelRowsInput) -> PanelRowState {
        let c = input.current
        let verdict = item.healthItem.flatMap { h in input.verdicts.first { $0.item == h } }
        var state = content(item, input, verdict)
        state.dot = dot(item, verdict, hasValue: state.value != dash && state.value != "采集中", input.dataState)
        state.level = verdict?.level ?? .green
        // A missing memory percent shows the missing dot unless the level is a problem (gate W21).
        if item == .memory, c.memoryPressurePercent == nil, !state.isProblem, case .fresh = input.dataState {
            state.dot = .missing
        }
        switch input.dataState {
        case .collecting:
            state.status = .collecting
            if state.value == dash { state.value = "采集中" }
            if state.value == "采集中" { state.note = "正在采集" }
        case .stale(let since):
            state.status = .stale
            state.valuePrefix = TextFormat.clock(since, timeZone: input.timeZone)
            if item != .memory && item != .disk { state.note = "停在 " + TextFormat.clock(since, timeZone: input.timeZone) }
        case .fresh:
            if state.dot == .missing { state.status = .missing } else if state.dot == .collecting { state.status = .collecting }
        }
        return state
    }

    private static func dot(_ item: SidebarItem, _ v: ItemVerdict?, hasValue: Bool, _ data: DataState) -> PanelDot {
        switch data {
        case .collecting: return .collecting
        case .stale: return .stale
        case .fresh: break
        }
        guard let v else { return hasValue ? .neutralHollow : .missing }
        switch v.level {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return hasValue ? .normal : .missing
        case .stale: return .stale
        case .unknown: return v.reasonCode == "missing" ? .missing : .collecting
        case .notApplicable: return .missing
        }
    }

    private static func percentInt(_ v: Double?) -> String {
        TextFormat.percent(v)
    }

    private static func content(_ item: SidebarItem, _ input: PanelRowsInput, _ v: ItemVerdict?) -> PanelRowState {
        let c = input.current
        var s = PanelRowState(item: item, name: item.label, dot: .normal, level: .green, valuePrefix: nil, value: dash,
                              note: dash, status: .measured)
        let code = v?.reasonCode ?? ""
        switch item {
        case .cpu:
            s.value = percentInt(c.cpuPercent)
            switch code {
            case "cpu_mean_10m": s.note = "10 分钟均值 " + percentInt(c.cpuMean10m)
            case "cpu_mean_5m": s.note = "5 分钟均值 " + percentInt(c.cpuMean5m)
            case "app_saturated":
                var name = v?.headline ?? ""
                if let r = name.range(of: " 占满一个核") { name = String(name[..<r.lowerBound]) }
                if let app = input.topApps.first(where: { $0.name == name }), let cpu = app.cpuPercent {
                    s.note = name + " " + TextFormat.percent(cpu)
                } else {
                    s.note = name.isEmpty ? "App 持续占用" : name
                }
            default: s.note = "5 分钟均值 " + percentInt(c.cpuMean5m)
            }
        case .memory:
            let cap = CapacityFormat.memory(c)
            s.note = cap.usedOfTotal
            if code == "swap_growth", let g = c.swapGrowth30m {
                s.valuePrefix = "swap"
                s.value = TextFormat.signedBytes(g)
            } else {
                s.valuePrefix = "压力"
                s.value = c.memoryPressurePercent.map { String($0) + "%" } ?? dash
            }
        case .disk:
            let cap = CapacityFormat.disk(c)
            s.note = cap.usedOfTotal
            var growth: Int64?
            switch code {
            case "growth_1d": growth = input.diskGrowth["1d"]?.bytes
            case "growth_5d": growth = input.diskGrowth["5d"]?.bytes
            case "growth_30d": growth = input.diskGrowth["30d"]?.bytes
            default: break
            }
            if let growth {
                s.value = TextFormat.signedDiskGB(growth)
            } else {
                s.valuePrefix = "可用"
                if !cap.isMissing {
                    s.value = cap.available
                } else if let a = c.diskAvailable {
                    s.value = ByteText.gb(a)
                } else {
                    s.value = dash
                }
            }
        case .network:
            if let rx = c.rx, let tx = c.tx {
                s.value = RateText.text(rx + tx)
                s.note = "\u{2193}" + RateText.text(rx) + " \u{2191}" + RateText.text(tx)
            } else {
                s.value = dash
                s.note = dash
            }
        case .battery:
            s.value = percentInt(c.batteryPercent)
            switch code {
            case "sleep_drain":
                if let rate = sleepRate(c.lastSleep) { s.note = "睡眠每小时 " + String(format: "%.1f%%", rate) } else { s.note = "睡眠掉电偏快" }
            case "awake_drain":
                if let rate = c.awakeDrainPerHour { s.note = "使用中每小时 " + String(format: "%.0f%%", rate) } else { s.note = "掉电偏快" }
            default:
                switch c.powerSource {
                case .ac?: s.note = "电源适配器"
                case .battery?: s.note = "电池供电"
                case nil: s.note = dash
                }
            }
        case .thermal:
            s.value = thermalWord(c.thermal)
            if let t = c.smcCPUTemperature {
                s.note = "CPU " + String(format: "%.0f", t) + " \u{00B0}C（参考）"
            } else {
                s.note = "系统热状态"
            }
        case .anomalyLog:
            break
        }
        return s
    }

    /// Percent points per hour over a sleep. Nil when the sleep was shorter than a minute.
    static func sleepRate(_ s: SleepRecord?) -> Double? {
        guard let s else { return nil }
        let hours = s.wokeAt.timeIntervalSince(s.sleptAt) / 3600
        guard hours > 1.0 / 60 else { return nil }
        return (s.batteryBefore - s.batteryAfter) / hours
    }
}

// MARK: - Anomaly area

/// One anomaly row (DESIGN_V2.md 7.2). It holds no measured value: the reason word, a duration and a start time only (7.3).
struct AnomalyBar: Equatable, Identifiable {
    var item: HealthItem
    var sidebar: SidebarItem
    var level: HealthLevel
    /// "磁盘 · 异常", "内存 · 留意".
    var title: String
    /// "5 天增长", "压力警告".
    var reason: String
    /// "3 小时 12 分".
    var duration: String
    /// "开始 10:52", "开始 昨天 22:10".
    var start: String
    var id: String { item.rawValue }

    var accessibilityLabel: String { title + "，" + reason + "，已持续 " + duration + "，" + start }
}

enum PanelAnomalies {
    /// Reason word for a reason code. It carries no measured value. A time window ("5 天") is allowed (DESIGN_V2.md 7.3).
    static func reasonWord(item: HealthItem, code: String) -> String {
        switch (item, code) {
        case (.disk, "growth_1d"): return "1 天增长"
        case (.disk, "growth_5d"): return "5 天增长"
        case (.disk, "growth_30d"): return "30 天增长"
        case (.disk, "low_space"): return "可用空间不足"
        case (.memory, "pressure_warning"): return "压力警告"
        case (.memory, "pressure_critical"): return "压力严重"
        case (.memory, "swap_growth"): return "swap 30 分钟增长"
        case (.cpu, "app_saturated"): return "App 持续占用"
        case (.cpu, _): return "持续高负载"
        case (.thermal, "thermal_fair"): return "热状态偏高"
        case (.thermal, "thermal_serious"): return "热状态严重"
        case (.thermal, "thermal_critical"): return "热状态临界"
        case (.power, "sleep_drain"): return "睡眠掉电偏快"
        case (.power, "awake_drain"): return "掉电偏快"
        default: return "需要处理"
        }
    }

    /// "10:52", "昨天 22:10", "10月9日 22:10".
    static func startText(_ start: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = TextFormat.clock(start, timeZone: timeZone)
        if calendar.isDate(start, inSameDayAs: now) { return "开始 " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            return "开始 昨天 " + clock
        }
        return "开始 " + TextFormat.dateTime(start, timeZone: timeZone)
    }

    /// Level word of the title: red 异常, yellow 留意.
    static func levelWord(_ level: HealthLevel) -> String { level == .red ? "异常" : "留意" }

    /// The bars for the shown anomalies, in plan order. `shown` comes from `PanelLayoutPlan.shownAnomalies`.
    static func bars(shown: [HealthItem], verdicts: [ItemVerdict], now: Date, timeZone: TimeZone = TimeZone.current) -> [AnomalyBar] {
        shown.compactMap { item in
            guard let v = verdicts.first(where: { $0.item == item }) else { return nil }
            let row = SidebarItem(item)
            return AnomalyBar(item: item, sidebar: row, level: v.level, title: row.label + " · " + levelWord(v.level),
                              reason: reasonWord(item: item, code: v.reasonCode),
                              duration: TextFormat.duration(since: v.since, now: now),
                              start: v.since.map { startText($0, now: now, timeZone: timeZone) } ?? PanelRows.dash)
        }
    }
}

/// What the anomaly area shows (DESIGN_V2.md 2.5 to 2.7, 7.1, 7.2).
enum PanelAreaState: Equatable {
    /// "没有异常" with the record entry on the right. `records` is the count of the last 7 days, nil when unknown.
    case quiet(records: Int?)
    case collecting
    case stale(minutes: Int)
    case anomalies

    static func make(dataState: DataState, anomalyCount: Int, records: Int?, now: Date) -> PanelAreaState {
        switch dataState {
        case .collecting: return .collecting
        case .stale(let since): return .stale(minutes: max(1, Int(now.timeIntervalSince(since) / 60)))
        case .fresh: return anomalyCount > 0 ? .anomalies : .quiet(records: records)
        }
    }

    var text: String {
        switch self {
        case .quiet: return "没有异常"
        case .collecting: return "正在采集第一组数据"
        case .stale(let minutes): return "数据已过期 " + TextFormat.span(seconds: Double(minutes) * 60)
        case .anomalies: return "异常"
        }
    }

    /// The right side of the quiet line: "近 7 天 2 条记录 ›" or "近 7 天无记录".
    static func recordsText(_ records: Int?) -> String {
        guard let records else { return "近 7 天记录" }
        return records == 0 ? "近 7 天无记录" : "近 7 天 \(records) 条记录"
    }
}

// MARK: - Footer

enum PanelFooterMode: Equatable {
    case copyProblems, inspect, inspectDisabled
}

struct PanelFooterState: Equatable {
    var mode: PanelFooterMode
    var title: String
    var subtitle: String?
    var enabled: Bool
    var copiedTitle: String
    /// The bubble text after a successful copy (DESIGN_V2.md 8.1).
    var copiedBubble: String
    var failedBubble: String

    static func make(dataState: DataState, anomalyCount: Int) -> PanelFooterState {
        if case .collecting = dataState {
            return PanelFooterState(mode: .inspectDisabled, title: "让 Agent 做一次日常巡检", subtitle: nil, enabled: false,
                                    copiedTitle: "\u{2713} 已复制", copiedBubble: "巡检单已复制，交给 Agent 吧",
                                    failedBubble: "没复制上，再点一次试试")
        }
        if anomalyCount > 0 {
            return PanelFooterState(mode: .copyProblems, title: "复制排查提示词", subtitle: "粘贴给你的 Agent", enabled: true,
                                    copiedTitle: "\u{2713} 已复制", copiedBubble: "已复制，去问你的 Agent 吧",
                                    failedBubble: "没复制上，再点一次试试")
        }
        return PanelFooterState(mode: .inspect, title: "让 Agent 做一次日常巡检", subtitle: nil, enabled: true,
                                copiedTitle: "\u{2713} 已复制", copiedBubble: "巡检单已复制，交给 Agent 吧",
                                failedBubble: "没复制上，再点一次试试")
    }
}

// MARK: - Mini curves (DESIGN_V2.md 5.5)

struct SparkPoint: Equatable {
    var t: Date
    var v: Double
}

/// Data of one mini curve. `runs` are the unbroken stretches: a missing value or a gap ends a run (no line across a gap).
struct SparkSeries: Equatable {
    var runs: [[SparkPoint]]
    var window: ClosedRange<Date>
    var domain: ClosedRange<Double>

    var isEmpty: Bool { runs.allSatisfy { $0.count < 1 } }
    var last: SparkPoint? { runs.last(where: { !$0.isEmpty })?.last }

    static func empty(now: Date) -> SparkSeries {
        SparkSeries(runs: [], window: now.addingTimeInterval(-1800)...now, domain: 0...100)
    }

    /// Keeps at most `limit` points of a run, evenly spaced, always the last one.
    static func thin(_ points: [SparkPoint], limit: Int) -> [SparkPoint] {
        guard points.count > limit, limit > 1 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        var out = [SparkPoint]()
        for i in 0..<limit { out.append(points[min(points.count - 1, Int((Double(i) * step).rounded()))]) }
        return out
    }

    /// Builds the runs of a trend series for a value picker. Window: the last `seconds` before `now`.
    static func fromTrend(_ trend: TrendSeries, now: Date, seconds: TimeInterval = 1800, domain: ClosedRange<Double>,
                          value: (TrendPoint) -> Double?) -> SparkSeries {
        let start = now.addingTimeInterval(-seconds)
        var runs = [[SparkPoint]]()
        for segment in trend.segments {
            var run = [SparkPoint]()
            for p in segment where p.t >= start && p.t <= now {
                if let v = value(p), v.isFinite {
                    run.append(SparkPoint(t: p.t, v: v))
                } else if !run.isEmpty {
                    runs.append(thin(run, limit: 90))
                    run = []
                }
            }
            if !run.isEmpty { runs.append(thin(run, limit: 90)) }
        }
        return SparkSeries(runs: runs, window: start...now, domain: domain)
    }

    /// The curve of one row. Cases follow DESIGN_V2.md 5.5: CPU, pressure and battery 0 to 100; network from 0 to the window
    /// maximum (at least 1 MB/s); thermal 0 to 3; disk 7 days with a span of at least 10 GB.
    static func make(_ item: SidebarItem, trend: TrendSeries, disk: [DiskPoint], now: Date) -> SparkSeries {
        switch item {
        case .cpu:
            return fromTrend(trend, now: now, domain: 0...100) { $0.cpu }
        case .memory:
            return fromTrend(trend, now: now, domain: 0...100) { $0.pressurePercent.map { Double($0) } }
        case .battery:
            return fromTrend(trend, now: now, domain: 0...100) { $0.battery }
        case .thermal:
            return fromTrend(trend, now: now, domain: 0...3) { $0.thermal.map { Double($0.rank) } }
        case .network:
            var s = fromTrend(trend, now: now, domain: 0...1_000_000) { p in
                guard let rx = p.rx, let tx = p.tx else { return nil }
                return rx + tx
            }
            let top = s.runs.flatMap { $0 }.map { $0.v }.max() ?? 0
            s.domain = 0...max(1_000_000, top * 1.1)
            return s
        case .disk:
            let start = now.addingTimeInterval(-7 * 86400)
            let points = disk.filter { $0.t >= start && $0.t <= now }.map { SparkPoint(t: $0.t, v: $0.gb) }
            let low = points.map { $0.v }.min() ?? 0
            let high = points.map { $0.v }.max() ?? 10
            let span = max(10, high - low)
            let mid = (high + low) / 2
            return SparkSeries(runs: points.isEmpty ? [] : [thin(points, limit: 90)], window: start...now,
                               domain: (mid - span / 2)...(mid + span / 2))
        case .anomalyLog:
            return .empty(now: now)
        }
    }
}
