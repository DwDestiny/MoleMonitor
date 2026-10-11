// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the power rules (sleep drain and awake drain) (docs/DESIGN.md 9.1).
// Pos: Called from main.swift via runPowerTests(); no top-level code in this file. Owner I1.
//      Helpers gen, pt, replay, verdictAt and minutesSince come from HealthRuleTests.swift.

import Foundation

private func sleepRecord(hours: Double, drainPerHour: Double, wokeMinutesAgo: Double = 30, onBattery: Bool = true) -> SleepRecord {
    let woke = ruleBase.addingTimeInterval(-wokeMinutesAgo * 60)
    return SleepRecord(sleptAt: woke.addingTimeInterval(-hours * 3600), wokeAt: woke, batteryBefore: 90,
                       batteryAfter: 90 - drainPerHour * hours, onBatteryBeforeSleep: onBattery)
}

private func evalPower(_ points: [TrendPoint], sleeps: [SleepRecord] = [], hasBattery: Bool = true,
                       at time: Date? = nil) -> ItemVerdict? {
    var s = RuleMemory()
    return PowerHealth.evaluate(points: points, sleeps: sleeps, hasBattery: hasBattery,
                                now: time ?? points.last?.t ?? ruleBase, state: &s)
}

private func replayPower(_ pts: [TrendPoint], sleeps: [SleepRecord] = []) -> [ItemVerdict] {
    replay(pts) { p, t, s in PowerHealth.evaluate(points: p, sleeps: sleeps, hasBattery: true, now: t, state: &s) }
}

/// Battery points that fall `perHour` percent per hour from `start` percent, rounded to whole percent like the system.
private func drainPoints(_ from: Double, _ to: Double, start: Double, perHour: Double, power: PowerSource = .battery) -> [TrendPoint] {
    gen(from, to) { m in pt(m, battery: (start - perHour * (m - from) / 60).rounded(), power: power) }
}

