// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for BubbleCopy (docs/DESIGN_V3.md 4.1, DESIGN_V2.md 4.11, gate W13): width units, the line budget of the
//         17 pt headline in a 320 pt content width, the examples of 4.11 and the quiet, stale and collecting texts.
// Pos: Called from main.swift via runBubbleCopyTests(); no top-level code in this file.

import Foundation

func runBubbleCopyTests() {
    section("BubbleCopyTests")
    expect(BubbleCopy.width("一切正常，电脑在干活") == 10, "width: 10 full-width characters")
    expect(BubbleCopy.width("CPU 100%，电脑在干活") == 10, "width: half-width counts 0.5 (4.11 table: 10.0)")

    // W13: every template at its worst value fits 24 width units and 2 lines; a problem template holds a digit.
    let all = BubbleCopy.allTemplates
    expect(all.count >= 22, "all 4.11 templates are listed (\(all.count))")
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

    // Line budget: 17 pt type in a 320 pt content width holds 18.8 em. A text up to lineEm stays on one line. A longer text breaks once
    // at the comma (or after "一直占着"), so the system never splits a word. No line passes maxLineEm. At most 2 lines.
    expect(BubbleCopy.lineEm <= 320.0 / 17.0 && BubbleCopy.maxLineEm <= 320.0 / 17.0, "the budget is below the 18.8 em of a 320 pt line at 17 pt")
    for (name, text, _) in all {
        let lines = text.wrapped.components(separatedBy: "\n")
        expect(lines.count <= 2, "\(name): at most 2 lines, got \(lines.count)")
        expect(text.wrapped.replacingOccurrences(of: "\n", with: "") == text.main || text.wrapped.replacingOccurrences(of: "\n", with: " ") == text.main,
               "\(name): the break only replaces a space or adds nothing: \(text.wrapped)")
        for line in lines { expect(BubbleCopy.em(line) <= BubbleCopy.maxLineEm, "\(name): line '\(line)' is \(BubbleCopy.em(line)) em, a line holds \(BubbleCopy.maxLineEm)") }
        if BubbleCopy.em(text.main) <= BubbleCopy.oneLineEm { expect(lines.count == 1, "\(name): a short text stays on one line") }
        if lines.count == 2 { expect(lines[0].hasSuffix("，") || lines[0].hasSuffix("一直占着"), "\(name): the break sits at the comma: \(lines[0])") }
    }
    expect(BubbleCopy.wrapped("磁盘 5 天胖了 314 GB，该让 Agent 看看了") == "磁盘 5 天胖了 314 GB，\n该让 Agent 看看了", "disk growth breaks at the comma")
    expect(BubbleCopy.wrapped("CPU 忙了 40 分钟，均值 74%") == "CPU 忙了 40 分钟，均值 74%", "CPU yellow fits one line at 17 pt")
    expect(BubbleCopy.wrapped("一切正常，电脑在干活") == "一切正常，电脑在干活", "a short text is not broken")
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

    // Quiet texts follow the CPU band (10, 40, 80). No dog voice.
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 3)).main == "一切正常", "idle")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: nil)).main == "一切正常", "no CPU reading")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 25)).main == "一切正常，电脑在干活", "busy band")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 52)).main == "一切正常，CPU 52%", "high band example")
    expect(BubbleCopy.text(for: BubbleInput(cpuPercent: 91)).main == "一切正常，CPU 冲到 91%", "top band example")
    for (name, text, _) in all { expect(!text.main.contains("您") && !text.main.contains("汪"), "\(name): no 您, no dog sound") }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let staleAt = cal.date(bySettingHour: 13, minute: 20, second: 0, of: now)!
    expect(BubbleCopy.text(for: BubbleInput(dataState: .stale(staleAt), calendar: cal), now: staleAt.addingTimeInterval(25 * 60)).main == "数据已经 25 分钟没更新", "stale example")
    expect(BubbleCopy.subline(for: BubbleInput(dataState: .stale(staleAt), calendar: cal), headline: BubbleText(main: "x"), sampledAt: nil, now: staleAt.addingTimeInterval(25 * 60)) == "最后一次读数在 13:20", "stale subline names the clock")
    expect(BubbleCopy.subline(for: BubbleInput(dataState: .collecting), headline: BubbleText(main: "x"), sampledAt: nil, now: staleAt) == nil, "collecting has no subline")
    expect(BubbleCopy.text(for: BubbleInput(dataState: .collecting, collected: 0)).main == "正在检查，已完成 0/6 项", "collecting, nothing yet")
    expect(BubbleCopy.text(for: BubbleInput(dataState: .collecting, collected: 4)).main == "正在检查，已完成 4/6 项", "collecting example")
    expect(BubbleCopy.collectingText(done: 9) == "正在检查，已完成 6/6 项" && BubbleCopy.collectingText(done: -1) == "正在检查，已完成 0/6 项", "the count stays inside 0 to 6")

    // The first problem leads. The count of problems lives only in the footer.
    let p = BubbleProblem(item: .disk, level: .red, reasonCode: "low_space", number: nil, app: nil, bytes: 18 * GB)
    let q = BubbleProblem(item: .memory, level: .yellow, reasonCode: "pressure_warning", number: 64, app: nil)
    let two = BubbleCopy.text(for: BubbleInput(problems: [p, q]))
    expect(two.main.contains("18") && two.main == "磁盘只剩 18 GB，快装不下了", "the first problem leads")
    expect(two.emphasis == "18 GB" && two.level == .red, "the evidence is still marked for the rows")
}
