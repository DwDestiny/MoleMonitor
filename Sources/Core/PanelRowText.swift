// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, current readings, the data state, the trend and the disk series (docs/DESIGN_V3.md 5; docs/DESIGN_V2.md 2.8, 5.3, 5.5, 7.3, 8.1).
// Output: PanelRowState (one breakdown row as plain texts and a dot, with the plain-words problem note), AnomalyBar (sidebar header data),
//         PanelFooterState, PanelAreaState (the record row of the main column) and the mini curve data.
// Pos: All texts of the main column in one pure place, so Linux tests check them (gates W02, W19, W21). Foundation only.
//      A measured zero, a missing value, a collecting value and a stale value look different (DESIGN_V2.md 2.8, 5.3).
//      A number with a unit appears in a row and never in an anomaly bar (7.3).

import Foundation

// MARK: - Dots and rows

/// The state dot of a row (DESIGN_V2.md 3.5). The shape carries the meaning, the color repeats it.
enum PanelDot: String, Equatable {
    case red, yellow
    case normal            // Gray filled circle: measured and healthy. The network row too (no health level, so always quiet)
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
    /// 11 pt prefix of the value: "压力", "可用", "swap", .
    var valuePrefix: String?
    /// 17 pt value: "23%", "+314 GB", "正常", "—", "采集中".
    var value: String
    var note: String
    var status: PanelStatusKind
    /// Line 2 of a problem row (DESIGN_V3.md 5.1): "5 天胖了 314 GB，已持续 3 小时". Nil for a row that is not a problem.
    var problemNote: String? = nil
    var id: String { item.rawValue }

    var isProblem: Bool { dot == .red || dot == .yellow }

