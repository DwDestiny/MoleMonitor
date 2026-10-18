// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Helpers (expect, section) defined in main.swift; MenuRunner.swift.
// Output: Assertions for the menu bar runner (docs/DESIGN_V3.md 4.2, gates W29 and W30 on the Core side): the hysteresis
//         (start >= 35 %, stop after 2 ticks < 25 %), the speed tiers, the motion conditions, the busy text, and the
//         silhouette (inside the canvas, mark box clear, bob <= 1 pt, the 4 run frames differ in the leg band).
// Pos: Called from main.swift via runMenuRunnerTests(); no top-level code in this file. Owner P-icon (v3).

import Foundation

func runMenuRunnerTests() {
    section("MenuRunnerTests")

    // Speed tiers: only three, at 35 to 60, 60 to 85, >= 85.
    expect(MenuRunSpeed.allCases.map(\.fps) == [4, 6, 8], "three speed tiers 4, 6, 8 fps")
    expect(MenuRunLogic.speed(cpu: 35) == .slow && MenuRunLogic.speed(cpu: 59.9) == .slow, "35 to 60 %: 4 fps")
    expect(MenuRunLogic.speed(cpu: 60) == .medium && MenuRunLogic.speed(cpu: 84.9) == .medium, "60 to 85 %: 6 fps")
    expect(MenuRunLogic.speed(cpu: 85) == .fast && MenuRunLogic.speed(cpu: 100) == .fast && MenuRunLogic.speed(cpu: 400) == .fast,
           ">= 85 %: 8 fps")
    expect(abs(MenuRunSpeed.fast.interval - 0.125) < 1e-9 && abs(MenuRunSpeed.slow.tolerance - 0.05) < 1e-9,
           "interval 1/fps, tolerance 20 %")
    expect(MenuRunSpeed.allCases.allSatisfy { $0.fps <= 8 }, "never above 8 Hz")

    // Hysteresis.
    func run(_ values: [Double?]) -> [MenuRunState] {
        var s = MenuRunState()
        return values.map { s = MenuRunLogic.next(s, cpu: $0); return s }
    }
    expect(run([34.9]).last?.running == false, "34.9 % does not start")
    expect(run([35]).last == MenuRunState(running: true, calmTicks: 0, speed: .slow), "35 % starts at 4 fps")
    expect(run([90]).last?.speed == .fast, "90 % starts at 8 fps")
    expect(run([40, 20]).last?.running == true, "one tick < 25 % keeps running")
    expect(run([40, 20, 20]).last == MenuRunState(), "two ticks < 25 % in a row stop")
    expect(run([40, 20, 30, 20]).last?.running == true, "a tick at >= 25 % resets the calm count")
    expect(run([40, 20, 30, 20, 20]).last?.running == false, "then two more calm ticks stop")
    expect(run([40, 30, 30, 30]).last?.running == true, "25 to 35 % keeps running")
    expect(run([40, 30]).last?.speed == .slow, "25 to 35 % while running: 4 fps")
    expect(run([40, 70]).last?.speed == .medium && run([40, 70, 95]).last?.speed == .fast && run([95, 50]).last?.speed == .slow,
           "speed follows the latest tick")
    expect(run([40, nil, nil, nil]).last?.running == true, "a tick without a CPU value changes nothing")
    expect(run([40, 20, nil, 20]).last?.running == false, "a tick without a value does not reset the calm count")
    expect(run([30, 30, 34]).allSatisfy { !$0.running }, "below 35 % never starts")
    expect(run([Double.nan]).last == MenuRunState(), "NaN changes nothing")

    // Conditions: each one alone stops the motion.
    let fresh = MenuIconState(posture: .relaxed, badge: nil)
    let running = MenuRunState(running: true, calmTicks: 0, speed: .fast)
    expect(MenuRunLogic.animates(running, state: fresh, conditions: MenuMotionConditions()), "running, fresh, all clear: animates")
    expect(!MenuRunLogic.animates(MenuRunState(), state: fresh, conditions: MenuMotionConditions()), "not running: still")
    var each = [MenuMotionConditions]()
    for k in 0..<5 {
        var c = MenuMotionConditions()
        switch k {
        case 0: c.reduceMotion = true
        case 1: c.screenLocked = true
        case 2: c.displayAsleep = true
        case 3: c.iconVisible = false
        default: c.lowPower = true
        }
        each.append(c)
    }
    expect(each.allSatisfy { !MenuRunLogic.animates(running, state: fresh, conditions: $0) },
           "Reduce Motion, locked, display asleep, hidden, low power: still")
    for mark in MenuMark.allCases {
        let s = MenuIconState(posture: .hollow, badge: nil, mark: mark)
        expect(!MenuRunLogic.animates(running, state: s, conditions: MenuMotionConditions()), "\(mark.rawValue): never runs")
    }
    expect(MenuRunLogic.animates(running, state: MenuIconState(posture: .pant, badge: MenuBadge(item: .disk)),
                                 conditions: MenuMotionConditions()), "a health mark does not stop the run")
    expect(!MenuRunLogic.animates(running, state: nil, conditions: MenuMotionConditions()), "no state yet: still")

    // Text.
    expect(MenuRunLogic.text("MoleMonitor：一切正常。CPU 正常。", running: true) == "MoleMonitor：一切正常。CPU 正常，CPU 占用高。",
           "busy suffix before the last full stop")
    expect(MenuRunLogic.text("MoleMonitor：一切正常", running: true) == "MoleMonitor：一切正常，CPU 占用高", "busy suffix at the end")
    expect(MenuRunLogic.text("abc。", running: false) == "abc。", "standing: text unchanged")

    // Silhouette.
    expect(MenuRunPose.all.count == 5 && MenuRunPose.runFrames.count == 4, "1 stand frame and 4 run frames")
    let mark = (x: MenuRunnerArt.markOrigin.x - MenuRunnerArt.markGap, y: MenuRunnerArt.markOrigin.y - MenuRunnerArt.markGap)
    expect(MenuRunnerArt.markOrigin.x + MenuRunnerArt.markSize <= 24 && MenuRunnerArt.markOrigin.y + MenuRunnerArt.markSize <= 18,
           "mark box inside the canvas")
    var bobs = [Double]()
    for p in MenuRunPose.all {
        let f = MenuRunnerArt.figure(p)
        bobs.append(f.bob)
        let inside = f.fill.allSatisfy { s in
            let b = s.bounds
            return b.0 >= 0 && b.1 >= 0 && b.2 <= MenuRunnerArt.width && b.3 <= MenuRunnerArt.height
        }
        expect(inside, "\(p): every shape inside 24 x 18 pt")
        // The mark box and its clear ring stay free of the dog (sampled every 0.25 pt).
        var hit = false
        var y = mark.y
        while y <= 18 {
            var x = mark.x
            while x <= 24 {
                if f.fill.contains(where: { $0.contains(x, y) }) { hit = true }
                x += 0.25
            }
            y += 0.25
        }
        expect(!hit, "\(p): the mark box is clear of the dog")
        let g = MenuRunnerArt.alphaGrid(p, scale: 1)
        let solid = g.joined().filter { $0 >= 0.5 }.count
        expect(solid >= 120, "\(p): \(solid) solid px at 1x")
        expect(f.legs.count == 2, "\(p): two leg columns (front pair, hind pair)")
        // Legs about 1/4 of the canvas height: each column reaches at most 6 pt below its hip.
        expect(f.legs.allSatisfy { $0.bounds.3 - $0.bounds.1 <= 7.5 }, "\(p): short leg columns")
    }
    // The tail ball sits on the back: no higher than the top of the head, and it overlaps a back shape (no stalk).
    let tailTop = MenuRunnerArt.tail.bounds.1, headTop = MenuRunnerArt.head.bounds.1
    expect(tailTop >= headTop, "tail ball top \(tailTop) not above head top \(headTop)")
    if case let .circle(tx, ty, tr) = MenuRunnerArt.tail {
        let touches = MenuRunnerArt.torso.contains { s in
            s != MenuRunnerArt.tail && s.contains(tx - tr * 0.8, ty + tr * 0.6)
        }
        expect(touches, "tail ball lower front overlaps the back (no stalk)")
    } else {
        expect(false, "tail ball is a circle")
    }
    expect(!MenuRunnerArt.torso.contains { if case .capsule = $0 { return true } else { return false } },
           "no stalk shapes in the torso")
    // The ear gap cuts into the head (a drooping ear, not an upward dot): every gap stroke starts below the head top.
    expect(MenuRunnerArt.earGap.count >= 2 && MenuRunnerArt.earGap.allSatisfy { $0.bounds.1 > headTop + 2 },
           "drooping ear gap inside the head")
    // The head is the biggest round shape.
    if case let .circle(_, _, hr) = MenuRunnerArt.head, case let .circle(_, _, tr) = MenuRunnerArt.tail {
        expect(hr > tr * 2, "head radius \(hr) > 2 x tail radius")
    }
    expect((bobs.max() ?? 0) - (bobs.min() ?? 0) <= 1.0 + 1e-9, "body bob range <= 1 pt")
    expect(MenuRunnerArt.figure(.stand).bob == 0, "stand frame has no bob")
    // Standing feet are on the ground line (bottom of the round end at y 17.6 to 18).
    let standFeet = MenuRunnerArt.figure(.stand).legs.map { $0.bounds.3 }
    expect(standFeet.allSatisfy { $0 >= 17.6 && $0 <= 18 }, "stand: both leg columns on the ground")

    // The 4 run frames differ pairwise in the leg band (rows below the belly, 2x) by at least 30 % (the W29 gate). The
    // Q4 redraw reaches about 0.8; the Core floor below is 0.6 so a later edit cannot silently flatten the gait.
    let band = 28..<36   // y 14 to 18 pt at 2x (below the belly)
    let grids = MenuRunPose.runFrames.map { ($0.description, Array(MenuRunnerArt.alphaGrid($0, scale: 2)[band])) }
    let m = IconMetrics.matrix(grids)
    print("  run leg band pairs: " + m.pairs.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", "))
    expect(m.minimum >= 0.30, "run frames leg band pairwise XOR min \(String(format: "%.3f", m.minimum)) >= 0.30")
    expect(m.minimum >= 0.60, "run frames leg band pairwise XOR min \(String(format: "%.3f", m.minimum)) >= 0.60 (Core floor)")
    let standVsRun = MenuRunPose.runFrames.map {
        IconMetrics.xorRatio(Array(MenuRunnerArt.alphaGrid(.stand, scale: 2)[band]), Array(MenuRunnerArt.alphaGrid($0, scale: 2)[band]))
    }
    expect((standVsRun.min() ?? 0) >= 0.30, "stand differs from each run frame in the leg band: " + standVsRun.map { String(format: "%.2f", $0) }.joined(separator: " "))
}
