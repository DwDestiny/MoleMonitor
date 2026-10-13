// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for PanelLayout v2 (docs/DESIGN_V2.md 2.3, 5.2, 7.2) and PanelRowText (rows, anomaly bars, footer).
// Pos: Called from main.swift via runLayoutTests(); no top-level code in this file. Owner WP-C.

import Foundation

private func lv(_ item: HealthItem, _ level: HealthLevel, code: String = "x", since minutes: Double = 30) -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: code, headline: "x",
                since: level == .green ? nil : now.addingTimeInterval(-minutes * 60), levelChangedAt: nil, alert: nil)
}

private func verdicts(_ problems: [(HealthItem, HealthLevel)], battery: Bool = true) -> [ItemVerdict] {
    HealthItem.allCases.map { item in
        if let p = problems.first(where: { $0.0 == item }) { return lv(item, p.1) }
        if item == .power && !battery { return lv(item, .notApplicable) }
        return lv(item, .green)
    }
}

private func plan(_ problems: [(HealthItem, HealthLevel)], battery: Bool = true) -> PanelLayoutPlan {
    PanelLayout.plan(PanelLayoutInput(verdicts: verdicts(problems, battery: battery), hasBattery: battery))
}

func runLayoutTests() {
    section("PanelLayout v2: height formula")
    let all: [(HealthItem, HealthLevel)] = [(.disk, .red), (.memory, .red), (.power, .yellow), (.cpu, .yellow), (.thermal, .yellow)]
    for (count, laptop) in [(0, 524.0), (1, 524.0), (2, 524.0), (3, 524.0), (4, 524.0), (5, 524.0)] {
        let p = plan(Array(all.prefix(count)))
        expect(p.height == laptop, "laptop \(count) anomalies: \(laptop), got \(p.height)")
        expect(p.rows.count == 6, "laptop has 6 rows")
    }
    let desktopAll: [(HealthItem, HealthLevel)] = [(.disk, .red), (.memory, .red), (.cpu, .yellow), (.thermal, .yellow)]
    for (count, desktop) in [(0, 484.0), (1, 484.0), (2, 484.0), (3, 484.0), (4, 484.0)] {
        let p = plan(Array(desktopAll.prefix(count)), battery: false)
        expect(p.height == desktop, "desktop \(count) anomalies: \(desktop), got \(p.height)")
        expect(p.rows.count == 5 && !p.rows.contains(.battery), "desktop has 5 rows, no battery")
    }
    expect(PanelMetrics.width == 352 && PanelMetrics.widthWithSidebar == 672, "widths 352 and 672")
    expect(PanelMetrics.dotColumn + PanelMetrics.dotGap + PanelMetrics.textColumn + PanelMetrics.valueColumn
           + PanelMetrics.sparkGap + PanelMetrics.sparkWidth == PanelMetrics.contentWidth, "row columns add up to 320")

    section("PanelLayout v2: row order")
    let quiet = plan([])
    expect(quiet.quiet && quiet.rows == SidebarItem.fixedRows, "quiet: fixed order")
    expect(quiet.sections == [.hero, .rows, .anomaly, .footer], "four sections in order")
    let mixed = plan([(.thermal, .yellow), (.disk, .red)])
    expect(mixed.rows.prefix(2) == [.disk, .thermal], "red problem before yellow problem, got \(mixed.rows)")
    expect(Array(mixed.rows.dropFirst(2)) == [.cpu, .memory, .network, .battery], "normal rows keep the fixed order, got \(mixed.rows)")
    let four = plan(Array(all.prefix(4)))
    expect(four.anomalies.count == 4 && four.height == quiet.height, "4 anomalies: all listed, height unchanged")
    expect(plan([(.power, .yellow)], battery: false).anomalies.isEmpty, "no battery anomaly on a desktop")

    section("PanelRows: values and notes")
    var c = CurrentReadings()
    c.cpuPercent = 18; c.cpuMean5m = 18; c.cpuMean10m = 94
    c.memoryPressurePercent = 23
    c.physicalMemory = 64 << 30
    c.diskTotal = 995_000_000_000; c.diskUsed = 593_000_000_000; c.diskPurgeable = 21_000_000_000
    c.rx = 1_100_000; c.tx = 96_000
    c.batteryPercent = 82; c.powerSource = .ac
    c.thermal = .nominal; c.smcCPUTemperature = 51
    let input = PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .fresh, now: now, timeZone: TimeZone(identifier: "UTC")!)
    let rows = PanelRows.make(order: SidebarItem.fixedRows, input: input)
    expect(rows.count == 6 && rows.map { $0.item } == SidebarItem.fixedRows, "six rows")
    expect(rows[0].value == "18%" && rows[0].note == "5 分钟均值 18%" && rows[0].dot == .normal, "cpu row: \(rows[0])")
    expect(rows[1].valuePrefix == "压力" && rows[1].value == "23%", "memory pressure 23%, got \(rows[1].measurement)")
    expect(rows[2].valuePrefix == "可用" && rows[2].value == "402 GB" && rows[2].note == "已用 593 / 995 GB", "disk row: \(rows[2])")
    expect(rows[3].dot == .normal, "network has no health level: a quiet filled dot, not the hollow collecting dot")
    expect(rows[4].value == "82%" && rows[4].note == "电源适配器", "battery row: \(rows[4])")
    expect(rows[5].value == "正常" && rows[5].note.hasPrefix("CPU 51"), "thermal row: \(rows[5])")
    for r in rows { expect(!r.isProblem, "healthy row \(r.name) is not a problem") }

    var noPressure = c
    noPressure.memoryPressurePercent = nil
    let mp = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: noPressure, dataState: .fresh, now: now))
    expect(mp.value == "—" && mp.dot == .missing && mp.status == .missing, "nil pressure shows the dash and the missing dot")
    var zero = c
    zero.memoryPressurePercent = 0
    let mz = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: zero, dataState: .fresh, now: now))
    expect(mz.value == "0%" && mz.dot == .normal, "measured zero shows 0%")
    var high = c
    high.memoryPressurePercent = 95
    let mh = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: high, dataState: .fresh, now: now))
    expect(mh.dot == .normal, "95% with a normal level stays a gray dot")
    let mred = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([(.memory, .red)]), current: noPressure, dataState: .fresh, now: now))
    expect(mred.dot == .red, "a problem keeps the problem dot when the percent is missing")

    let growth = ["5d": DiskGrowth(window: "5d", bytes: 314_000_000_000, netBytes: nil, fromMinAt: nil, coveredHours: 120, status: .ok)]
    let dverdicts = [lv(.disk, .red, code: "growth_5d"), lv(.cpu, .green), lv(.memory, .green), lv(.thermal, .green), lv(.power, .green)]
    let dg = PanelRows.row(.disk, PanelRowsInput(verdicts: dverdicts, current: c, dataState: .fresh, diskGrowth: growth, now: now))
    expect(dg.value == "+314 GB" && dg.dot == .red && dg.isProblem, "disk growth row: \(dg)")
    expect(dg.note == "已用 593 / 995 GB，可用 402 GB", "disk growth row: the value is no free space, so the note carries it, got \(dg.note)")
    expect(rows[2].note == "已用 593 / 995 GB", "healthy disk: the value is the free space, the note does not repeat it")
    let dstale = PanelRows.row(.disk, PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .stale(now.addingTimeInterval(-3600)), now: now))
    expect(dstale.note == "已用 593 / 995 GB", "stale disk: the value still is the free space, so the note does not repeat it, got \(dstale.note)")
    var withMemory = c
    withMemory.memory = MemoryBreakdown(app: Int64(40.2 * Double(1 << 30)), wired: Int64(10.0 * Double(1 << 30)),
                                        compressed: Int64(8.0 * Double(1 << 30)), total: 64 << 30)
    let mem = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: withMemory, dataState: .fresh, now: now))
    expect(mem.note == "已用 58.2 / 64 GB，可用 5.8 GB", "memory note shows used, total and available, got \(mem.note)")
    var drain = c
    drain.awakeDrainPerHour = 34
    drain.lastSleep = SleepRecord(sleptAt: now.addingTimeInterval(-3 * 3600), wokeAt: now, batteryBefore: 80, batteryAfter: 70, onBatteryBeforeSleep: true)
    let awakeRow = PanelRows.row(.battery, PanelRowsInput(verdicts: [lv(.power, .yellow, code: "awake_drain")], current: drain, dataState: .fresh, now: now))
    expect(awakeRow.note == "每小时掉电 34%", "awake drain note, got \(awakeRow.note)")
    let sleepRow = PanelRows.row(.battery, PanelRowsInput(verdicts: [lv(.power, .yellow, code: "sleep_drain")], current: drain, dataState: .fresh, now: now))
    expect(sleepRow.note == "睡眠时每小时掉电 3.3%", "sleep drain note in the same sentence form, got \(sleepRow.note)")
    func ago(_ minutes: Double) -> String { TextFormat.duration(since: now.addingTimeInterval(-minutes * 60), now: now) }
    expect(ago(180) == "3 小时" && ago(200) == "3 小时 20 分" && ago(45) == "45 分" && ago(0.5) == "刚刚", "duration leaves out a zero remainder: \(ago(180)) \(ago(200)) \(ago(45))")
    expect(ago(48 * 60) == "2 天" && ago(26 * 60) == "1 天 2 小时", "days: \(ago(48 * 60)) \(ago(26 * 60))")
    expect(TextFormat.span(seconds: 3600) == "1 小时" && TextFormat.span(seconds: 3900) == "1 小时 5 分", "span leaves out a zero remainder")

    let col = PanelRows.row(.cpu, PanelRowsInput(verdicts: verdicts([]), current: CurrentReadings(), dataState: .collecting, now: now))
    expect(col.dot == .collecting && col.status == .collecting, "collecting row")
    let st = PanelRows.row(.cpu, PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .stale(now.addingTimeInterval(-3600)),
                                                now: now, timeZone: TimeZone(identifier: "UTC")!))
    expect(st.dot == .stale && st.valuePrefix == nil && st.note == "5 分钟均值 18%", "stale cpu row keeps its normal note, no clock time, got \(String(describing: st.valuePrefix)) \(st.note)")
    let stm = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .stale(now.addingTimeInterval(-3600)),
                                                    now: now, timeZone: TimeZone(identifier: "UTC")!))
    expect(stm.valuePrefix == "压力" && stm.dot == .stale, "stale memory row keeps its prefix, no clock time, got \(String(describing: stm.valuePrefix))")
    for item in SidebarItem.fixedRows {
        let r = PanelRows.row(item, PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .stale(now.addingTimeInterval(-3600)),
                                                   now: now, timeZone: TimeZone(identifier: "UTC")!))
        expect(!r.note.contains("11:00") && !r.note.contains("停在") && r.valuePrefix != "11:00", "stale \(item) row says no time, got \(r.note)")
    }

    section("PanelAnomalies: bars, reasons, start times")
    let utc = TimeZone(identifier: "UTC")!
    expect(PanelAnomalies.startText(now.addingTimeInterval(-3600), now: now, timeZone: utc) == "开始 11:00", "same day start")
    expect(PanelAnomalies.startText(now.addingTimeInterval(-14 * 3600), now: now, timeZone: utc) == "开始 昨天 22:00", "yesterday start")
    let reasons: [(HealthItem, String, String)] = [(.disk, "growth_1d", "1 天增长"), (.disk, "growth_5d", "5 天增长"), (.disk, "growth_30d", "30 天增长"),
        (.disk, "low_space", "可用空间不足"), (.memory, "pressure_warning", "压力警告"), (.memory, "pressure_critical", "压力严重"),
        (.memory, "swap_growth", "swap 30 分钟增长"), (.cpu, "cpu_mean_10m", "持续高负载"), (.cpu, "app_saturated", "App 持续占用"),
        (.thermal, "thermal_fair", "热状态偏高"), (.thermal, "thermal_serious", "热状态严重"), (.thermal, "thermal_critical", "热状态临界"),
        (.power, "sleep_drain", "睡眠掉电偏快"), (.power, "awake_drain", "掉电偏快")]
    for (item, code, word) in reasons { expect(PanelAnomalies.reasonWord(item: item, code: code) == word, "reason \(code)") }
    let sv = [lv(.disk, .red, code: "growth_5d", since: 192), lv(.memory, .yellow, code: "pressure_warning", since: 20)]
    expect(PanelAnomalies.summary(items: [.disk, .memory], verdicts: sv, now: now) == "异常 2 项，最久已持续 3 小时 12 分", "summary: \(PanelAnomalies.summary(items: [.disk, .memory], verdicts: sv, now: now))")
    expect(PanelAnomalies.episode(sv[0], now: now, timeZone: utc) == "已持续 3 小时 12 分，开始 08:48", "episode: \(String(describing: PanelAnomalies.episode(sv[0], now: now, timeZone: utc)))")
    expect(PanelAnomalies.episode(lv(.cpu, .green), now: now, timeZone: utc) == nil, "no episode for a normal item")
    let bars = PanelAnomalies.bars(shown: [.disk, .memory],
                                   verdicts: [lv(.disk, .red, code: "growth_5d", since: 192), lv(.memory, .yellow, code: "pressure_warning", since: 20)],
                                   now: now, timeZone: utc)
    expect(bars.count == 2 && bars[0].title == "磁盘异常" && bars[1].title == "内存留意", "bar titles: \(bars.map { $0.title })")
    expect(bars[0].duration == "3 小时 12 分", "duration, got \(bars[0].duration)")
    for b in bars {
        let digits = b.reason.contains(where: { $0.isNumber })
        expect(!b.reason.contains("GB") && !b.reason.contains("%") && !b.reason.contains("\u{00B0}"), "no measured value in the reason: \(b.reason) \(digits)")
    }
    for r in rows + [dg] {
        for b in bars { expect(r.measurement != b.reason && !b.title.contains(r.measurement), "no repeated measured value") }
    }

    section("PanelFooter and PanelArea")
    let f0 = PanelFooterState.make(dataState: .fresh, anomalyCount: 0)
    expect(f0.mode == .inspect && f0.title == "复制日常巡检提示词" && f0.subtitle == "粘贴给你的 Agent" && f0.enabled, "quiet footer has the same shape as the problem footer")
    let f1 = PanelFooterState.make(dataState: .fresh, anomalyCount: 2)
    expect(f1.mode == .copyProblems && f1.title == "复制排查提示词" && f1.subtitle == "粘贴给你的 Agent", "problem footer")
    expect(f1.copiedTitle == "\u{2713} 已复制" && f1.copiedBubble == "已复制，去问你的 Agent 吧", "copied texts")
    expect(!PanelFooterState.make(dataState: .collecting, anomalyCount: 0).enabled, "collecting footer is disabled")
    expect(PanelFooterState.make(dataState: .stale(now), anomalyCount: 1).mode == .copyProblems, "stale footer follows the problems")
    expect(PanelAreaState.make(dataState: .fresh, anomalyCount: 0, records: 3, now: now) == .quiet(records: 3), "quiet area")
    expect(PanelAreaState.recordsText(0) == "近 7 天无记录" && PanelAreaState.recordsText(3) == "近 7 天 3 条记录", "records text")
    expect(PanelAreaState.make(dataState: .fresh, anomalyCount: 1, records: nil, now: now) == .anomalies, "anomaly area")

    section("SparkSeries")
    let empty = SparkSeries.empty(now: now)
    expect(empty.isEmpty && empty.last == nil, "empty spark")
    expect(SparkSeries.thin((0..<500).map { SparkPoint(t: now, v: Double($0)) }, limit: 90).count == 90, "thin to 90 points")

    runSidebarTests()
}

