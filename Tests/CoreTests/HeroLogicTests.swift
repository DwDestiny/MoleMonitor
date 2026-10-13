// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for HeroFacts and HeroBrain (docs/DESIGN_V2.md 4.4, 4.8, 4.10, 4.11): evidence numbers, the 30 s number rule,
//         one-shot permission, taps, long press, copy texts and the easter eggs at open.
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
                              includeAppNames: true, night: false)
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
    expect(facts([], battery: nil).hasBattery == false && facts([]).hasBattery, "battery from the battery percent")

    // Director and texts
    var brain = HeroBrain(facts: facts([], cpu: 5))
    expect(brain.plan.action == .lieIdle && brain.text.main == "一切正常，我先趴会儿", "quiet start: lie and the quiet text")
    _ = brain.update(facts([], cpu: 25, at: now.addingTimeInterval(10)), reduceMotion: false)
    expect(brain.plan.action == .walk && brain.text.main == "电脑在干活，我陪着溜达", "the gait text follows the gait at once")
    _ = brain.update(facts([], cpu: 60, at: now.addingTimeInterval(20)), reduceMotion: false)
    let trotText = brain.text.main
    expect(brain.plan.action == .trot && trotText.hasPrefix("CPU "), "trot text with the CPU")
    _ = brain.update(facts([], cpu: 70, at: now.addingTimeInterval(30)), reduceMotion: false)
    expect(brain.text.main == trotText, "a number alone does not change the text inside 30 s")
    _ = brain.update(facts([], cpu: 70, at: now.addingTimeInterval(52)), reduceMotion: false)
    expect(brain.text.main != trotText, "after 30 s the number updates")

    // A new problem: notice and a pop; with Reduce Motion no one-shot
    var b2 = HeroBrain(facts: facts([], cpu: 25))
    let e1 = b2.update(facts([v(.disk, .yellow, "low_space")], cpu: 25, at: now.addingTimeInterval(30)) { $0.diskAvailable = 40 * GB },
                       reduceMotion: false)
    expect(e1.oneShot == .notice && e1.pop, "a new problem plays notice and pops the bubble")
    expect(b2.text.main.contains("40 GB"), "the problem text replaces the quiet text at once")
    var b3 = HeroBrain(facts: facts([], cpu: 25))
    let e2 = b3.update(facts([v(.disk, .yellow, "low_space")], cpu: 25, at: now.addingTimeInterval(30)), reduceMotion: true)
    expect(e2.oneShot == nil && e2.pop, "Reduce Motion: no one-shot, the text still changes")
    var b4 = HeroBrain(facts: facts([], cpu: 25))
    let e3 = b4.update(facts([v(.thermal, .red, "thermal_critical")], cpu: 25, at: now.addingTimeInterval(30)), reduceMotion: false)
    expect(e3.oneShot == nil && b4.plan.action == .pantLie, "thermal red: pant_lie wins over notice (4.4 priority)")

    // Taps (4.8)
    var memory = HeroMemory()
    var pet = HeroBrain(facts: facts([], cpu: 5))
    let day = Calendar.current.startOfDay(for: now)
    let t1 = pet.tap(at: 0, day: day, reduceMotion: false, memory: &memory)
    expect(t1.oneShot == .wag && t1.repeats == 2 && t1.hearts == 3 && t1.pop, "tap: wag twice and 3 hearts")
    expect(pet.text.main == BubbleCopy.tapTexts[0], "tap: the first tap text")
    _ = pet.tap(at: 0.5, day: day, reduceMotion: false, memory: &memory)
    expect(pet.text.main == BubbleCopy.tapTexts[1], "the tap texts rotate")
    _ = pet.tap(at: 1.0, day: day, reduceMotion: false, memory: &memory)
    _ = pet.tap(at: 1.5, day: day, reduceMotion: false, memory: &memory)
    let t5 = pet.tap(at: 2.0, day: day, reduceMotion: false, memory: &memory)
    expect(t5.oneShot == .notice && t5.hearts == 0 && pet.text.main == "别摸啦，我在站岗", "5 taps in 3 s: notice and 别摸啦")
    pet.endEvent()
    expect(pet.text.main == "一切正常，我先趴会儿", "the event text ends")
    for i in 0..<4 { _ = pet.tap(at: 10 + Double(i) * 4, day: day, reduceMotion: false, memory: &memory) }
    let t10 = pet.tap(at: 40, day: day, reduceMotion: false, memory: &memory)
    expect(memory.tapsToday == 10 && pet.text.main == "今天第 10 次摸我啦" && t10.oneShot == .wag, "the 10th tap of the day shows the count")
    let lp = pet.longPress(day: day, reduceMotion: false, memory: &memory)
    expect(lp.repeats == 3 && lp.hearts == 5 && pet.text.main == "嘿嘿，好舒服", "long press: wag 3 times, 5 hearts")
    let rm = pet.tap(at: 60, day: day, reduceMotion: true, memory: &memory)
    expect(rm.oneShot == nil && rm.hearts == 0, "Reduce Motion: no wag and no hearts")
    var sick = HeroBrain(facts: facts([v(.disk, .red, "low_space")]) { $0.diskAvailable = 9 * GB })
    let ts = sick.tap(at: 0, day: day, reduceMotion: false, memory: &memory)
    expect(ts.oneShot == .wag && ts.hearts == 3 && sick.text.main.hasPrefix("磁盘只剩"), "with a problem: wag and hearts, the problem text stays")

    // Copy feedback
    var cp = HeroBrain(facts: facts([], cpu: 5))
    let c1 = cp.copied("已复制，去问你的 Agent 吧", reduceMotion: false)
    expect(c1.oneShot == .wag && c1.copyStarted && cp.display.main == "已复制，去问你的 Agent 吧", "copy success: wag and the copy text")
    cp.endCopy()
    let c2 = cp.copied("没复制上，再点一次试试", reduceMotion: false)
    expect(c2.oneShot == nil && cp.display.main == "没复制上，再点一次试试", "copy failure: the text, no wag")
    expect(cp.copied(nil, reduceMotion: false) == HeroEffects(), "no copy text: nothing")

    // Eggs at open
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var m2 = HeroMemory()
    var egg = HeroBrain(facts: facts([], cpu: 5, battery: nil))
    let morning = UTCTime.parseISO("2026-10-12T07:30:00Z")!
    let o1 = egg.appeared(clock: morning, calendar: cal, lastNightClean: true, eggs: true, memory: &m2)
    expect(o1.pop && o1.eventStarted && egg.text.main == "早上好，昨晚没有异常", "first open in the morning after a clean night")
    egg.endEvent()
    let o2 = egg.appeared(clock: morning.addingTimeInterval(600), calendar: cal, lastNightClean: true, eggs: true, memory: &m2)
    expect(o2.eventStarted && egg.text.main == "这台 Mac 没有电池，我少操一份心", "second open: no morning text, the no-battery text once")
    egg.endEvent()
    let o3 = egg.appeared(clock: morning.addingTimeInterval(900), calendar: cal, lastNightClean: true, eggs: true, memory: &m2)
    expect(!o3.eventStarted, "the no-battery text shows once per process")
    let friday = UTCTime.parseISO("2026-10-16T19:00:00Z")!
    var fr = HeroBrain(facts: facts([], cpu: 5))
    var m3 = HeroMemory(lastOpenDay: cal.startOfDay(for: friday))
    _ = fr.appeared(clock: friday, calendar: cal, lastNightClean: false, eggs: true, memory: &m3)
    expect(fr.text.main == "周五了，电脑也想下班", "Friday evening, no problem, CPU below 20 %")
    fr.endEvent()
    let again = fr.appeared(clock: friday.addingTimeInterval(1800), calendar: cal, lastNightClean: false, eggs: true, memory: &m3)
    expect(!again.eventStarted, "the Friday text shows once a week")
    var off = HeroBrain(facts: facts([], cpu: 5, battery: nil))
    var m4 = HeroMemory()
    expect(!off.appeared(clock: morning, calendar: cal, lastNightClean: true, eggs: false, memory: &m4).eventStarted, "eggs off: no egg")
    var ill = HeroBrain(facts: facts([v(.cpu, .yellow, "cpu_mean_5m")], cpu: 5, battery: nil))
    var m5 = HeroMemory()
    expect(!ill.appeared(clock: morning, calendar: cal, lastNightClean: true, eggs: true, memory: &m5).eventStarted, "no egg with a problem")
}
