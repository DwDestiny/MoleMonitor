// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for BubbleCopy (docs/DESIGN_V2.md 4.10, 4.11, gate W13).
// Pos: Called from main.swift via runBubbleCopyTests(); no top-level code in this file.

import Foundation

func runBubbleCopyTests() {
    section("BubbleCopyTests")
    expect(BubbleCopy.width("一切正常，我先趴会儿") == 10, "width: 10 full-width characters")
    expect(BubbleCopy.width("CPU 100%，我跟着小跑") == 10, "width: half-width counts 0.5 (4.11 table: 10.0)")

    // W13: every template at its worst value fits 24 width units and 2 lines; a problem template holds a digit.
    let all = BubbleCopy.allTemplates
    expect(all.count >= 37, "all 4.11 templates are listed (\(all.count))")
    for (name, text, problem) in all {
        let w = BubbleCopy.width(text.main)
        expect(w <= BubbleCopy.maxWidth, "\(name): \(w) width units, at most 24: \(text.main)")
        expect(!text.main.contains("您"), "\(name): no 您")
        if problem {
            expect(text.main.contains { $0.isNumber }, "\(name): a problem text has a digit: \(text.main)")
            if let e = text.emphasis { expect(text.main.contains(e) && e.contains { $0.isNumber }, "\(name): the emphasis is the evidence") }
            expect(text.level == .yellow || text.level == .red, "\(name): the emphasis has the level color")
        }
    }

    // Line break: a long text breaks once at the comma (or after "一直占着"), so the system never splits a word.
    for (name, text, _) in all {
        let lines = text.wrapped.components(separatedBy: "\n")
        expect(lines.count <= 2, "\(name): at most 2 lines, got \(lines.count)")
        expect(text.wrapped.replacingOccurrences(of: "\n", with: "") == text.main || text.wrapped.replacingOccurrences(of: "\n", with: " ") == text.main,
               "\(name): the break only replaces a space or adds nothing: \(text.wrapped)")
        for line in lines { expect(BubbleCopy.em(line) <= 12.4, "\(name): line '\(line)' is \(BubbleCopy.em(line)) em, a line holds about 12.6") }
        if BubbleCopy.em(text.main) <= BubbleCopy.oneLineEm { expect(lines.count == 1, "\(name): a short text stays on one line") }
        if lines.count == 2 { expect(lines[0].hasSuffix("，") || lines[0].hasSuffix("一直占着"), "\(name): the break sits at the comma: \(lines[0])") }
    }
    expect(BubbleCopy.wrapped("磁盘 5 天胖了 314 GB，该让 Agent 看看了") == "磁盘 5 天胖了 314 GB，\n该让 Agent 看看了", "disk growth breaks at the comma")
    expect(BubbleCopy.wrapped("CPU 忙了 40 分钟，均值 74%") == "CPU 忙了 40 分钟，\n均值 74%", "CPU yellow breaks before 均值, not inside it")
    expect(BubbleCopy.wrapped("一切正常，我先趴会儿") == "一切正常，我先趴会儿", "a short text is not broken")
    expect(BubbleCopy.wrapped("Orchard Browser 一直占着 412% CPU") == "Orchard Browser 一直占着\n412% CPU", "a text without comma breaks after 一直占着")

    // Examples of 4.11, exactly.
    func one(_ item: HealthItem, _ level: HealthLevel, _ code: String, number: Double? = nil, app: String? = nil,
             bytes: Int64? = nil, seconds: Double? = nil) -> String {
        BubbleCopy.text(for: BubbleInput(problems: [BubbleProblem(item: item, level: level, reasonCode: code, number: number,
                                                                  app: app, bytes: bytes, seconds: seconds)])).main
    }
    expect(one(.disk, .red, "growth_5d", bytes: 314 * GB) == "磁盘 5 天胖了 314 GB，该让 Agent 看看了", "disk growth example")
    expect(one(.disk, .red, "low_space", bytes: 18 * GB) == "磁盘只剩 18 GB，快装不下了", "disk red example")
    expect(one(.disk, .yellow, "low_space", bytes: 46 * GB) == "磁盘只剩 46 GB，开始挤了", "disk yellow example")
    expect(one(.memory, .red, "pressure_critical", number: 87) == "内存压力 87%，我快背不动了", "memory red example")
    expect(one(.memory, .yellow, "pressure_warning", number: 64) == "内存压力 64%，有点挤了", "memory yellow example")
    expect(one(.memory, .red, "pressure_critical", bytes: 9_800_000_000) == "内存严重不足，swap 已到 9.8 GB", "memory red fallback")
    expect(one(.memory, .yellow, "pressure_warning", bytes: 6_200_000_000) == "内存有点挤，swap 已到 6.2 GB", "memory yellow fallback")
    expect(one(.memory, .yellow, "swap_growth", bytes: 3_100_000_000) == "swap 半小时涨了 3.1 GB，有点沉", "swap growth example")
    expect(one(.cpu, .red, "cpu_mean_10m", number: 97, seconds: 18 * 60) == "CPU 满负荷 18 分钟了，我快跑不动了", "CPU red example")
    expect(one(.cpu, .yellow, "cpu_mean_5m", number: 74, seconds: 40 * 60) == "CPU 忙了 40 分钟，均值 74%", "CPU yellow example")
    expect(one(.cpu, .yellow, "app_saturated", number: 412, app: "Xcode") == "Xcode 一直占着 412% CPU", "app example")
    expect(one(.cpu, .yellow, "app_saturated", number: 412, app: "Google Chrome Helper") == "有个 App 一直占着 412% CPU", "long app name")
    expect(one(.cpu, .yellow, "app_saturated", number: 412, app: nil) == "有个 App 一直占着 412% CPU", "app names off")
    expect(one(.thermal, .red, "thermal_serious", seconds: 12 * 60) == "热到降速了，已持续 12 分钟", "thermal red example")
    expect(one(.thermal, .yellow, "thermal_fair", seconds: 8 * 60) == "有点热，已经 8 分钟了", "thermal yellow example")
    expect(one(.power, .yellow, "sleep_drain", number: 3.3) == "合盖时每小时掉电 3.3%，偏快", "sleep drain example")
    expect(one(.power, .yellow, "awake_drain", number: 18) == "1 小时掉了 18% 电，有点快", "awake drain example")
    expect(BubbleCopy.duration(3 * 3600 + 5) == "3 小时" && BubbleCopy.duration(3 * 86400) == "3 天", "{D} hours and days")
    expect(BubbleCopy.size(1_300_000_000_000) == "1.3 TB" && BubbleCopy.size(512_000_000) == "512 MB", "{X} units")

    // Quiet texts follow the gait on screen; night texts (4.9).
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 3)).main == "一切正常，我先趴会儿", "idle")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 25)).main == "电脑在干活，我陪着溜达", "walk")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 52)).main == "CPU 52%，我跟着小跑", "trot example")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 91)).main == "CPU 冲到 91%，全力奔跑中", "sprint example")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 42, gait: .walk)).main == "电脑在干活，我陪着溜达", "the gait on screen wins over the raw CPU")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 5, isNight: true)).main == "夜深了，一切正常，晚安", "night sleep")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 48, isNight: true)).main == "这么晚还在忙，CPU 48%", "night busy example")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let staleAt = cal.date(bySettingHour: 13, minute: 20, second: 0, of: now)!
    expect(BubbleCopy.text(for: BubbleInput(dataState: .stale(staleAt), calendar: cal)).main == "数据停在 13:20，我有点懵", "stale example")
    expect(BubbleCopy.text(for: BubbleInput(dataState: .collecting)).main == "我先闻闻看，30 秒后告诉你", "collecting")

    // Eggs and problems (4.8 rule 2), copy feedback (4.11), second line (4.10 rule 4).
    let p = BubbleProblem(item: .disk, level: .red, reasonCode: "low_space", number: nil, app: nil, bytes: 18 * GB)
    let q = BubbleProblem(item: .memory, level: .yellow, reasonCode: "pressure_warning", number: 64, app: nil)
    let two = BubbleCopy.text(for: BubbleInput(problems: [p, q]))
    expect(two.main.contains("18") && two.main == "磁盘只剩 18 GB，快装不下了", "the first problem leads, the count lives only in the footer")
    expect(two.emphasis == "18 GB" && two.level == .red, "the evidence is emphasized in the level color")
    expect(BubbleCopy.text(for: BubbleInput(problems: [p], event: .petTap(0))).main == "磁盘只剩 18 GB，快装不下了", "no egg text during a problem")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 3, event: .petTap(5))).main == BubbleCopy.tapTexts[1], "tap texts rotate")
    expect(BubbleCopy.text(for: BubbleInput(problems: [p], event: .copySucceeded(inspection: false))).main == "已复制，去问你的 Agent 吧", "copy feedback shows during a problem")
    expect(BubbleCopy.text(for: BubbleInput(event: .copySucceeded(inspection: true))).main == "巡检单已复制，交给 Agent 吧", "inspection copy")
    expect(BubbleCopy.text(for: BubbleInput(event: .petCount(10))).main == "今天第 10 次摸我啦", "count text")
}