func runSidebarTests() {
    let utc = TimeZone(identifier: "UTC")!
    section("Sidebar: ranges")
    expect(SidebarRange.options(for: .cpu) == [.h2, .h24, .d7], "cpu ranges")
    expect(SidebarRange.options(for: .disk) == [.h24, .d7, .d30] && SidebarRange.defaultRange(for: .disk) == .d7, "disk ranges")
    expect(SidebarRange.defaultRange(for: .memory) == .h2 && SidebarRange.options(for: .anomalyLog) == [.d7, .d30], "defaults")
    expect(SidebarRange.covering(start: now.addingTimeInterval(-3 * 3600), now: now, item: .cpu) == .h24, "covering 3 h gives 24 h")
    expect(SidebarRange.covering(start: now.addingTimeInterval(-10 * 86400), now: now, item: .cpu) == .d7, "covering is capped")

    section("Sidebar: LTTB and runs")
    let pts = (0..<1000).map { ChartPoint(t: now.addingTimeInterval(Double($0) * 60), v: Double($0 % 50)) }
    let cut = ChartSampling.lttb(pts, limit: 360)
    expect(cut.count == 360 && cut.first == pts.first && cut.last == pts.last, "lttb keeps 360 points with both ends, got \(cut.count)")
    expect(ChartSampling.lttb(Array(pts.prefix(100)), limit: 360).count == 100, "short list is unchanged")
    let samples: [(t: Date, v: Double?)] = [(now, 1), (now.addingTimeInterval(30), 2), (now.addingTimeInterval(60), nil),
                                            (now.addingTimeInterval(90), 3), (now.addingTimeInterval(1000), 4)]
    let runs = ChartSampling.runs(samples, gap: 120, limit: 240)
    expect(runs.count == 3 && runs[0].count == 2 && runs[1].count == 1 && runs[2].count == 1, "a nil value and a gap split runs, got \(runs.map { $0.count })")

    section("Sidebar: charts")
    let fine = (0..<240).map { i in TrendPoint(t: now.addingTimeInterval(-Double(239 - i) * 30), cpu: Double(i % 100)) }
    var input = SidebarInput(item: .cpu, range: .h2, trend: TrendSeries(segments: [fine]), rollups: [], diskSeries: [], diskTrigger: nil,
                             sleeps: [], current: CurrentReadings(), verdicts: [], status: nil, now: now, timeZone: utc)
    let c2 = SidebarChart.make(input)
    expect(c2.lines.count == 1 && c2.lines[0].pointCount == 240 && c2.thresholds == [70, 90], "cpu 2 h line has 240 points")
    expect(c2.recordedText == nil && c2.emptyHead < 0.01, "full history has no recorded note")
    expect(c2.readout(at: now, timeZone: utc)?.hasSuffix("%") == true, "readout ends with percent, got \(String(describing: c2.readout(at: now, timeZone: utc)))")
    input.range = .h24
    let c24 = SidebarChart.make(input)
    expect(c24.isEmpty && c24.firstData == nil && c24.emptyHead == 1, "24 h without rollups is empty")
    var ws = [RollupWindow]()
    for i in 0..<288 { ws.append(RollupWindow(end: now.addingTimeInterval(-Double(287 - i) * 300), pointCount: 10, cpuMean: 20, cpuPeak: 40)) }
    input.rollups = ws
    let c24b = SidebarChart.make(input)
    expect(c24b.lines[0].pointCount == 288 && c24b.recordedText == nil, "24 h from 288 windows, got \(c24b.lines[0].pointCount)")
    input.range = .d7
    let c7 = SidebarChart.make(input)
    expect(c7.lines[0].pointCount == 288 && c7.recordedText == "已记录 23 小时", "7 d with 23 hours of history, got \(String(describing: c7.recordedText))")
    let stats = SidebarStats.make(input)
    expect(stats.map { $0.label } == ["当前", "均值", "峰值"] && stats[1].value == "20%" && stats[2].value == "40%", "cpu stats \(stats)")

    section("Sidebar: network and thermal")
    input.item = .network
    input.range = .h24
    input.rollups = (0..<288).map { RollupWindow(end: now.addingTimeInterval(-Double(287 - $0) * 300), pointCount: 10, rxKBps: 100, txKBps: 20) }
    let net = SidebarChart.make(input)
    expect(net.bars.count >= 24 && net.bars.count <= 25 && net.lines.isEmpty, "24 h network gives hourly bars, got \(net.bars.count)")
    let nstats = SidebarStats.make(input)
    expect(nstats.count == 3 && nstats[2].value.hasPrefix("至少 "), "30 day traffic is a lower bound with 1 day of history, got \(nstats[2].value)")
    input.item = .thermal
    input.range = .h2
    input.trend = TrendSeries(segments: [(0..<10).map { TrendPoint(t: now.addingTimeInterval(-Double(9 - $0) * 30), cpu: 10, thermal: $0 < 5 ? .nominal : .fair) }])
    let th = SidebarChart.make(input)
    expect(th.style == .step && th.domain == 0...3 && th.lines.count == 2 && th.lines[1].secondary, "thermal step with a CPU line")
    expect(th.legend == [ChartLegendEntry(text: "热状态", quiet: false), ChartLegendEntry(text: "CPU 占用 0\u{2013}100%", quiet: true)], "thermal legend, got \(th.legend)")
    expect(th.yLabels?.top == "临界" && th.yLabels?.bottom == "正常", "thermal axis words, got \(String(describing: th.yLabels))")
    expect(c2.legend.isEmpty && c2.yLabels?.top == "100%" && c2.yLabels?.bottom == "0%", "one line has no legend, percent axis")
    input.item = .network
    input.range = .h2
    input.trend = TrendSeries(segments: [(0..<10).map { TrendPoint(t: now.addingTimeInterval(-Double(9 - $0) * 30), rx: 2_000_000, tx: 100_000) }])
    let net2 = SidebarChart.make(input)
    expect(net2.legend.map { $0.text } == ["\u{2193} 下行", "\u{2191} 上行"] && net2.legend.map { $0.quiet } == [false, true] && net2.legend.map { $0.dashed } == [false, true], "network legend with arrows, got \(net2.legend)")
    input.item = .memory
    input.trend = TrendSeries(segments: [(0..<10).map { TrendPoint(t: now.addingTimeInterval(-Double(9 - $0) * 30), swapUsed: 9_800_000_000, pressurePercent: 80) }])
    let mem2 = SidebarChart.make(input)
    expect(mem2.legend.map { $0.text } == ["压力", "swap 0\u{2013}11 GB"], "memory legend with the swap scale, got \(mem2.legend)")
    input.item = .thermal
    expect(th.readout(at: now, timeZone: utc)?.contains("偏热") == true, "thermal readout uses the word")

    section("Sidebar: ranking and footnotes")
    let apps = [AppUsage(key: "a", name: "A", bundleID: "x.a", cpuPercent: 94, memoryBytes: 2_000_000_000, memoryBasis: "footprint", processCount: 1,
                         isSystem: false, diskWrittenBytes: 500_000_000),
                AppUsage(key: "b", name: "B", bundleID: nil, cpuPercent: 10, memoryBytes: 400_000_000, memoryBasis: "footprint", processCount: 1,
                         isSystem: false, diskWrittenBytes: nil)]
    let cpuTable = SidebarRanking.make(.cpu, apps: apps, interfaces: nil, blockers: nil)
    expect(cpuTable?.rows.count == 2 && cpuTable?.rows[0].value == "94%", "cpu ranking")
    let writers = [DiskWriterRow(key: "a", name: "A", bundleID: "x.a", bytes: 500_000_000, isSystem: false),
                   DiskWriterRow(key: "z", name: "Z", bundleID: nil, bytes: 0, isSystem: false)]
    let disk = SidebarRanking.make(.disk, apps: apps, interfaces: nil, blockers: nil, diskWriters: writers)
    expect(disk?.rows.count == 1 && disk?.rows[0].value == "500 MB", "disk write ranking, got \(String(describing: disk?.rows.first?.value))")
    let noWrites = SidebarRanking.make(.disk, apps: apps, interfaces: nil, blockers: nil, diskWriters: nil)
    expect(noWrites?.rows.isEmpty == true && noWrites?.emptyText?.hasPrefix("\u{2014}") == true, "missing disk writes are not zero")
    let blockerTable = SidebarRanking.make(.battery, apps: [], interfaces: nil, blockers: [SleepBlocker(name: "Zoom", preventsSystemSleep: true, preventsDisplaySleep: true)])
    expect(blockerTable?.rows.first?.value == "防止系统睡眠、防止显示器睡眠", "sleep blocker kinds")
    let nets = SidebarRanking.make(.network, apps: [], interfaces: [InterfaceRate(name: "en0", displayName: "Wi-Fi", downBytesPerSec: 1_100_000, upBytesPerSec: 96_000, totalDown: 5, totalUp: 6),
                                                             InterfaceRate(name: "utun3", displayName: "utun3", downBytesPerSec: 9_000_000, upBytesPerSec: 0, totalDown: 0, totalUp: 0)], blockers: nil)
    expect(nets?.rows.count == 1 && nets?.rows[0].name == "Wi-Fi" && nets?.rows[0].value == "\u{2193}1.1 MB/s \u{2191}96 KB/s", "network ranking skips VPN, got \(String(describing: nets?.rows.first?.value))")
    expect(SidebarRanking.make(.network, apps: [], interfaces: nil, blockers: nil)?.emptyText?.hasPrefix("\u{2014}") == true, "no interface data is a dash")
    expect(SidebarRanking.make(.battery, apps: [], interfaces: nil, blockers: [])?.emptyText == "没有 App 阻止睡眠", "no blockers")
    expect(SidebarRanking.make(.anomalyLog, apps: apps, interfaces: nil, blockers: nil) == nil, "log has no ranking")
    expect(SidebarFootnote.lines(.battery, current: CurrentReadings()) == ["这不是耗电排行。macOS 不提供可靠的每应用耗电数据。"], "battery footnote")
    expect(SidebarFootnote.lines(.network, current: CurrentReadings()).first?.contains("按网卡分列") == true, "network footnote")

    section("Sidebar: anomaly records")
    let e1 = EventRecord(item: .disk, first: .yellow, peak: .red, reasonCode: "growth_1d", start: now.addingTimeInterval(-3600),
                         end: nil, peakValue: 314, unit: "GB", app: nil, endEstimated: false)
    let e2 = EventRecord(item: .cpu, first: .yellow, peak: .yellow, reasonCode: "cpu_mean_10m", start: now.addingTimeInterval(-30 * 3600),
                         end: now.addingTimeInterval(-29 * 3600), peakValue: 94, unit: "%", app: "Xcode", endEstimated: true)
    let groups = SidebarRecords.groups([e2, e1], days: 7, now: now, timeZone: utc)
    expect(groups.count == 2 && groups[0].title == "今天" && groups[1].title == "昨天", "groups today and yesterday, got \(groups.map { $0.title })")
    expect(groups[0].rows[0].span.hasSuffix("进行中") && groups[0].rows[0].ongoing, "ongoing record")
    expect(groups[1].rows[0].duration.hasPrefix("约 ") && groups[1].rows[0].evidence.contains("Xcode"), "estimated end and app name")
    let e3 = EventRecord(item: .power, first: .yellow, peak: .yellow, reasonCode: "awake_drain", start: now.addingTimeInterval(-600), end: nil,
                         peakValue: 34, unit: "%/h", app: nil, endEstimated: false)
    let e4 = EventRecord(item: .power, first: .yellow, peak: .yellow, reasonCode: "sleep_drain", start: now.addingTimeInterval(-600), end: nil,
                         peakValue: 3.3, unit: "%/h", app: nil, endEstimated: false)
    expect(SidebarRecords.row(e3, now: now, tz: utc).evidence == "每小时掉电 34%", "awake drain in the log, got \(SidebarRecords.row(e3, now: now, tz: utc).evidence)")
    expect(SidebarRecords.row(e4, now: now, tz: utc).evidence == "睡眠时每小时掉电 3.3%", "sleep drain in the log, got \(SidebarRecords.row(e4, now: now, tz: utc).evidence)")
    expect(SidebarRecords.dayTitle(20000, today: 20010).contains("月") && SidebarRecords.dayTitle(20000, today: 20010).contains("周"), "older day title")
    let rstats = SidebarStats.make(SidebarInput(item: .anomalyLog, range: .d7, trend: .empty, rollups: [], diskSeries: [], diskTrigger: nil, sleeps: [],
                                                current: CurrentReadings(), verdicts: [], status: nil, now: now, timeZone: utc), events: [e1, e2])
    expect(rstats[0].value == "2" && rstats[1].value == "1 小时 0 分" || rstats[1].value.contains("小时"), "record stats \(rstats)")
}