func runPowerTests() {
    section("Power: no battery")
    expect(evalPower([pt(0, battery: 80, power: .ac)], hasBattery: false) == nil, "a Mac without a battery has no power item")

    section("Power: sleep drain")
    let basePoints = gen(0, 5) { pt($0, battery: 61, power: .battery) }
    let yellow = evalPower(basePoints, sleeps: [sleepRecord(hours: 6, drainPerHour: 3.3, wokeMinutesAgo: 130)], at: ruleBase.addingTimeInterval(5 * 60))
    expect(yellow?.level == .yellow && yellow?.reasonCode == "sleep_drain", "3.3 %/h over 6 h is yellow")
    expect(yellow?.headline == "睡眠掉电 3.3%/小时", "sleep headline: \(yellow?.headline ?? "")")
    let woke = ruleBase.addingTimeInterval(-130 * 60)
    expect(yellow?.since == woke, "the sleep problem starts at the wake time")
    let red = evalPower(basePoints, sleeps: [sleepRecord(hours: 5, drainPerHour: 6.2)])
    expect(red?.level == .red, "6.2 %/h is red")
    let edgeRed = evalPower(basePoints, sleeps: [sleepRecord(hours: 4, drainPerHour: 6)])
    expect(edgeRed?.level == .red, "exactly 6 %/h is red")
    let edgeYellow = evalPower(basePoints, sleeps: [sleepRecord(hours: 4, drainPerHour: 3)])
    expect(edgeYellow?.level == .yellow, "exactly 3 %/h is yellow")
    let low = evalPower(basePoints, sleeps: [sleepRecord(hours: 8, drainPerHour: 2.9)])
    expect(low?.level == .green, "2.9 %/h is green")
    let shortSleep = evalPower(basePoints, sleeps: [sleepRecord(hours: 1.9, drainPerHour: 20)])
    expect(shortSleep?.level == .green, "a sleep shorter than 2 hours is not judged")
    let onPower = evalPower(basePoints, sleeps: [sleepRecord(hours: 8, drainPerHour: 10, onBattery: false)])
    expect(onPower?.level == .green, "a sleep on power is not judged")
    let expired = evalPower(basePoints, sleeps: [sleepRecord(hours: 6, drainPerHour: 4, wokeMinutesAgo: 24 * 60 + 5)])
    expect(expired?.level == .green, "the sleep problem ends 24 hours after the wake")
    let cleared = evalPower(basePoints, sleeps: [sleepRecord(hours: 6, drainPerHour: 4, wokeMinutesAgo: 600),
                                                 sleepRecord(hours: 3, drainPerHour: 1, wokeMinutesAgo: 60)])
    expect(cleared?.level == .green, "a newer qualifying sleep judged green ends the problem")
    let keep = evalPower(basePoints, sleeps: [sleepRecord(hours: 6, drainPerHour: 4, wokeMinutesAgo: 600),
                                              sleepRecord(hours: 1, drainPerHour: 1, wokeMinutesAgo: 60)])
    expect(keep?.level == .yellow, "a short newer sleep does not end the problem")
    expect(PowerHealth.sleepDrain(sleepRecord(hours: 4, drainPerHour: 5)) != nil, "sleepDrain gives a rate for a long battery sleep")

    section("Power: awake drain")
    let fast = drainPoints(0, 90, start: 100, perHour: 34)
    let fastV = replayPower(fast)
    expect(verdictAt(fastV, fast, 40)?.level == .green && verdictAt(fastV, fast, 40)?.reasonCode == "insufficient_window",
           "a window shorter than 60 minutes is insufficient_window, level green: \(verdictAt(fastV, fast, 40)?.reasonCode ?? "")")
    let f = verdictAt(fastV, fast, 80)
    expect(f?.level == .yellow && f?.reasonCode == "awake_drain", "34 %/h for an hour is yellow")
    expect(f?.headline == "电池供电 · 掉电 34%/小时", "awake headline: \(f?.headline ?? "")")
    expect((minutesSince(f) ?? 0) >= 58 && (minutesSince(f) ?? 0) <= 62, "the problem starts at the first sample with a rate of 30 %/h, got \(String(describing: minutesSince(f)))")
    let veryFast = drainPoints(0, 90, start: 100, perHour: 48)
    expect(replayPower(veryFast).last?.level == .red, "48 %/h is red")
    let normal = drainPoints(0, 90, start: 100, perHour: 12)
    expect(replayPower(normal).last?.level == .green && replayPower(normal).last?.reasonCode == "ok", "12 %/h is green")
    expect(replayPower(normal).last?.headline == "电量 " + String(format: "%.0f", normal.last!.battery!) + "% · 电池供电", "green headline on battery")

    // Exit below 80 % of the entry threshold (24 %/h), or when the charger is connected.
    let slow = drainPoints(0, 70, start: 100, perHour: 34) + drainPoints(70.5, 200, start: 62, perHour: 27)
    let slowV = replayPower(slow)
    expect(verdictAt(slowV, slow, 100)?.level == .yellow, "27 %/h holds yellow (exit below 24 %/h)")
    let ended = drainPoints(0, 70, start: 100, perHour: 34) + drainPoints(70.5, 200, start: 62, perHour: 10)
    expect(replayPower(ended).last?.level == .green, "10 %/h ends the problem")
    let plug = drainPoints(0, 90, start: 100, perHour: 34) + gen(90.5, 92) { pt($0, battery: 70, power: .ac) }
    let plugV = replayPower(plug)
    expect(plugV.last?.level == .green && plugV.last?.headline == "电量 70% · 接电源", "the charger ends the problem: \(plugV.last?.headline ?? "")")
    let replug = plug + drainPoints(92.5, 120, start: 70, perHour: 34)
    let replugV = replayPower(replug)
    expect(replugV.last?.reasonCode == "insufficient_window", "the window is cleared when power is connected")

    // A charger inside the 60 minutes breaks the window.
    let mixed = drainPoints(0, 30, start: 100, perHour: 34) + gen(30.5, 35) { pt($0, battery: 90, power: .ac) } + drainPoints(35.5, 80, start: 90, perHour: 34)
    expect(replayPower(mixed).last?.reasonCode == "insufficient_window", "only the stretch after the last charger counts")

    section("Power: merge and unknowns")
    let both = replayPower(veryFast, sleeps: [sleepRecord(hours: 6, drainPerHour: 3.3, wokeMinutesAgo: 130)])
    let b = both.last
    expect(b?.level == .red && b?.reasonCode == "awake_drain", "the higher level wins")
    // Same level: the earlier start wins. Sleep wake at 10 minutes before the end vs awake start later.
    let sameYellow = replayPower(fast, sleeps: [SleepRecord(sleptAt: ruleBase.addingTimeInterval(-10 * 3600), wokeAt: ruleBase.addingTimeInterval(-2 * 3600),
                                                             batteryBefore: 90, batteryAfter: 60, onBatteryBeforeSleep: true)])
    let sy = sameYellow.last
    expect(sy?.level == .yellow && sy?.reasonCode == "sleep_drain", "the same level takes the earlier start: \(sy?.reasonCode ?? "")")
    expect(replayPower([]).isEmpty, "no points give no verdicts")
    expect(evalPower([], at: ruleBase)?.level == .unknown, "no points and no sleeps is unknown")
    let noBat = evalPower(gen(0, 5) { pt($0, battery: nil, power: nil) })
    expect(noBat?.level == .unknown, "no battery readings is unknown")
    let acOnly = evalPower(gen(0, 5) { pt($0, battery: 83, power: .ac) })
    expect(acOnly?.level == .green && acOnly?.headline == "电量 83% · 接电源", "on power it is green")
}
