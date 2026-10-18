// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for HeroFacts, HeroProgress and HeroBrain (docs/DESIGN_V3.md 4.1): evidence numbers, the 30 s number rule,
//         the collecting count and the quiet texts.
// Pos: Called from main.swift via runHeroLogicTests(); no top-level code in this file.

import Foundation

func runHeroLogicTests() {
    section("HeroLogicTests")
    func v(_ item: HealthItem, _ level: HealthLevel, _ code: String, _ headline: String = "", since: Date? = nil) -> ItemVerdict {
        ItemVerdict(item: item, level: level, reasonCode: code, headline: headline, since: since, levelChangedAt: nil, alert: nil)
    }
    let greens = HealthItem.allCases.map { v($0, .green, "ok") }
    func facts(_ verdicts: [ItemVerdict], cpu: Double? = 5, at: Date = now, state: DataState = .fresh, battery: Double? = 80,
               configure: (inout CurrentReadings) -> Void = { _ in }) -> HeroFacts {
        var c = CurrentReadings()
        c.cpuPercent = cpu
        c.batteryPercent = battery
        configure(&c)
        var all = greens.filter { g in !verdicts.contains { $0.item == g.item } }
        all += verdicts
        return HeroFacts.make(verdicts: all, current: c, apps: [], status: nil, dataState: state, now: at,
                              includeAppNames: true)
    }

    // Evidence numbers
    let disk = facts([v(.disk, .red, "low_space")]) { $0.diskAvailable = 12 * GB }
    expect(disk.bubble.problems.first?.bytes == 12 * GB, "low space: the free bytes are the evidence")
    expect(BubbleCopy.text(for: disk.bubble).main == "磁盘只剩 12 GB，快装不下了", "disk red text with the free space")
    let mem = facts([v(.memory, .yellow, "pressure_warning")]) { $0.memoryPressurePercent = 82 }
    expect(BubbleCopy.text(for: mem.bubble).main == "内存压力 82%，有点挤了", "memory yellow text with the pressure percent")
    let sleep = facts([v(.power, .red, "sleep_drain", "睡眠掉电 4.2%/小时")])
    expect(sleep.bubble.problems.first?.number == 4.2, "sleep drain: the rate comes from the headline")
    expect(HeroFacts.firstNumber("CPU 5 分钟均值 87%") == 5 && HeroFacts.firstNumber("无") == nil, "first number of a text")
    let hot = facts([v(.thermal, .yellow, "thermal_fair", since: now.addingTimeInterval(-600))])
    expect(hot.bubble.problems.first?.seconds == 600, "the duration comes from since")
    expect(!facts([]).hasProblem && hot.hasProblem, "hasProblem follows the problem items")

    // Texts and the 30 s number rule
    var brain = HeroBrain(facts: facts([], cpu: 5))
    expect(brain.text.main == "一切正常", "quiet start: the plain text")
    brain.update(facts([], cpu: 25, at: now.addingTimeInterval(10)))
    expect(brain.text.main == "一切正常，电脑在干活", "a change of CPU band changes the text at once")
    brain.update(facts([], cpu: 60, at: now.addingTimeInterval(20)))
    let busyText = brain.text.main
    expect(busyText == "一切正常，CPU 60%", "busy text with the CPU")
    brain.update(facts([], cpu: 70, at: now.addingTimeInterval(30)))
    expect(brain.text.main == busyText, "a number alone does not change the text inside 30 s")
    brain.update(facts([], cpu: 70, at: now.addingTimeInterval(52)))
    expect(brain.text.main == "一切正常，CPU 70%", "after 30 s the number updates")

    // A new problem replaces the quiet text at once
    var b2 = HeroBrain(facts: facts([], cpu: 25))
    b2.update(facts([v(.disk, .yellow, "low_space")], cpu: 25, at: now.addingTimeInterval(30)) { $0.diskAvailable = 40 * GB })
    expect(b2.text.main.contains("40 GB"), "the problem text replaces the quiet text at once")

    // Collecting count: the 6 readings of the rows
    expect(HeroProgress.done(CurrentReadings()) == 0, "nothing arrived: 0 of 6")
    var cr = CurrentReadings()
    cr.cpuPercent = 0
    expect(HeroProgress.done(cr) == 1, "a measured zero counts as arrived")
    cr.memoryPressurePercent = 40
    cr.diskAvailable = 100 * GB
    cr.rx = 0
    cr.batteryPercent = 80
    cr.thermal = .nominal
    expect(HeroProgress.done(cr) == 6, "all 6 readings arrived")
    cr.batteryPercent = nil
    cr.powerSource = .ac
    expect(HeroProgress.done(cr) == 6, "a Mac without battery still reports its power source")
    let col = facts([], cpu: 3, state: .collecting, battery: nil) { $0.memoryPressurePercent = 40 }
    expect(col.bubble.collected == 2, "collecting facts carry the count (CPU and memory)")
    var cb = HeroBrain(facts: col)
    expect(cb.text.main == "正在检查，已完成 2/6 项", "collecting title with the count")
    cb.update(facts([], cpu: 3, at: now.addingTimeInterval(1), state: .collecting, battery: nil) { $0.memoryPressurePercent = 40; $0.rx = 1 })
    expect(cb.text.main == "正在检查，已完成 3/6 项", "the count updates at once")
    expect(HeroBrain.collectingDelay == 0.5, "the collecting title waits 0.5 s")
}
