// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the CPU, memory and thermal rules and ProblemOrder (docs/DESIGN.md 9.1).
// Pos: Called from main.swift via runHealthRuleTests(); no top-level code in this file. Owner I1.
//      Time is in minutes after `now` (the base). A replay evaluates the rule at every point, like the engine.

import Foundation

let ruleBase = now

/// Points every `step` minutes from minute `from` up to and including minute `to`.
func gen(_ from: Double, _ to: Double, step: Double = 0.5, _ make: (Double) -> TrendPoint) -> [TrendPoint] {
    var out = [TrendPoint]()
    var m = from
    while m <= to + 1e-9 {
        out.append(make(m))
        m += step
    }
    return out
}

func pt(_ minute: Double, cpu: Double? = nil, pressure: MemoryPressure? = nil, swap: Int64? = nil,
        thermal: ThermalLevel? = nil, battery: Double? = nil, power: PowerSource? = nil) -> TrendPoint {
    var p = TrendPoint(t: ruleBase.addingTimeInterval(minute * 60))
    p.cpu = cpu
    p.pressure = pressure
    p.swapUsed = swap
    p.thermal = thermal
    p.battery = battery
    p.power = power
    return p
}

/// Verdict after every point, with the state carried over.
func replay(_ points: [TrendPoint], _ evaluate: ([TrendPoint], Date, inout RuleMemory) -> ItemVerdict?) -> [ItemVerdict] {
    var state = RuleMemory()
    var out = [ItemVerdict]()
    for i in 0..<points.count {
        let prefix = Array(points[0...i])
        if let v = evaluate(prefix, points[i].t, &state) { out.append(v) }
    }
    return out
}

/// The verdict at minute `m` of a replay made from `points`.
func verdictAt(_ verdicts: [ItemVerdict], _ points: [TrendPoint], _ m: Double) -> ItemVerdict? {
    let target = ruleBase.addingTimeInterval(m * 60)
    guard let i = points.firstIndex(where: { $0.t >= target }), i < verdicts.count else { return nil }
    return verdicts[i]
}

func minutesSince(_ v: ItemVerdict?) -> Double? {
    v?.since.map { $0.timeIntervalSince(ruleBase) / 60 }
}

func replayCPU(_ pts: [TrendPoint], apps: [AppWindowStat] = []) -> [ItemVerdict] {
    replay(pts) { p, t, s in CPUHealth.evaluate(points: p, apps: apps, now: t, state: &s) }
}

func replayMemory(_ pts: [TrendPoint], physical: Int64 = 17_179_869_184) -> [ItemVerdict] {
    replay(pts) { p, t, s in MemoryHealth.evaluate(points: p, physicalBytes: physical, now: t, state: &s) }
}

func replayThermal(_ pts: [TrendPoint]) -> [ItemVerdict] {
    replay(pts) { p, t, s in ThermalHealth.evaluate(points: p, now: t, state: &s) }
}

func runHealthRuleTests() {
    runCPURuleTests()
    runMemoryRuleTests()
    runThermalRuleTests()
    runProblemOrderTests()
}