    /// The value of a quiet row (DESIGN_V3.md 5.2). The pressure prefix is left out: the row name says "内存".
    var quietValue: String {
        if valuePrefix == "压力" { return value }
        return measurement
    }

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
        case .normal: state = "正常"
        case .collecting: state = "采集中"
        case .stale: state = "数据已过期"
        case .missing: state = "无数据"
        case .failed: state = "读取失败"
        }
        return name + "，" + state + "，" + measurement + "，" + (problemNote ?? note)
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
            // A row that already has its reading shows it as measured. Only a row without a reading is "in progress",
            // so the rows agree with the headline count "已完成 N/6 项".
            if state.value == dash { state.value = "采集中" }
            if state.value == "采集中" {
                state.status = .collecting
                state.note = "正在采集"
            } else {
                state.status = .measured
                state.dot = .normal
                if state.note.hasSuffix(dash) { state.note = "正在采集" }
            }
        case .stale(let since):
            state.status = .stale
            // No clock before the value: the prefix keeps its normal word and the value keeps its column width.
            // The headline subline names the clock of the last reading. Memory and disk keep their own note.
            if item != .memory && item != .disk { state.note = "停在 " + TextFormat.clock(since, timeZone: input.timeZone) }
        case .fresh:
            if state.dot == .missing { state.status = .missing } else if state.dot == .collecting { state.status = .collecting }
        }
        if state.isProblem && state.status == .measured {
            state.problemNote = problemNote(item, state, code: verdict?.reasonCode ?? "", since: verdict?.since, input)
        }
        return state
    }

    // MARK: Problem note (DESIGN_V3.md 5.1)

    /// Longest app name in a problem note, in width units. A longer name is cut and ends with an ellipsis.
    static let noteAppNameWidth = 6.0

    /// "人话原因，已持续 N". The plain word is 胖了 (disk), 喘不过气 (memory), 掉电太快 (battery), 跑太久 (CPU) or 发烫 (temperature).
    /// The measured number stays in the text.
    static func problemNote(_ item: SidebarItem, _ state: PanelRowState, code: String, since: Date?, _ input: PanelRowsInput) -> String {
        reason(item, state, code: code, input) + lasting(since: since, now: input.now)
    }

    /// "，已持续 3 小时", "，刚刚开始" below one minute, empty without a start time.
    static func lasting(since: Date?, now: Date) -> String {
        guard let since else { return "" }
        let text = TextFormat.duration(since: since, now: now)
        return text == "刚刚" ? "，刚刚开始" : "，已持续 " + text
    }

    private static func clipped(_ name: String) -> String {
        var out = ""
        for ch in name {
            if BubbleCopy.width(out + String(ch)) > noteAppNameWidth { return out + "\u{2026}" }
            out.append(ch)
        }
        return out
    }

    private static func reason(_ item: SidebarItem, _ state: PanelRowState, code: String, _ input: PanelRowsInput) -> String {
        let c = input.current
        switch item {
        case .disk:
            switch code {
            case "growth_1d", "growth_5d", "growth_30d":
                let word = PanelAnomalies.reasonWord(item: .disk, code: code)
                let amount = state.value.hasPrefix("+") ? String(state.value.dropFirst()) : state.value
                return state.value == dash ? word : word + " " + amount
            default: return PanelAnomalies.reasonWord(item: .disk, code: "low_space")
            }
        case .memory:
            return PanelAnomalies.reasonWord(item: .memory, code: code)
        case .battery:
            let word = PanelAnomalies.reasonWord(item: .power, code: code)
            if code == "sleep_drain", let rate = sleepRate(c.lastSleep) { return word + "，睡眠每小时 " + String(format: "%.1f%%", rate) }
            if code == "awake_drain", let rate = c.awakeDrainPerHour { return word + "，每小时 " + String(format: "%.0f%%", rate) }
            return word
        case .cpu:
            if code == "app_saturated" {
                let full = state.note
                let pct = full.split(separator: " ").last.map(String.init) ?? ""
                let name = String(full.dropLast(pct.count)).trimmingCharacters(in: .whitespaces)
                let word = PanelAnomalies.reasonWord(item: .cpu, code: code)
                if name.isEmpty || pct.isEmpty || !pct.hasSuffix("%") { return word }
                return clipped(name) + " " + word + " " + pct
            }
            return PanelAnomalies.reasonWord(item: .cpu, code: code) + "，" + state.note
        case .thermal:
            let word = PanelAnomalies.reasonWord(item: .thermal, code: code)
            if let t = c.smcCPUTemperature { return word + "，CPU " + String(format: "%.0f", t) + " \u{00B0}C" }
            return word + "，热状态" + state.value
        case .network, .anomalyLog:
            return state.note
        }
    }

    private static func dot(_ item: SidebarItem, _ v: ItemVerdict?, hasValue: Bool, _ data: DataState) -> PanelDot {
        switch data {
        case .collecting: return .collecting
        case .stale: return .stale
        case .fresh: break
        }
        guard let v else { return hasValue ? .normal : .missing }
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
            // Memory shows the full triple: the value on the right is the pressure, so the free part belongs in the note.
            let cap = CapacityFormat.memory(c)
            s.note = cap.usedOfTotalAvailable
            if code == "swap_growth", let g = c.swapGrowth30m {
                s.valuePrefix = "swap"
                s.value = TextFormat.signedBytes(g)
            } else {
                s.valuePrefix = "压力"
                s.value = c.memoryPressurePercent.map { String($0) + "%" } ?? dash
            }
        case .disk:
            let cap = CapacityFormat.disk(c)
            var growth: Int64?
            switch code {
            case "growth_1d": growth = input.diskGrowth["1d"]?.bytes
            case "growth_5d": growth = input.diskGrowth["5d"]?.bytes
            case "growth_30d": growth = input.diskGrowth["30d"]?.bytes
            default: break
            }
            // The free space stays out of the note while the value shows it ("可用 412 GB", also stale). A growth value
            // does not show it, so then the note carries it.
            s.note = growth != nil ? cap.usedOfTotalAvailable : cap.usedOfTotal
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
                if let rate = sleepRate(c.lastSleep) { s.note = "睡眠时每小时掉电 " + String(format: "%.1f%%", rate) } else { s.note = "睡眠掉电偏快" }
            case "awake_drain":
                if let rate = c.awakeDrainPerHour { s.note = "每小时掉电 " + String(format: "%.0f%%", rate) } else { s.note = "掉电偏快" }
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

/// The reason, the duration and the start of one anomaly. The sidebar header shows them (DESIGN_V2.md 7.2 as changed on
/// 2026-10-12). It holds no measured value: the reason word, a duration and a start time only (7.3).
struct AnomalyBar: Equatable, Identifiable {
    var item: HealthItem
    var sidebar: SidebarItem
    var level: HealthLevel
    /// "磁盘异常", "内存留意".
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
    /// The plain reason phrase of a reason code, the one source for the main column and the record page (DESIGN_V3.md 9).
    /// It carries no measured value. Level does not change it: the marker and the tint carry the level.
    /// "5 天胖了", "喘不过气", "掉电太快", "跑太久", "发烫", "快满了，可用空间不足".
    static func reasonWord(item: HealthItem, code: String) -> String {
        switch (item, code) {
        case (.disk, "growth_1d"): return "1 天胖了"
        case (.disk, "growth_5d"): return "5 天胖了"
        case (.disk, "growth_30d"): return "30 天胖了"
        case (.disk, "low_space"): return "快满了，可用空间不足"
        case (.memory, "swap_growth"): return "喘不过气，swap 在涨"
        case (.memory, _): return "喘不过气"
        case (.cpu, _): return "跑太久"
        case (.thermal, _): return "发烫"
        case (.power, _): return "掉电太快"
        default: return "需要处理"
        }
    }

    /// The measured value that the record page appends to the reason phrase ("5 天胖了 314 GB", "喘不过气，峰值 87%",
    /// "掉电太快，每小时 34%"). Number style: no space before "%".
    static func recordEvidence(item: HealthItem, code: String, value: Double?, unit: String?) -> String {
        let word = reasonWord(item: item, code: code)
        guard let v = value, v.isFinite else { return word }
        let n = String(format: "%.0f", v)
        switch item {
        case .disk:
            return code == "low_space" ? "快满了，可用 \(n) GB" : word + " " + n + " " + (unit ?? "GB")
        case .memory:
            return unit == "%" ? word + "，峰值 " + n + "%" : word + "，swap " + n + " " + (unit ?? "GB")
        case .cpu:
            return word + "，峰值 " + n + "%"
        case .power:
            let rate = code == "sleep_drain" ? String(format: "%.1f", v) : n
            return word + (code == "sleep_drain" ? "，睡眠每小时 " : "，每小时 ") + rate + "%"
        case .thermal:
            return word
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

    /// The single line of the anomaly area: "异常 4 项，最久已持续 3 小时". The duration part is left out when no start is known.
    static func summary(items: [HealthItem], verdicts: [ItemVerdict], now: Date) -> String {
        var text = "异常 \(items.count) 项"
        let starts = items.compactMap { item in verdicts.first(where: { $0.item == item })?.since }
        if let first = starts.min() {
            let long = TextFormat.duration(since: first, now: now)
            text += "，最久已持续 " + long
        }
        return text
    }

    /// The line under the sidebar title of a problem item: "已持续 3 小时 12 分，开始 06:20". Nil for a normal item.
    static func episode(_ verdict: ItemVerdict?, now: Date, timeZone: TimeZone = TimeZone.current) -> String? {
        guard let v = verdict, v.level == .red || v.level == .yellow, let since = v.since else { return nil }
        return "已持续 " + TextFormat.duration(since: since, now: now) + "，" + startText(since, now: now, timeZone: timeZone)
    }

    /// The bars for the anomalies, in plan order. `shown` comes from `PanelLayoutPlan.shownAnomalies`.
    static func bars(shown: [HealthItem], verdicts: [ItemVerdict], now: Date, timeZone: TimeZone = TimeZone.current) -> [AnomalyBar] {
        shown.compactMap { item in
            guard let v = verdicts.first(where: { $0.item == item }) else { return nil }
            let row = SidebarItem(item)
            return AnomalyBar(item: item, sidebar: row, level: v.level, title: row.label + levelWord(v.level),
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
    case stale(minutes: Int, records: Int?)
    /// A problem row is shown. The record row then holds only the entry "近 7 天 N 条记录 ›".
    case anomalies(records: Int?)

    static func make(dataState: DataState, anomalyCount: Int, records: Int?, now: Date) -> PanelAreaState {
        switch dataState {
        case .collecting: return .collecting
        case .stale(let since): return .stale(minutes: max(1, Int(now.timeIntervalSince(since) / 60)), records: records)
        case .fresh: return anomalyCount > 0 ? .anomalies(records: records) : .quiet(records: records)
        }
    }

    var text: String {
        switch self {
        case .quiet: return "没有异常"
        case .collecting: return "正在采集第一组数据"
        case .stale: return ""   // the headline subline carries the age (BubbleCopy.subline)
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
    var enabled: Bool
    var copiedTitle: String
    /// The bubble text after a successful copy (DESIGN_V2.md 8.1).
    var copiedBubble: String
    var failedBubble: String

    /// The primary button is hidden, not disabled, while the first data is collected (DESIGN_V3.md 5.4).
    var hidden: Bool { mode == .inspectDisabled }

    static func make(dataState: DataState, anomalyCount: Int) -> PanelFooterState {
        if case .collecting = dataState {
            return PanelFooterState(mode: .inspectDisabled, title: "复制日常巡检提示词", enabled: false,
                                    copiedTitle: "已复制", copiedBubble: "巡检单已复制，交给 Agent 吧",
                                    failedBubble: "没复制上，再点一次试试")
        }
        if anomalyCount > 0 {
            return PanelFooterState(mode: .copyProblems, title: "复制排查提示词", enabled: true,
                                    copiedTitle: "已复制", copiedBubble: "已复制，去问你的 Agent 吧",
                                    failedBubble: "没复制上，再点一次试试")
        }
        return PanelFooterState(mode: .inspect, title: "复制日常巡检提示词", enabled: true,
                                copiedTitle: "已复制", copiedBubble: "巡检单已复制，交给 Agent 吧",
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
            var lastKept = Date.distantPast
            for p in segment where p.t >= start && p.t <= now {
                // Keep one point per 20 s, so 2 s live points and 30 s points do not mix (DESIGN_V2.md 5.5).
                if p.t.timeIntervalSince(lastKept) < 20 && p.t != segment.last?.t { continue }
                lastKept = p.t
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
