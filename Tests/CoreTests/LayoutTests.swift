// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for PanelLayout (docs/DESIGN_V3.md 3.3, 5; DESIGN_V2.md 5.2) and PanelRowText (rows, problem notes, records, footer).
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
    section("PanelLayout v3: height formula (DESIGN_V3.md 3.3)")
    // The expected values are computed from PanelMetrics, with the parts written out here. They do not call PanelLayout.height.
    func expected(items: Int, problems: Int, hero: Double) -> Double {
        let expanded = min(PanelMetrics.maxProblemRows, problems)
        let quietItems = items - expanded
        let quietRows = Double((quietItems + 1) / 2)
        var rowsHeight = quietRows * PanelMetrics.quietRow
        if expanded > 0 { rowsHeight += Double(expanded) * PanelMetrics.problemRow + Double(expanded - 1) * PanelMetrics.problemRowGap }
        return PanelMetrics.topPadding + hero + PanelMetrics.heroGap + rowsHeight + PanelMetrics.rowsToRecordGap
            + PanelMetrics.recordRow + PanelMetrics.recordToFooterGap + PanelMetrics.footer + PanelMetrics.bottomPadding
    }
    let all: [(HealthItem, HealthLevel)] = [(.disk, .red), (.memory, .red), (.power, .yellow), (.cpu, .yellow), (.thermal, .yellow)]
    for count in 0...5 {
        let p = plan(Array(all.prefix(count)))
        let want = expected(items: 6, problems: count, hero: PanelMetrics.hero)
        expect(p.height == want, "laptop \(count) anomalies: \(want), got \(p.height)")
        expect(p.rows.count == 6, "laptop has 6 rows")
        expect(p.problemRowCount == min(3, count), "laptop \(count) anomalies: \(min(3, count)) expanded rows")
    }
    let desktopAll: [(HealthItem, HealthLevel)] = [(.disk, .red), (.memory, .red), (.cpu, .yellow), (.thermal, .yellow)]
    for count in 0...4 {
        let p = plan(Array(desktopAll.prefix(count)), battery: false)
        let want = expected(items: 5, problems: count, hero: PanelMetrics.hero)
        expect(p.height == want, "desktop \(count) anomalies: \(want), got \(p.height)")
        expect(p.rows.count == 5 && !p.rows.contains(.battery), "desktop has 5 rows, no battery")
    }
    // All green with 6 items is at most 290 pt with the 64 pt headline block (DESIGN_V3.md 3.3, 4.1).
    for hero in [PanelMetrics.hero, 64.0] {
        let green = PanelLayout.height(hasBattery: true, problems: 0, hero: hero)
        expect(green == expected(items: 6, problems: 0, hero: hero), "all green with hero \(hero): \(green)")
        expect(hero > 64 || green <= 290, "all green with hero \(hero) is at most 290, got \(green)")
        let top = PanelLayout.height(hasBattery: true, problems: 3, hero: hero)
        expect(top == expected(items: 6, problems: 3, hero: hero), "three problem rows with hero \(hero): \(top)")
    }
    expect(PanelLayout.height(hasBattery: true, problems: 0, hero: 64) == 264, "all green with a 64 pt hero is 264 pt")
    expect(PanelLayout.height(hasBattery: true, problems: 3, hero: 64) == 436, "three problem rows with a 64 pt hero is 436 pt")
    expect(plan(Array(all.prefix(4))).height == plan(Array(all.prefix(3))).height, "the fourth problem does not add height")
    // The preview matrix (scripts/ci_acceptance.py, gate M3 and W24): the problem rows of each preview case and the height of its file.
    // The script holds the same table (PREVIEW_PROBLEMS). The heights are 264, 328 and 436 pt, so the files are 528, 656 and 872 px high.
    let previewProblems: [(PreviewCase, Int, Double)] = [(.allGreen, 0, 264), (.cpuYellow, 1, 328), (.diskRed, 1, 328), (.powerYellow, 1, 328),
                                                         (.multi, 4, 436), (.collecting, 0, 264), (.stale, 0, 264)]
    for (c, count, height) in previewProblems {
        let f = PreviewScenario.fixture(c, full: true, now: now)
        let battery = PanelRows.hasBattery(f.verdicts)
        let layout = PanelLayout.plan(PanelLayoutInput(verdicts: f.verdicts, hasBattery: battery))
        expect(battery, "preview \(c.rawValue) has a battery row")
        expect(layout.anomalies.count == count, "preview \(c.rawValue) has \(count) problems, got \(layout.anomalies.count)")
        expect(layout.height == height, "preview \(c.rawValue) is \(height) pt high, got \(layout.height)")
        let empty = PreviewScenario.fixture(c, full: false, now: now)
        expect(PanelLayout.plan(PanelLayoutInput(verdicts: empty.verdicts, hasBattery: battery)).height == height, "preview \(c.rawValue) empty data has the same height")
    }
    expect(PanelMetrics.width == 352 && PanelMetrics.widthWithSidebar == 672, "widths 352 and 672")
    expect(PanelMetrics.problemRow == 64 && PanelMetrics.quietRow == 28 && PanelMetrics.recordRow == 28 && PanelMetrics.footer == 32, "row heights")
    expect(PanelMetrics.primaryButtonWidth + PanelMetrics.footerGap + PanelMetrics.moreButtonWidth == PanelMetrics.rowBackgroundWidth,
           "footer line adds up to 336")

    section("PanelLayout v2: row order")
    let quiet = plan([])
    expect(quiet.quiet && quiet.rows == SidebarItem.fixedRows, "quiet: fixed order")
    expect(quiet.sections == [.hero, .rows, .anomaly, .footer], "four sections in order")
    let mixed = plan([(.thermal, .yellow), (.disk, .red)])
    expect(mixed.rows.prefix(2) == [.disk, .thermal], "red problem before yellow problem, got \(mixed.rows)")
    expect(Array(mixed.rows.dropFirst(2)) == [.cpu, .memory, .network, .battery], "normal rows keep the fixed order, got \(mixed.rows)")
    let four = plan(Array(all.prefix(4)))
    expect(four.anomalies.count == 4 && four.problemRowCount == 3, "4 anomalies: all listed, 3 expanded rows")
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
    expect(st.dot == .stale && st.valuePrefix == nil && st.note == "停在 11:00", "stale cpu row has the clock time in the note, got \(String(describing: st.valuePrefix)) \(st.note)")
    let stm = PanelRows.row(.memory, PanelRowsInput(verdicts: verdicts([]), current: c, dataState: .stale(now.addingTimeInterval(-3600)),
                                                    now: now, timeZone: TimeZone(identifier: "UTC")!))
    expect(stm.valuePrefix == "11:00", "stale memory row carries the clock time, got \(String(describing: stm.valuePrefix))")

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

    section("PanelRows: problem notes (DESIGN_V3.md 5.1)")
    let worstLasting = [200.0, 26 * 60.0, 47 * 60.0 + 59]   // minutes: 3 h 20 min, 1 day 2 h, 1 day 23 h 59 min
    func note(_ item: SidebarItem, _ health: HealthItem, _ level: HealthLevel, _ code: String, _ cur: CurrentReadings,
              minutes: Double = 180, growth: [String: DiskGrowth] = [:], apps: [AppUsage] = []) -> PanelRowState {
        PanelRows.row(item, PanelRowsInput(verdicts: [lv(health, level, code: code, since: minutes)], current: cur, dataState: .fresh,
                                           diskGrowth: growth, topApps: apps, now: now, timeZone: utc))
    }
    let nd = note(.disk, .disk, .red, "growth_5d", c, growth: growth)
    expect(nd.problemNote == "5 天胖了 314 GB，已持续 3 小时", "disk note: \(String(describing: nd.problemNote))")
    var pressure = c
    pressure.memoryPressurePercent = 87
    let nm = note(.memory, .memory, .red, "pressure_critical", pressure, minutes: 25)
    expect(nm.problemNote == "喘不过气，已持续 25 分" && nm.value == "87%", "memory note: \(String(describing: nm.problemNote))")
    expect(nm.quietValue == "87%", "the quiet value of memory has no prefix word")
    expect(note(.memory, .memory, .red, "pressure_critical", pressure, minutes: 0.2).problemNote == "喘不过气，刚刚开始", "a new problem says it just started")
    expect(note(.disk, .disk, .red, "low_space", c).problemNote == "快满了，可用空间不足，已持续 3 小时", "low space note")
    let nb = note(.battery, .power, .yellow, "awake_drain", drain)
    expect(nb.problemNote == "掉电太快，每小时 34%，已持续 3 小时", "battery note: \(String(describing: nb.problemNote))")
    let ns = note(.battery, .power, .yellow, "sleep_drain", drain)
    expect(ns.problemNote == "掉电太快，睡眠每小时 3.3%，已持续 3 小时", "battery sleep note: \(String(describing: ns.problemNote))")
    let nc = note(.cpu, .cpu, .yellow, "cpu_mean_10m", c)
    expect(nc.problemNote == "跑太久，10 分钟均值 94%，已持续 3 小时", "cpu note: \(String(describing: nc.problemNote))")
    let nt = note(.thermal, .thermal, .yellow, "thermal_fair", c)
    expect(nt.problemNote == "发烫，CPU 51 \u{00B0}C，已持续 3 小时", "thermal note: \(String(describing: nt.problemNote))")
    let heavy = [AppUsage(key: "x", name: "Final Cut Pro Long Name", bundleID: nil, cpuPercent: 230, memoryBytes: 1, memoryBasis: "footprint",
                          processCount: 1, isSystem: false, diskWrittenBytes: nil)]
    func appNote(_ minutes: Double) -> PanelRowState {
        let v = ItemVerdict(item: .cpu, level: .yellow, reasonCode: "app_saturated", headline: "Final Cut Pro Long Name 占满一个核",
                            since: now.addingTimeInterval(-minutes * 60), levelChangedAt: nil, alert: nil)
        return PanelRows.row(.cpu, PanelRowsInput(verdicts: [v], current: c, dataState: .fresh, topApps: heavy, now: now, timeZone: utc))
    }
    let na = appNote(180)
    expect(na.problemNote == "Final Cut Pr\u{2026} 跑太久 230%，已持续 3 小时", "app note cuts a long name: \(String(describing: na.problemNote))")
    expect(PanelRows.row(.cpu, input).problemNote == nil, "a healthy row has no problem note")
    // Every note fits 24 width units, also at the longest duration and the longest numbers.
    var worst = c
    worst.memoryPressurePercent = 100; worst.awakeDrainPerHour = 100; worst.cpuMean10m = 100
    worst.lastSleep = SleepRecord(sleptAt: now.addingTimeInterval(-3 * 3600), wokeAt: now, batteryBefore: 100, batteryAfter: 70, onBatteryBeforeSleep: true)
    let big = ["30d": DiskGrowth(window: "30d", bytes: 1_200_000_000_000, netBytes: nil, fromMinAt: nil, coveredHours: 720, status: .ok)]
    for minutes in worstLasting {
        var notes = [String]()
        notes.append(note(.disk, .disk, .red, "growth_30d", worst, minutes: minutes, growth: big).problemNote ?? "")
        notes.append(note(.disk, .disk, .red, "low_space", worst, minutes: minutes).problemNote ?? "")
        notes.append(note(.memory, .memory, .red, "swap_growth", worst, minutes: minutes).problemNote ?? "")
        notes.append(note(.memory, .memory, .yellow, "pressure_warning", worst, minutes: minutes).problemNote ?? "")
        notes.append(note(.battery, .power, .yellow, "sleep_drain", worst, minutes: minutes).problemNote ?? "")
        notes.append(note(.battery, .power, .yellow, "awake_drain", worst, minutes: minutes).problemNote ?? "")
        notes.append(note(.cpu, .cpu, .yellow, "cpu_mean_10m", worst, minutes: minutes).problemNote ?? "")
        notes.append(appNote(minutes).problemNote ?? "")
        notes.append(note(.thermal, .thermal, .red, "thermal_critical", worst, minutes: minutes).problemNote ?? "")
        for text in notes {
            expect(BubbleCopy.width(text) <= BubbleCopy.maxWidth, "problem note at most 24 width units (\(BubbleCopy.width(text))): \(text)")
            expect(text.contains(where: { $0.isNumber }), "the problem note keeps a number: \(text)")
        }
    }
    let quietKeep = PanelRows.row(.disk, input)
    expect(quietKeep.quietValue == "可用 402 GB", "the quiet disk value keeps the free-space prefix, got \(quietKeep.quietValue)")
    let gray = PanelRows.row(.cpu, PanelRowsInput(verdicts: [lv(.cpu, .yellow, code: "cpu_mean_10m")], current: c, dataState: .stale(now.addingTimeInterval(-3600)), now: now))
    expect(gray.problemNote == nil, "a stale row has no problem note")

    section("PanelFooter and PanelArea")
    let f0 = PanelFooterState.make(dataState: .fresh, anomalyCount: 0)
    expect(f0.mode == .inspect && f0.title == "复制日常巡检提示词" && f0.enabled && !f0.hidden, "quiet footer")
    let f1 = PanelFooterState.make(dataState: .fresh, anomalyCount: 2)
    expect(f1.mode == .copyProblems && f1.title == "复制排查提示词" && !f1.hidden, "problem footer: no subtitle")
    expect(f1.copiedTitle == "已复制" && f1.copiedBubble == "已复制，去问你的 Agent 吧", "copied texts")
    expect(!PanelFooterState.make(dataState: .collecting, anomalyCount: 0).enabled && PanelFooterState.make(dataState: .collecting, anomalyCount: 0).hidden, "collecting footer is hidden")
    expect(PanelFooterState.make(dataState: .stale(now), anomalyCount: 1).mode == .copyProblems, "stale footer follows the problems")
    expect(PanelAreaState.make(dataState: .fresh, anomalyCount: 0, records: 3, now: now) == .quiet(records: 3), "quiet area")
    expect(PanelAreaState.recordsText(0) == "近 7 天无记录" && PanelAreaState.recordsText(3) == "近 7 天 3 条记录", "records text")
    expect(PanelAreaState.make(dataState: .fresh, anomalyCount: 1, records: 6, now: now) == .anomalies(records: 6), "anomaly area keeps the record count")

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
    let sentence = SidebarSummary.sentence(.cpu, range: .d7, stats: stats)
    expect(sentence == "7 天均值 20%，峰值 40%", "cpu sentence leaves out the missing current value, got \(sentence)")
    expect(SidebarSummary.sentence(.cpu, range: .h2, stats: [SidebarStat(label: "当前", value: "74%"), SidebarStat(label: "均值", value: "56%"),
                                                           SidebarStat(label: "峰值", value: "81%")]) == "当前 74%，2 小时均值 56%，峰值 81%", "design example sentence")
    expect(SidebarSummary.sentence(.memory, range: .h2, stats: [SidebarStat(label: "压力", value: "87%"), SidebarStat(label: "swap", value: "9.8 GB"),
                                                              SidebarStat(label: "30 分钟变化", value: "+2.4 GB")]).contains("swap 9.8 GB"), "swap is in the memory sentence")
    expect(!SidebarSummary.sentence(.network, range: .h2, stats: [SidebarStat(label: "今天", value: "1 GB")]).contains("\u{00B7}"), "no middle dot in the sentence")
    expect(c2.axisMarks.map { $0.text } == ["0", "70", "90"] && c2.axisMarks.filter { $0.threshold }.count == 2, "cpu marks: zero line and thresholds")
    expect(c2.liveEnd?.t == now && c7.liveEnd == nil, "live dot on fresh 2 h data only")
    let ev = EventRecord(item: .cpu, first: .yellow, peak: .yellow, reasonCode: "cpu_mean_10m", start: now.addingTimeInterval(-1800),
                         end: nil, peakValue: 80, unit: "%", app: nil, endEstimated: false)
    var input2 = input
    input2.range = .h2
    let banded = SidebarChart.make(input2, events: [ev, ev])
    expect(banded.bands.count == 1 && banded.bands[0].kind == .warning && banded.bands[0].to == now, "an ongoing yellow record is one warning band to now")
    expect(SidebarChart.make(input2).bands.isEmpty, "no records, no bands")

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
    expect(th.style == .step && th.domain == 0...3 && th.lines.count == 1, "thermal step, one chart one line")
    expect(th.axisMarks.count == 4 && th.axisMarks.allSatisfy { !$0.threshold }, "thermal marks are the four level words")
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
    expect(groups[0].rows[0].span.hasSuffix(" 起，进行中") && groups[0].rows[0].ongoing, "ongoing record, got \(groups[0].rows[0].span)")
    expect(!groups[1].rows[0].evidence.contains("\u{00B7}"), "no middle dot in the evidence")
    let strip = RecordStrip.segments(groups.flatMap { $0.rows }, days: 7, now: now)
    expect(strip.count == 2 && strip.last?.level == .red && strip.last?.to == 1, "strip: red last and the ongoing record reaches today")
    expect(strip.allSatisfy { $0.to - $0.from >= 0.008 - 1e-9 }, "short records stay visible on the strip")
    expect(groups[1].rows[0].duration.hasPrefix("约 ") && groups[1].rows[0].evidence.contains("Xcode"), "estimated end and app name")
    expect(SidebarRecords.dayTitle(20000, today: 20010).contains("月") && SidebarRecords.dayTitle(20000, today: 20010).contains("周"), "older day title")
    let rstats = SidebarStats.make(SidebarInput(item: .anomalyLog, range: .d7, trend: .empty, rollups: [], diskSeries: [], diskTrigger: nil, sleeps: [],
                                                current: CurrentReadings(), verdicts: [], status: nil, now: now, timeZone: utc), events: [e1, e2])
    expect(rstats[0].value == "2" && rstats[1].value == "1 小时 0 分" || rstats[1].value.contains("小时"), "record stats \(rstats)")
}