private func runCPURuleTests() {
    section("CPU rules")
    let calm = gen(0, 20) { pt($0, cpu: 50) }
    let calmV = replayCPU(calm)
    expect(calmV.last?.level == .green && calmV.last?.since == nil, "50 % for 20 min is green")
    expect(calmV.last?.headline == "CPU 5 分钟均值 50%", "green headline shows the mean: \(calmV.last?.headline ?? "")")
    expect(verdictAt(calmV, calm, 2)?.level == .unknown && verdictAt(calmV, calm, 2)?.reasonCode == "collecting",
           "2 minutes of data is collecting")
    expect(verdictAt(calmV, calm, 6)?.level == .green, "after 4.5 minutes the rule can judge")

    let busy = gen(0, 40) { pt($0, cpu: 80) }
    let busyV = replayCPU(busy)
    expect(verdictAt(busyV, busy, 8)?.level == .green, "80 % for 8 min is not yellow yet")
    expect(verdictAt(busyV, busy, 10.5)?.level == .yellow, "80 % for 10.5 min is yellow")
    let y = verdictAt(busyV, busy, 20)
    expect(y?.reasonCode == "cpu_mean_5m" && y?.headline == "5 分钟均值 80%", "yellow text: \(y?.headline ?? "")")
    expect(minutesSince(y) == 4.5, "since is the first sample with a 5 minute mean of 70 % or more, got \(String(describing: minutesSince(y)))")
    expect(verdictAt(busyV, busy, 30)?.level == .yellow, "yellow stays yellow before the 10 minute rule")

    let hot = gen(0, 45) { pt($0, cpu: 95) }
    let hotV = replayCPU(hot)
    expect(verdictAt(hotV, hot, 25)?.level == .red, "95 % for 25 min is red")
    let r = verdictAt(hotV, hot, 40)
    expect(r?.reasonCode == "cpu_mean_10m" && r?.headline == "10 分钟均值 95%", "red text: \(r?.headline ?? "")")
    expect(minutesSince(r) == 4.5, "yellow to red keeps the problem start, got \(String(describing: minutesSince(r)))")

    // Hysteresis: yellow, then 60 % (between 55 and 70) holds; then 40 % drops to green.
    let drop = gen(0, 20) { pt($0, cpu: 80) } + gen(20.5, 40) { pt($0, cpu: 62) } + gen(40.5, 50) { pt($0, cpu: 40) }
    let dropV = replayCPU(drop)
    expect(verdictAt(dropV, drop, 15)?.level == .yellow, "yellow before the drop")
    expect(verdictAt(dropV, drop, 39)?.level == .yellow, "62 % holds yellow (exit below 55 %)")
    expect(verdictAt(dropV, drop, 40.5 + 2)?.level == .yellow, "the exit needs 2 min below 55 %")
    expect(verdictAt(dropV, drop, 49)?.level == .green && verdictAt(dropV, drop, 49)?.since == nil, "40 % for a while returns to green")

    // Red drops to yellow first.
    let step = gen(0, 30) { pt($0, cpu: 95) } + gen(30.5, 60) { pt($0, cpu: 65) }
    let stepV = replayCPU(step)
    expect(verdictAt(stepV, step, 29)?.level == .red, "red before the drop")
    expect(verdictAt(stepV, step, 50)?.level == .yellow, "red drops to yellow, not to green (65 % is above 55 %)")
    expect(minutesSince(verdictAt(stepV, step, 50)) == minutesSince(verdictAt(stepV, step, 29)), "the problem start does not change on the drop")

    // A gap (sleep) clears the window and holds the level.
    let slept = gen(0, 20) { pt($0, cpu: 80) } + gen(60, 70) { pt($0, cpu: 80) }
    let sleptV = replayCPU(slept)
    expect(verdictAt(sleptV, slept, 62)?.level == .yellow, "after a sleep the level is held while the window fills")
    let fresh = gen(60, 70) { pt($0, cpu: 20) }
    expect(replayCPU(fresh).last?.level == .green, "a short run of low CPU is green")
    let nilCPU = gen(0, 10) { pt($0, cpu: nil) }
    expect(replayCPU(nilCPU).last?.level == .unknown && replayCPU(nilCPU).last?.reasonCode == "missing", "no CPU values gives unknown with reason missing")

    // One app on one core (PROJECT.md 3.2).
    let one = gen(0, 10) { pt($0, cpu: 10) }
    let hotApp = AppWindowStat(key: "com.example.render", name: "Render", mean10m: 98, mean30m: 95)
    let coolApp = AppWindowStat(key: "com.example.mail", name: "Mail", mean10m: 3, mean30m: 4)
    var st = RuleMemory()
    let a1 = CPUHealth.evaluate(points: one, apps: [hotApp, coolApp], now: one.last!.t, state: &st)
    expect(a1.level == .yellow && a1.reasonCode == "app_saturated" && a1.headline == "Render 占满一个核", "an app above 90 % is yellow: \(a1.headline)")
    expect(a1.since == one.last!.t.addingTimeInterval(-1800), "the app problem starts at the window start")
    var weak = hotApp
    weak.mean10m = 70
    weak.mean30m = 80
    let a2 = CPUHealth.evaluate(points: one, apps: [weak, coolApp], now: one.last!.t, state: &st)
    expect(a2.level == .yellow, "an app between the exit and the entry stays yellow")
    weak.mean10m = 40
    let a3 = CPUHealth.evaluate(points: one, apps: [weak, coolApp], now: one.last!.t, state: &st)
    expect(a3.level == .green && a3.since == nil, "10 minute mean below 50 % ends the app problem")
    var st2 = RuleMemory()
    _ = CPUHealth.evaluate(points: one, apps: [hotApp], now: one.last!.t, state: &st2)
    let gone = CPUHealth.evaluate(points: one, apps: [coolApp], now: one.last!.t, state: &st2)
    expect(gone.level == .green, "an app that left the list ends the problem")
    var st3 = RuleMemory()
    let just = AppWindowStat(key: "k", name: "K", mean10m: 90, mean30m: 89.9)
    expect(CPUHealth.evaluate(points: one, apps: [just], now: one.last!.t, state: &st3).level == .green, "a 30 minute mean of 89.9 % is not enough")
    var st4 = RuleMemory()
    _ = CPUHealth.evaluate(points: one, apps: [hotApp], now: one.last!.t, state: &st4)
    let held = CPUHealth.evaluate(points: one, apps: [], now: one.last!.t, state: &st4)
    expect(held.level == .yellow, "an empty app list does not end the problem")
    // The machine and the app rule together: the machine rule gives the text.
    var st5 = RuleMemory()
    let both = gen(0, 20) { pt($0, cpu: 85) }
    var last = ItemVerdict(item: .cpu, level: .unknown, reasonCode: "", headline: "", since: nil, levelChangedAt: nil, alert: nil)
    for i in 0..<both.count {
        last = CPUHealth.evaluate(points: Array(both[0...i]), apps: [hotApp], now: both[i].t, state: &st5)
    }
    expect(last.level == .yellow && last.reasonCode == "cpu_mean_5m", "the machine rule wins the text on a tie")
}

