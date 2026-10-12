// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section) defined in main.swift.
// Output: Assertions for DogArtPose (priority of the eight bitmaps) and DogArtSelector (smoothing, hysteresis, minimum hold,
//         the same gait as DogMotor) of docs/DESIGN.md 4.9.
// Pos: Called from main.swift via runDogArtPoseTests(); no top-level code in this file.

import Foundation

private func artInput(cpu: Double?, thermal: ThermalLevel? = .nominal, problem: HealthItem? = nil,
                      level: HealthLevel = .green, isStatic: Bool = false) -> DogInput {
    DogInput(cpuPercent: cpu, thermal: thermal, memoryLevel: .green, worstProblem: problem, worstLevel: level, isStatic: isStatic)
}

func runDogArtPoseTests() {
    section("DogArtPose")

    // File names and the list of eight.
    expect(DogArtPose.allCases.count == 8, "eight bitmaps")
    expect(DogArtPose.allCases.map { $0.fileName } == ["dog_lie", "dog_stand", "dog_walk", "dog_trot", "dog_sprint", "dog_pant", "dog_alert", "dog_gray"],
           "file names follow dog_<name>")

    // Gait map without overlays.
    let calm = artInput(cpu: 20)
    expect(DogArtPose.select(input: calm, gait: .lie) == .lie, "gait lie -> lie")
    expect(DogArtPose.select(input: calm, gait: .stand) == .stand, "gait stand -> stand")
    expect(DogArtPose.select(input: calm, gait: .walk) == .walk, "gait walk -> walk")
    expect(DogArtPose.select(input: calm, gait: .trot) == .trot, "gait trot -> trot")
    expect(DogArtPose.select(input: calm, gait: .sprint) == .sprint, "gait sprint -> sprint")

    // Priority 1: static is gray, whatever else is set.
    let staticAll = artInput(cpu: 95, thermal: .critical, problem: .disk, level: .red, isStatic: true)
    for g in DogGait.allCases {
        expect(DogArtPose.select(input: staticAll, gait: g) == .gray, "static beats pant, alert and every gait (\(g.rawValue))")
    }
    expect(DogArtPose.select(input: artInput(cpu: nil, thermal: nil, isStatic: true), gait: .stand) == .gray, "collecting is gray")

    // Priority 2: a red temperature is pant, before alert and before the gait.
    for t: ThermalLevel in [.serious, .critical] {
        expect(DogArtPose.select(input: artInput(cpu: 50, thermal: t), gait: .trot) == .pant, "thermal \(t.rawValue) -> pant")
        expect(DogArtPose.select(input: artInput(cpu: 50, thermal: t, problem: .thermal, level: .red), gait: .trot) == .pant,
               "pant beats alert (\(t.rawValue))")
    }
    for t: ThermalLevel? in [.nominal, .fair, nil] {
        expect(DogArtPose.select(input: artInput(cpu: 50, thermal: t), gait: .trot) == .trot, "thermal \(String(describing: t)) is not pant")
    }

    // Priority 3: the worst problem yellow or red is alert.
    expect(DogArtPose.select(input: artInput(cpu: 50, problem: .cpu, level: .yellow), gait: .trot) == .alert, "yellow problem -> alert")
    expect(DogArtPose.select(input: artInput(cpu: 5, problem: .disk, level: .red), gait: .lie) == .alert, "red problem -> alert")
    for level: HealthLevel in [.green, .unknown, .stale, .notApplicable] {
        expect(DogArtPose.select(input: artInput(cpu: 50, problem: .disk, level: level), gait: .trot) == .trot,
               "problem with level \(level.rawValue) is not alert")
    }
    expect(DogArtPose.select(input: artInput(cpu: 50, problem: nil, level: .red), gait: .trot) == .trot, "no problem item -> gait")

    // nil CPU: stand, and no crash.
    var nilCPU = DogArtSelector(initial: artInput(cpu: nil))
    expect(nilCPU.gait == .stand && nilCPU.pose == .stand, "nil CPU at the start is stand")
    nilCPU.advance(dt: 30, input: artInput(cpu: nil))
    expect(nilCPU.pose == .stand, "nil CPU stays stand")
    nilCPU.advance(dt: 30, input: artInput(cpu: 90))
    expect(nilCPU.pose == .sprint, "the first CPU value picks its gait at once (stand -> sprint)")
    nilCPU.advance(dt: 30, input: artInput(cpu: nil))
    expect(nilCPU.pose == .sprint, "a later nil CPU keeps the gait")

    // The first value picks the plain gait without smoothing.
    let starts: [(Double, DogArtPose)] = [(0, .lie), (9.9, .lie), (10, .walk), (39.9, .walk), (40, .trot), (79.9, .trot), (80, .sprint), (100, .sprint)]
    for (cpu, want) in starts {
        expect(DogArtSelector(initial: artInput(cpu: cpu)).pose == want, "initial CPU \(cpu) -> \(want.rawValue)")
    }

    section("DogArtSelector smoothing and hysteresis")

    // Hysteresis: walk is entered at 10 and left below 7. Hold CPU between the two: no change in either direction.
    var sel = DogArtSelector(initial: artInput(cpu: 20))
    expect(sel.pose == .walk, "start walk")
    for _ in 0..<60 { sel.advance(dt: 2, input: artInput(cpu: 8.5)) }
    expect(sel.pose == .walk, "CPU 8.5 (between leave 7 and enter 10) keeps walk")
    for _ in 0..<60 { sel.advance(dt: 2, input: artInput(cpu: 5)) }
    expect(sel.pose == .lie, "CPU 5 leaves walk (below 7)")
    for _ in 0..<60 { sel.advance(dt: 2, input: artInput(cpu: 8.5)) }
    expect(sel.pose == .lie, "CPU 8.5 keeps lie (below enter 10)")
    for _ in 0..<60 { sel.advance(dt: 2, input: artInput(cpu: 12)) }
    expect(sel.pose == .walk, "CPU 12 enters walk")

    // Smoothing: one spike of 2 s does not switch the picture (alpha = 1 - exp(-2/8) = 0.22).
    var spike = DogArtSelector(initial: artInput(cpu: 20))
    spike.advance(dt: 2, input: artInput(cpu: 95))
    expect(spike.pose == .walk, "a single 2 s spike to 95 % does not leave walk (smoothed about 36)")
    spike.advance(dt: 2, input: artInput(cpu: 20))
    expect(spike.pose == .walk, "and it falls back")
    // A sustained load does switch.
    var load = DogArtSelector(initial: artInput(cpu: 20))
    for _ in 0..<30 { load.advance(dt: 2, input: artInput(cpu: 95)) }
    expect(load.pose == .sprint, "60 s at 95 % reaches sprint")

    // Minimum hold: 4 s in one gait. Start in walk, jump to a very high CPU in 0.5 s steps: the switch waits for 4 s.
    var hold = DogArtSelector(initial: artInput(cpu: 20))
    hold.advance(dt: 0.5, input: artInput(cpu: 100))        // time 0.5
    var firstSwitchTime = -1.0
    var t = 0.5
    for _ in 0..<40 {
        let before = hold.gait
        hold.advance(dt: 0.5, input: artInput(cpu: 100))
        t += 0.5
        if hold.gait != before { firstSwitchTime = t; break }
    }
    expect(firstSwitchTime >= 0, "the high CPU does switch the gait in the end")
    // The first selector gait is the start gait, which was never "switched": lastSwitch is -infinity, so the first switch
    // is allowed as soon as the smoothed value passes the enter value.
    var hold2 = DogArtSelector(initial: artInput(cpu: 20))
    var times = [Double]()
    var clock = 0.0
    // CPU alternates 100 and 0 every 1 s: the smoothed value moves around 50, so switches are rare and never faster than 4 s.
    for i in 0..<400 {
        let before = hold2.gait
        hold2.advance(dt: 1, input: artInput(cpu: i % 2 == 0 ? 100 : 0))
        clock += 1
        if hold2.gait != before { times.append(clock) }
    }
    var minGap = Double.infinity
    for (a, b) in zip(times, times.dropFirst()) { minGap = min(minGap, b - a) }
    expect(minGap >= DogGaitRules.minHold || times.count < 2, "two switches are at least 4 s apart (min gap \(minGap))")
    // No more than 2 switches in any 10 s window.
    var worstWindow = 0
    for a in times {
        worstWindow = max(worstWindow, times.filter { $0 >= a && $0 < a + DogGaitRules.switchWindow }.count)
    }
    expect(worstWindow <= DogGaitRules.maxSwitches, "at most 2 switches in 10 s (worst \(worstWindow))")

    // Direct check of the hold with a smoothed value that crosses both thresholds quickly:
    // the selector at 0.5 s steps may not switch twice inside 4 s.
    var quick = DogArtSelector(initial: artInput(cpu: 0))
    var switches = [Double]()
    var qt = 0.0
    for step in 0..<200 {
        let before = quick.gait
        let cpu: Double = (step / 8) % 2 == 0 ? 100 : 0   // 4 s high, 4 s low
        quick.advance(dt: 0.5, input: artInput(cpu: cpu))
        qt += 0.5
        if quick.gait != before { switches.append(qt) }
    }
    var quickGap = Double.infinity
    for (a, b) in zip(switches, switches.dropFirst()) { quickGap = min(quickGap, b - a) }
    expect(switches.count >= 2, "the quick wave does switch (\(switches.count) switches)")
    expect(quickGap >= DogGaitRules.minHold, "minimum hold 4 s holds for the quick wave (min gap \(quickGap))")

    // A static input does not move the smoothing, and the next fresh input continues from the old value.
    var pause = DogArtSelector(initial: artInput(cpu: 50))
    let before = pause.smoothed
    pause.advance(dt: 30, input: artInput(cpu: nil, thermal: nil, isStatic: true))
    expect(pause.pose == .gray, "static input shows gray")
    expect(pause.smoothed == before, "static input keeps the smoothed CPU")
    pause.advance(dt: 30, input: artInput(cpu: 50))
    expect(pause.pose == .trot, "back to the gait after the static input")

    // Overlays do not stop the gait from running: pant first, then the gait shows what the CPU did meanwhile.
    var overlay = DogArtSelector(initial: artInput(cpu: 5))
    expect(overlay.pose == .lie, "start lie")
    for _ in 0..<40 { overlay.advance(dt: 2, input: artInput(cpu: 90, thermal: .serious)) }
    expect(overlay.pose == .pant, "red temperature shows pant")
    expect(overlay.gait == .sprint, "the gait went on in the background")
    overlay.advance(dt: 2, input: artInput(cpu: 90, thermal: .nominal))
    expect(overlay.pose == .sprint, "without the temperature the gait shows")

    // Same gait as DogMotor for the same steps: the selector reuses the rules, it does not change them.
    let waves: [(String, (Int) -> Double)] = [
        ("steps", { i in i < 120 ? 5 : (i < 300 ? 60 : (i < 420 ? 95 : 20)) }),
        ("edge", { i in 38 + 4 * sin(Double(i) / 3) }),
        ("walk edge", { i in 8.5 + 3 * sin(Double(i) / 5) }),
        ("noise", { i in Double((i * 37) % 100) }),
    ]
    for (name, wave) in waves {
        let first = artInput(cpu: wave(0))
        var motor = DogMotor(initialCPU: wave(0))
        var selector = DogArtSelector(initial: first)
        var different = 0
        for i in 1..<600 {
            let input = artInput(cpu: wave(i))
            _ = motor.frame(dt: 0.1, input: input)
            selector.advance(dt: 0.1, input: input)
            if motor.gait != selector.gait { different += 1 }
        }
        expect(different == 0, "selector gait equals DogMotor gait for wave \(name) (\(different) different steps)")
    }

    // Big steps are clamped.
    var big = DogArtSelector(initial: artInput(cpu: 5))
    big.advance(dt: 1e9, input: artInput(cpu: 95))
    expect(big.smoothed != nil && big.smoothed! > 90, "a very long step counts as the maximum step (smoothed \(big.smoothed ?? -1))")
    big.advance(dt: -5, input: artInput(cpu: 5))
    expect(big.smoothed != nil && big.smoothed! > 90, "a negative step moves nothing")

    section("DogRig.bubbleLayers")
    var pose = DogPose()
    pose.bubble = 1
    let glyph = DogArt.badge(.cpu)
    let whole = DogRig.layers(gait: .stand, pose: pose, glyph: glyph)
    let bubbles = DogRig.bubbleLayers(glyph: glyph, scale: 1)
    let tail = Array(whole.suffix(bubbles.count))
    var same = tail.count == bubbles.count
    for (a, b) in zip(tail, bubbles) where a.part.name != b.part.name || a.transform != b.transform { same = false }
    expect(same && !bubbles.isEmpty, "the bubble layers are the last layers of a frame with a bubble")
    expect(DogRig.bubbleLayers(glyph: nil, scale: 1).count == DogArt.overlay(.bubble).count, "no glyph: only the bubble parts")
}
