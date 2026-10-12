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
    for (count, laptop) in [(0, 524.0), (1, 560.0), (2, 604.0), (3, 648.0), (4, 648.0), (5, 648.0)] {
        let p = plan(Array(all.prefix(count)))
        expect(p.height == laptop, "laptop \(count) anomalies: \(laptop), got \(p.height)")
        expect(p.rows.count == 6, "laptop has 6 rows")
    }
    let desktopAll: [(HealthItem, HealthLevel)] = [(.disk, .red), (.memory, .red), (.cpu, .yellow), (.thermal, .yellow)]
    for (count, desktop) in [(0, 484.0), (1, 520.0), (2, 564.0), (3, 608.0), (4, 608.0)] {
        let p = plan(Array(desktopAll.prefix(count)), battery: false)
        expect(p.height == desktop, "desktop \(count) anomalies: \(desktop), got \(p.height)")
        expect(p.rows.count == 5 && !p.rows.contains(.battery), "desktop has 5 rows, no battery")
    }
    expect(PanelMetrics.width == 352 && PanelMetrics.widthWithSidebar == 672, "widths 352 and 672")
    expect(PanelMetrics.dotColumn + PanelMetrics.dotGap + PanelMetrics.textColumn + PanelMetrics.valueColumn
           + PanelMetrics.sparkGap + PanelMetrics.sparkWidth == PanelMetrics.contentWidth, "row columns add up to 320")

    section("PanelLayout v2: row order and overflow")
    let quiet = plan([])
    expect(quiet.quiet && quiet.rows == SidebarItem.fixedRows, "quiet: fixed order")
    expect(quiet.sections == [.hero, .rows, .anomaly, .footer], "four sections in order")
    let mixed = plan([(.thermal, .yellow), (.disk, .red)])
    expect(mixed.rows.prefix(2) == [.disk, .thermal], "red problem before yellow problem, got \(mixed.rows)")
    expect(Array(mixed.rows.dropFirst(2)) == [.cpu, .memory, .network, .battery], "normal rows keep the fixed order, got \(mixed.rows)")
    let four = plan(Array(all.prefix(4)))
    expect(four.anomalyRowCount == 3 && four.overflowCount == 2 && four.shownAnomalies.count == 2, "4 anomalies: overflow 2")
    let five = plan(all)
    expect(five.overflowCount == 3 && five.anomalies.count == 5, "5 anomalies: overflow 3")
    expect(plan(Array(all.prefix(3))).overflowCount == 0, "3 anomalies: no overflow")
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
    expect(rows[3].dot == .neutralHollow, "network always a hollow neutral dot")
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
    let bars = PanelAnomalies.bars(shown: [.disk, .memory],
                                   verdicts: [lv(.disk, .red, code: "growth_5d", since: 192), lv(.memory, .yellow, code: "pressure_warning", since: 20)],
                                   now: now, timeZone: utc)
    expect(bars.count == 2 && bars[0].title == "磁盘 · 异常" && bars[1].title == "内存 · 留意", "bar titles: \(bars.map { $0.title })")
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
    expect(f0.mode == .inspect && f0.title == "让 Agent 做一次日常巡检" && f0.enabled, "quiet footer")
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
}