private let gib: Int64 = 1_073_741_824

private func runMemoryRuleTests() {
    section("Memory rules")
    let warn30 = gen(0, 5) { pt($0, pressure: .normal, swap: gib) } + gen(5.5, 6) { pt($0, pressure: .warning, swap: gib) }
    expect(replayMemory(warn30).last?.level == .green, "warning for 30 s is still green")
    let warn60 = gen(0, 5) { pt($0, pressure: .normal, swap: gib) } + gen(5.5, 6.5) { pt($0, pressure: .warning, swap: gib) }
    let w = replayMemory(warn60).last
    expect(w?.level == .yellow && w?.reasonCode == "pressure_warning", "warning for 60 s is yellow")
    expect(minutesSince(w) == 5.5, "since is the first warning sample, got \(String(describing: minutesSince(w)))")
    expect(w?.headline == "压力警告 · swap 1.1 GB", "yellow headline: \(w?.headline ?? "")")

    let crit = gen(0, 5) { pt($0, pressure: .normal, swap: 9 * gib) } + gen(5.5, 6.5) { pt($0, pressure: .critical, swap: 9 * gib) }
    let c = replayMemory(crit).last
    expect(c?.level == .red && c?.reasonCode == "pressure_critical", "critical for 30 s is red")
    expect(c?.headline == "压力严重 · swap 9.7 GB", "red headline: \(c?.headline ?? "")")

    // Exit: 5 minutes at most warning leaves red; 5 minutes of normal leaves yellow.
    let phase = gen(0, 3) { pt($0, pressure: .normal, swap: gib) } + gen(3.5, 10) { pt($0, pressure: .critical, swap: gib) }
        + gen(10.5, 14) { pt($0, pressure: .warning, swap: gib) } + gen(14.5, 22) { pt($0, pressure: .warning, swap: gib) }
        + gen(22.5, 25) { pt($0, pressure: .normal, swap: gib) } + gen(25.5, 40) { pt($0, pressure: .normal, swap: gib) }
    let pv = replayMemory(phase)
    expect(verdictAt(pv, phase, 9)?.level == .red, "red during critical")
    expect(verdictAt(pv, phase, 13)?.level == .red, "red holds until 5 minutes at most warning")
    expect(verdictAt(pv, phase, 16)?.level == .yellow, "red drops to yellow after 5 minutes at warning")
    expect(minutesSince(verdictAt(pv, phase, 16)) == minutesSince(verdictAt(pv, phase, 9)), "problem start is unchanged")
    expect(verdictAt(pv, phase, 24)?.level == .yellow, "yellow holds while normal lasts less than 5 minutes")
    expect(verdictAt(pv, phase, 38)?.level == .green, "5 minutes of normal ends the problem")

    // Swap growth.
    func swapRamp(_ gbEnd: Double) -> [TrendPoint] {
        gen(0, 40) { m in pt(m, pressure: .normal, swap: Int64(Double(gib) * (1 + (m >= 10 ? (m - 10) / 30.0 * gbEnd : 0)))) }
    }
    let grow = replayMemory(swapRamp(3.0))
    let g = grow.last
    expect(g?.level == .yellow && g?.reasonCode == "swap_growth", "3 GiB in 30 minutes is yellow (limit 2 GiB on 16 GiB): \(g?.level.rawValue ?? "")")
    expect(g?.headline.hasPrefix("swap 30 分钟增加 ") == true, "swap headline: \(g?.headline ?? "")")
    expect(replayMemory(swapRamp(1.8)).last?.level == .green, "1.8 GiB in 30 minutes is green")
    expect(replayMemory(swapRamp(3.0), physical: 64 * gib).last?.level == .green, "the limit is 12.5 % of memory on a 64 GiB Mac (8 GiB)")
    let easing = swapRamp(3.0) + gen(40.5, 80) { pt($0, pressure: .normal, swap: 4 * gib - Int64(Double($0 - 40) * 0.01 * Double(gib))) }
    let ev = replayMemory(easing)
    expect(verdictAt(ev, easing, 55)?.level == .yellow, "growth between 512 MiB and 2 GiB holds yellow")
    expect(ev.last?.level == .green, "growth below 512 MiB ends the swap problem")

    // swapTrend arrows.
    func trendFor(_ delta: Double, physical: Int64 = 17_179_869_184) -> SwapTrend? {
        let p = gen(0, 40) { m in pt(m, swap: Int64(Double(gib) * (4 + (m >= 10 ? (m - 10) / 30.0 * delta : 0)))) }
        return MemoryHealth.swapTrend(points: p, physicalBytes: physical, now: p.last!.t)
    }
    expect(trendFor(3.0) == .steepUp, "+3 GiB is steepUp")
    expect(trendFor(1.0) == .up, "+1 GiB is up")
    expect(trendFor(0.2) == .flat, "+0.2 GiB is flat")
    expect(trendFor(-1.0) == .down, "-1 GiB is down")
    expect(trendFor(3.0, physical: 64 * gib) == .up, "+3 GiB is only up on a 64 GiB Mac")
    let shortSwap = gen(0, 10) { pt($0, swap: gib) }
    expect(MemoryHealth.swapTrend(points: shortSwap, physicalBytes: 17_179_869_184, now: shortSwap.last!.t) == nil, "no point 30 minutes ago gives no arrow")
    expect(MemoryHealth.swapGrowth30m(points: [], now: now) == nil, "no points give no growth")

    let noPressure = gen(0, 5) { pt($0, pressure: nil, swap: nil) }
    expect(replayMemory(noPressure).last?.level == .unknown, "no memory readings is unknown")
    let first = replayMemory(gen(0, 0.5) { pt($0, pressure: .normal, swap: gib) })
    expect(first.last?.level == .green, "a normal pressure reading is green at once")
    expect(first.last?.headline == "内存压力正常 · swap 1.1 GB", "green headline: \(first.last?.headline ?? "")")
}

