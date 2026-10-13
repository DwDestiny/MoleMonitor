// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for DogAction, DogStage and DogDirector (docs/DESIGN_V2.md 4.3 to 4.6, 4.9; gate W04 part 2, the computation).
// Pos: Called from main.swift via runDogActionTests(); no top-level code in this file.

import Foundation

func runDogActionTests() {
    section("DogActionTests")
    expect(DogAction.allCases.count == 10, "ten actions in the first release")
    expect(DogAction.lieIdle.rawValue == "lie_idle" && DogAction.sitGray.rawValue == "sit_gray", "raw values are the strip names")
    expect(DogActionInput().dataState == .fresh && DogActionInput().oneShot == nil, "default input is fresh without a one-shot")

    // f(s) nodes (4.5 rule 3) and the example of rule 5.
    let nodes: [(Double, Double)] = [(10, 0.70), (40, 1.30), (80, 2.08), (100, 3.00)]
    for (s, f) in nodes { expect(abs(DogStage.stepFrequency(s) - f) < 1e-9, "f(\(s)) = \(f)") }
    expect(abs(DogStage.stepFrequency(60) - 1.69) < 1e-9, "f(60) = 1.69 Hz")
    expect(DogStage.stepFrequency(0) == 0.70 && DogStage.stepFrequency(120) == 3.00, "f is flat outside the nodes")

    // 4.4 priority table, one row each. The director starts from the first CPU value without smoothing.
    func plan(_ input: DogActionInput) -> DogStagePlan {
        var d = DogDirector()
        return d.step(dt: 0, input: input)
    }
    let stale = plan(DogActionInput(dataState: .stale(now), cpuPercent: 95, thermal: .red))
    expect(stale.action == .sitGray, "stale wins over everything: sit_gray")
    expect(plan(DogActionInput(dataState: .collecting)).action == .sniff, "collecting: sniff")
    let hot = plan(DogActionInput(cpuPercent: 95, thermal: .red, memory: .red))
    expect(hot.action == .pantLie && hot.groundSpeed == 0, "thermal red beats memory red: pant_lie, no ground motion")
    let heavy = plan(DogActionInput(cpuPercent: 95, memory: .red))
    expect(heavy.action == .walk && heavy.variant == .heavy, "memory red: heavy walk")
    expect(heavy.sink == 4 && heavy.scaleY == 0.97, "heavy walk sinks 4 pt with scale 0.97")
    expect(heavy.stepHz <= 0.8 + 1e-9 && abs(heavy.stepHz - min(3.0 * 0.6, 0.8)) < 1e-9, "heavy steps f x 0.6 and at most 0.8 Hz")
    expect(abs(heavy.groundSpeed - 24 * heavy.stepHz) < 1e-9, "heavy ground slows in proportion")
    let tired = plan(DogActionInput(cpuPercent: 20, power: .yellow))
    expect(tired.action == .lieIdle && tired.variant == .tired && tired.rate == 0.6 && tired.sink == 2, "power yellow, CPU 20: tired lie at 0.6, 2 pt lower")
    expect(plan(DogActionInput(cpuPercent: 45, power: .red)).action == .trot, "power red with CPU 45: the CPU gait")
    expect(plan(DogActionInput(cpuPercent: 25, oneShot: .wag)).action == .wag, "a one-shot plays over the gait")
    expect(plan(DogActionInput(cpuPercent: 25, thermal: .red, oneShot: .wag)).action == .pantLie, "a problem action beats a one-shot")
    let sleep = plan(DogActionInput(cpuPercent: 10, isNight: true))
    expect(sleep.action == .lieIdle && sleep.variant == .sleep && sleep.rate == 0.5 && sleep.showsZ, "night, no problem, CPU 10: sleep at 0.5 with z")
    expect(plan(DogActionInput(cpuPercent: 25, isNight: true)).action == .walk, "night with CPU 25: the CPU gait")
    expect(plan(DogActionInput(cpuPercent: 5, disk: .yellow, isNight: true)).variant == .normal, "night with a problem: no sleep variant")
    expect(plan(DogActionInput(cpuPercent: 5, isNight: true, cpu: .yellow)).variant == .normal, "night with a CPU problem: no sleep variant")
    expect(plan(DogActionInput(cpuPercent: 5)).action == .lieIdle, "CPU 5: lie")
    expect(plan(DogActionInput(cpuPercent: 25)).action == .walk, "CPU 25: walk")
    expect(plan(DogActionInput(cpuPercent: 60)).action == .trot, "CPU 60: trot")
    expect(plan(DogActionInput(cpuPercent: 95)).action == .sprint, "CPU 95: sprint")
    expect(abs(plan(DogActionInput(cpuPercent: 60)).rate - 1.69 / 1.6) < 1e-9, "CPU 60: trot rate 1.06 (4.5 rule 5)")
    expect(abs(plan(DogActionInput(cpuPercent: 100)).rate - 1.25) < 1e-9, "CPU 100: sprint rate 1.25, 18 fps")

    // Overlays (4.4 second table).
    let over = plan(DogActionInput(cpuPercent: 25, thermal: .yellow, memory: .yellow, disk: .red, isNight: true))
    expect(over.overlays.bed == .full && over.overlays.sweat && over.overlays.memorySink && over.overlays.night, "disk red bed, sweat, memory sink, night")
    expect(over.sink == 2 && abs(over.stepHz - DogStage.stepFrequency(25) * 0.8) < 1e-9, "memory yellow: 2 pt lower, steps x 0.8")
    expect(plan(DogActionInput(cpuPercent: 25, disk: .yellow)).overlays.bed == .some, "disk yellow: half bed")
    let sweatLie = plan(DogActionInput(cpuPercent: 3, thermal: .yellow))
    expect(sweatLie.action == .lieIdle && abs(sweatLie.rate - 1.5) < 1e-9, "temperature yellow: breathing x 1.5")
    expect(plan(DogActionInput(dataState: .collecting, disk: .red)).overlays.bed == nil, "no bed while collecting")

    // Hysteresis, minimum hold and switch budget (4.5 rules 4 and 9).
    var d = DogDirector()
    d.step(dt: 0, input: DogActionInput(cpuPercent: 45))
    expect(d.gait == .trot, "first value 45: trot at once")
    for _ in 0..<10 { d.step(dt: 2, input: DogActionInput(cpuPercent: 36)) }
    expect(d.gait == .trot, "36 stays trot (leave below 34)")
    var t = 0.0
    while d.gait == .trot && t < 60 { d.step(dt: 2, input: DogActionInput(cpuPercent: 20)); t += 2 }
    expect(d.gait == .walk, "falls to walk below 34")
    var e = DogDirector()
    e.step(dt: 0, input: DogActionInput(cpuPercent: 5))
    e.step(dt: 2, input: DogActionInput(cpuPercent: 95))
    let firstSwitch = e.gait
    e.step(dt: 1, input: DogActionInput(cpuPercent: 0))
    e.step(dt: 1, input: DogActionInput(cpuPercent: 0))
    expect(firstSwitch != .lieIdle && e.gait == firstSwitch, "a new gait holds for 4 s")

    // W04 part 2: CPU 5 % to 95 % in 60 s, one sample per 2 s.
    var r = DogDirector()
    var freqs = [Double]()
    var worstDev = 0.0
    var worstStep = 0.0
    var previous: DogStagePlan?
    for i in 0...30 {
        let s = 5 + 90 * Double(i) / 30
        let p = r.step(dt: i == 0 ? 0 : 2, input: DogActionInput(cpuPercent: s))
        if p.action != .lieIdle {
            freqs.append(p.stepHz)
            let f = DogStage.stepFrequency(r.smoothed ?? s)
            worstDev = max(worstDev, abs(p.stepHz - f) / f)
        }
        if let q = previous, q.action == p.action { worstStep = max(worstStep, abs(p.rate - q.rate)) }
        previous = p
    }
    let monotonic = zip(freqs, freqs.dropFirst()).allSatisfy { $0.1 >= $0.0 - 1e-9 }
    expect(monotonic, "ramp: the step frequency never falls")
    expect(worstDev <= 0.02, "ramp: step frequency within 2 % of f(s), worst \(worstDev)")
    expect(worstStep <= 0.25 + 1e-9, "ramp: rate change per sample at most 0.25, worst \(worstStep)")
    expect(r.gait == .sprint, "ramp ends in sprint")

    // Transitions (4.6).
    expect(DogStage.transition(from: .walk, to: .trot) == .atContact, "gait to gait at a contact frame")
    expect(DogStage.transition(from: .lieIdle, to: .walk) == .standUp, "lie to walk: stand_up")
    expect(DogStage.transition(from: .pantLie, to: .sprint) == .standUp, "pant_lie to sprint: stand_up")
    expect(DogStage.transition(from: .trot, to: .lieIdle) == .lieDown, "trot to lie: lie_down")
    expect(DogStage.transition(from: .walk, to: .sitGray) == .crossfade(0.2), "to sit_gray: 200 ms crossfade")
    expect(DogStage.transition(from: .lieIdle, to: .sniff) == .crossfade(0.16), "to sniff: 160 ms crossfade")
    expect(DogStage.transition(from: .wag, to: .walk) == .crossfade(0.12), "one-shot end: 120 ms crossfade")
    expect(DogStage.transition(from: .walk, .normal, to: .walk, .heavy) == .tween, "variant change: tween")
    expect(DogStage.transition(from: .walk, to: .walk) == .none, "same action: none")

    // Night window (4.9 rule 1).
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: now)! }
    expect(DogStage.isNight(at(22), calendar: cal) && DogStage.isNight(at(5), calendar: cal), "22:00 and 5:00 are night")
    expect(!DogStage.isNight(at(6), calendar: cal) && !DogStage.isNight(at(21), calendar: cal), "6:00 and 21:00 are day")
}