private func runThermalRuleTests() {
    section("Thermal rules")
    let fair9 = gen(0, 9) { pt($0, thermal: .fair) }
    expect(replayThermal(fair9).last?.level == .green, "fair for 9 min is green")
    let fair10 = gen(0, 10) { pt($0, thermal: .fair) }
    let f = replayThermal(fair10).last
    expect(f?.level == .yellow && f?.reasonCode == "thermal_fair" && f?.headline == "热状态偏热", "fair for 10 min is yellow")
    expect(minutesSince(f) == 0, "since is the first fair sample")
    let serious = gen(0, 3) { pt($0, thermal: .nominal) } + gen(3.5, 4.5) { pt($0, thermal: .serious) }
    let s = replayThermal(serious).last
    expect(s?.level == .red && s?.reasonCode == "thermal_serious" && s?.headline == "热状态很热", "serious for 60 s is red")
    expect(replayThermal(gen(0, 3) { pt($0, thermal: .nominal) } + gen(3.5, 4) { pt($0, thermal: .serious) }).last?.level == .green, "serious for 30 s is not red yet")
    let critical = gen(0, 3) { pt($0, thermal: .nominal) } + [pt(3.5, thermal: .critical)]
    let cv = replayThermal(critical).last
    expect(cv?.level == .red && cv?.reasonCode == "thermal_critical" && cv?.headline == "热状态过热", "critical is red at once")

    let cycle = gen(0, 12) { pt($0, thermal: .fair) } + gen(12.5, 16) { pt($0, thermal: .serious) }
        + gen(16.5, 18) { pt($0, thermal: .fair) } + gen(18.5, 22) { pt($0, thermal: .fair) }
        + gen(22.5, 24) { pt($0, thermal: .fair) } + gen(24.5, 30) { pt($0, thermal: .nominal) }
    let cyc = replayThermal(cycle)
    expect(verdictAt(cyc, cycle, 14)?.level == .red, "red while serious")
    expect(verdictAt(cyc, cycle, 17)?.level == .red, "red holds below 3 minutes at fair")
    expect(verdictAt(cyc, cycle, 22)?.level == .yellow, "after 3 minutes at most fair, red drops to yellow")
    expect(minutesSince(verdictAt(cyc, cycle, 22)) == 0, "the problem start is unchanged")
    expect(verdictAt(cyc, cycle, 26)?.level == .yellow, "yellow holds until nominal lasts 3 minutes")
    expect(verdictAt(cyc, cycle, 29)?.level == .green, "nominal for 3 minutes ends the problem")
    expect(replayThermal(gen(0, 5) { pt($0, thermal: nil) }).last?.level == .unknown, "no thermal readings is unknown")
    expect(replayThermal(gen(0, 2) { pt($0, thermal: .nominal) }).last?.headline == "温度正常", "green headline")
}

private func verdict(_ item: HealthItem, _ level: HealthLevel, since minutes: Double?) -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: "x", headline: "x",
                since: minutes.map { ruleBase.addingTimeInterval(-$0 * 60) }, levelChangedAt: nil, alert: nil)
}

private func runProblemOrderTests() {
    section("ProblemOrder")
    // Level first.
    let a = ProblemOrder.problems([verdict(.cpu, .red, since: 5), verdict(.disk, .yellow, since: 500), verdict(.memory, .red, since: 50)])
    expect(a.map { $0.item } == [.memory, .cpu, .disk], "red first (longer first), then yellow: \(a.map { $0.item.rawValue })")
    // Duration, then fixed priority when the starts are within 60 s.
    let b = ProblemOrder.problems([verdict(.cpu, .yellow, since: 30), verdict(.thermal, .yellow, since: 30.5), verdict(.disk, .yellow, since: 30.9)])
    expect(b.map { $0.item } == [.thermal, .disk, .cpu], "starts within 60 s are the same, fixed priority decides: \(b.map { $0.item.rawValue })")
    let c = ProblemOrder.problems([verdict(.thermal, .yellow, since: 10), verdict(.cpu, .yellow, since: 12)])
    expect(c.map { $0.item } == [.cpu, .thermal], "a start more than 60 s earlier goes first")
    // Fixed priority list: thermal, memory, disk, power, cpu.
    let d = ProblemOrder.problems([verdict(.cpu, .yellow, since: 1), verdict(.power, .yellow, since: 1), verdict(.disk, .yellow, since: 1),
                                   verdict(.memory, .yellow, since: 1), verdict(.thermal, .yellow, since: 1)])
    expect(d.map { $0.item } == [.thermal, .memory, .disk, .power, .cpu], "fixed priority is thermal, memory, disk, power, cpu")
    // All: problems first, then the rest by fixed priority.
    let all = ProblemOrder.all([verdict(.cpu, .green, since: nil), verdict(.disk, .red, since: 5), verdict(.thermal, .green, since: nil),
                                verdict(.power, .unknown, since: nil), verdict(.memory, .green, since: nil)])
    expect(all.map { $0.item } == [.disk, .thermal, .memory, .power, .cpu], "all: problem first, then fixed priority: \(all.map { $0.item.rawValue })")
    // Stability: equal inputs in any order give the same output.
    let items = [verdict(.cpu, .yellow, since: 20), verdict(.memory, .yellow, since: 20.2), verdict(.power, .yellow, since: 19.9)]
    let o1 = ProblemOrder.problems(items).map { $0.item }
    let o2 = ProblemOrder.problems(items.reversed()).map { $0.item }
    expect(o1 == o2, "the order does not depend on the input order: \(o1) \(o2)")
    // Chains inside the 60 s tolerance do not flip: 0 s, 50 s, 100 s starts.
    let chain = [verdict(.cpu, .yellow, since: 10), verdict(.memory, .yellow, since: 10 + 50.0 / 60), verdict(.thermal, .yellow, since: 10 + 100.0 / 60)]
    let ch1 = ProblemOrder.problems(chain).map { $0.item }
    let ch2 = ProblemOrder.problems(chain.reversed()).map { $0.item }
    expect(ch1 == ch2, "a chain of near starts sorts the same in every input order: \(ch1) \(ch2)")
    expect(ProblemOrder.problems([verdict(.cpu, .green, since: nil), verdict(.disk, .stale, since: nil)]).isEmpty, "only yellow and red are problems")
    expect(ProblemOrder.topic(for: .power) == .power && ProblemOrder.topic(for: .disk) == .disk, "topic maps from item")
}
