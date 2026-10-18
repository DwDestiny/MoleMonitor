// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The whole-machine CPU percent of each engine tick, the motion conditions, the icon state (docs/DESIGN_V3.md 4.2).
// Output: The menu bar runner: poses (stand, 4 run frames), the side-view Bichon silhouette of each pose as simple
//         shapes (24 x 18 pt, y down), the run hysteresis (start at >= 35 %, stop after 2 ticks < 25 %), the three
//         speed tiers (4, 6, 8 fps), the motion conditions, the "CPU busy" text suffix, and a coverage raster for tests.
// Pos: Pure logic and geometry, Foundation only, tested on Linux (Tests/CoreTests/MenuRunnerTests.swift). The App draws
//      the shapes (Sources/App/MenuRunnerShapes.swift) and owns the one run timer (Sources/App/StatusIcon.swift).
//      v3 (U10, 2026-10-18): replaces the v2 head postures and the switch animation of the menu bar icon. Redrawn the
//      same day (Q4): tail ball on the back, two short leg columns, drooping ear, so it reads as a Bichon.

import Foundation

/// The pose of the menu bar runner: the standing frame, or run frame 0 to 3 (reach, gather, push, flight).
enum MenuRunPose: Hashable, CustomStringConvertible {
    case stand
    case run(Int)

    static let runFrameCount = 4
    static var runFrames: [MenuRunPose] { (0..<runFrameCount).map { .run($0) } }
    static var all: [MenuRunPose] { [.stand] + runFrames }

    var description: String {
        switch self {
        case .stand: return "stand"
        case .run(let i): return "run\(i)"
        }
    }
}

/// Run speed tiers (DESIGN_V3.md 4.2): 35 to 60 % 4 fps, 60 to 85 % 6 fps, >= 85 % 8 fps. Only these three.
enum MenuRunSpeed: Int, CaseIterable {
    case slow = 4, medium = 6, fast = 8

    var fps: Int { rawValue }
    /// Seconds between two frames (the timer interval).
    var interval: TimeInterval { 1 / Double(rawValue) }
    /// Timer tolerance: 20 % of the interval.
    var tolerance: TimeInterval { interval * 0.2 }
}

/// What forbids motion of the menu bar icon. Any one of them keeps the icon on the still frame with no timer.
struct MenuMotionConditions: Equatable {
    var reduceMotion = false
    var screenLocked = false
    var displayAsleep = false
    var iconVisible = true
    var lowPower = false

    var allowsMotion: Bool { !reduceMotion && !screenLocked && !displayAsleep && iconVisible && !lowPower }
}

/// The run state between engine ticks.
struct MenuRunState: Equatable {
    var running = false
    /// Consecutive ticks below `MenuRunLogic.stopPercent` while running.
    var calmTicks = 0
    /// The speed while running, nil while standing.
    var speed: MenuRunSpeed?
}

enum MenuRunLogic {
    static let startPercent = 35.0
    static let stopPercent = 25.0
    /// Ticks below `stopPercent` in a row before the runner stops (2 ticks of 30 s = 60 s).
    static let calmTicksToStop = 2
    static let mediumPercent = 60.0
    static let fastPercent = 85.0
    /// The text added to the tooltip and the VoiceOver label while the runner runs.
    static let busySuffix = "，CPU 占用高"

    static func speed(cpu: Double) -> MenuRunSpeed {
        if cpu >= fastPercent { return .fast }
        if cpu >= mediumPercent { return .medium }
        return .slow
    }

    /// The state after one engine tick. A tick without a CPU value changes nothing and does not count.
    static func next(_ s: MenuRunState, cpu: Double?) -> MenuRunState {
        guard let cpu, cpu.isFinite else { return s }
        var n = s
        if !s.running {
            guard cpu >= startPercent else { return MenuRunState() }
            n.running = true
            n.calmTicks = 0
            n.speed = speed(cpu: cpu)
            return n
        }
        if cpu < stopPercent {
            n.calmTicks += 1
            if n.calmTicks >= calmTicksToStop { return MenuRunState() }
        } else {
            n.calmTicks = 0
        }
        n.speed = speed(cpu: cpu)
        return n
    }

    /// True when the icon shows the run loop: running, fresh data (no collecting or stale mark), motion allowed.
    static func animates(_ s: MenuRunState, state: MenuIconState?, conditions: MenuMotionConditions) -> Bool {
        guard s.running, s.speed != nil, conditions.allowsMotion else { return false }
        guard let state else { return false }
        return state.mark == nil
    }

    /// Tooltip and VoiceOver text: the v2 text, plus "，CPU 占用高" at the end while the runner runs (before the last "。").
    static func text(_ base: String, running: Bool) -> String {
        guard running else { return base }
        if base.hasSuffix("。") { return String(base.dropLast()) + busySuffix + "。" }
        return base + busySuffix
    }
}

// MARK: - Silhouette

/// One shape of the silhouette, in pt, y down.
enum MenuRunnerShape: Equatable {
    case circle(x: Double, y: Double, r: Double)
    case ellipse(x: Double, y: Double, rx: Double, ry: Double)
    /// A line from (x0, y0) to (x1, y1) with round ends of radius r.
    case capsule(x0: Double, y0: Double, x1: Double, y1: Double, r: Double)

    func moved(dy: Double) -> MenuRunnerShape {
        switch self {
        case let .circle(x, y, r): return .circle(x: x, y: y + dy, r: r)
        case let .ellipse(x, y, rx, ry): return .ellipse(x: x, y: y + dy, rx: rx, ry: ry)
        case let .capsule(x0, y0, x1, y1, r): return .capsule(x0: x0, y0: y0 + dy, x1: x1, y1: y1 + dy, r: r)
        }
    }

    /// Bounding box (minX, minY, maxX, maxY).
    var bounds: (Double, Double, Double, Double) {
        switch self {
        case let .circle(x, y, r): return (x - r, y - r, x + r, y + r)
        case let .ellipse(x, y, rx, ry): return (x - rx, y - ry, x + rx, y + ry)
        case let .capsule(x0, y0, x1, y1, r): return (min(x0, x1) - r, min(y0, y1) - r, max(x0, x1) + r, max(y0, y1) + r)
        }
    }

    func contains(_ px: Double, _ py: Double) -> Bool {
        switch self {
        case let .circle(x, y, r):
            return (px - x) * (px - x) + (py - y) * (py - y) <= r * r
        case let .ellipse(x, y, rx, ry):
            let u = (px - x) / rx, v = (py - y) / ry
            return u * u + v * v <= 1
        case let .capsule(x0, y0, x1, y1, r):
            let dx = x1 - x0, dy = y1 - y0
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((px - x0) * dx + (py - y0) * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let cx = x0 + t * dx - px, cy = y0 + t * dy - py
            return cx * cx + cy * cy <= r * r
        }
    }
}

/// The silhouette of one pose: `fill` shapes in the ink, then `cut` shapes cleared (the eye and the ear gap).
struct MenuRunnerFigure: Equatable {
    var fill: [MenuRunnerShape]
    var cut: [MenuRunnerShape]
    /// Vertical body offset of this pose, pt (positive is down).
    var bob: Double
    /// The leg shapes (also in `fill`), for the leg checks.
    var legs: [MenuRunnerShape]
}

/// Side-view Bichon facing left (DESIGN_V3.md 4.2, review round 2 of U10): the head is the biggest round shape, with a
/// short muzzle, a cut-out eye and a drooping ear (an ear lobe on the side of the head, its front and lower edge cut as
/// a thin gap); a curly body (an ellipse with a chest fluff, three curls on the back and a rump curl); the tail ball sits
/// directly on the rear of the back (no stalk) and stays below the top of the head; two short fluffy leg columns (front
/// pair and hind pair, each one wide round-ended column, about 1/4 of the canvas height). The mark box (bottom right)
/// stays clear of the dog in every pose.
enum MenuRunnerArt {
    static let width = 24.0
    static let height = 18.0
    /// The health mark (▲ or ■) and the data mark sit in this box, bottom right.
    static let markOrigin = (x: 17.5, y: 11.5)
    static let markSize = 6.5
    /// Clear ring around the mark, pt.
    static let markGap = 0.75

    /// Half width of a leg column (front pair, hind pair).
    static let legRadius = 1.5
    static let frontHip = (x: 8.6, y: 12.0)
    static let hindHip = (x: 13.2, y: 12.0)

    static let head: MenuRunnerShape = .circle(x: 5.6, y: 6.3, r: 4.9)
    /// The tail ball, on the rear of the back (it overlaps the back curl, so no stalk).
    static let tail: MenuRunnerShape = .circle(x: 16.5, y: 6.0, r: 2.2)
    /// The ear lobe; its front and lower edge are cut by `earGap`.
    static let ear: MenuRunnerShape = .ellipse(x: 7.3, y: 8.2, rx: 1.8, ry: 3.1)

    /// Head, muzzle, chest fluff, body, back curls, rump curl, ear lobe, tail ball.
    static let torso: [MenuRunnerShape] = [
        head,
        .circle(x: 1.6, y: 8.3, r: 1.45),
        .circle(x: 7.8, y: 10.2, r: 2.6),
        .ellipse(x: 11.6, y: 10.0, rx: 4.8, ry: 3.3),
        .circle(x: 10.4, y: 7.2, r: 1.9), .circle(x: 12.8, y: 7.0, r: 2.0), .circle(x: 14.9, y: 7.9, r: 1.8),
        .circle(x: 15.3, y: 9.4, r: 1.5),
        ear,
        tail,
    ]
    static let eye: MenuRunnerShape = .circle(x: 3.4, y: 6.0, r: 0.75)
    /// The thin gap that draws the drooping ear: down from the top of the head, then back under the lobe.
    static let earGap: [MenuRunnerShape] = [
        .capsule(x0: 6.3, y0: 4.5, x1: 5.6, y1: 6.8, r: 0.3),
        .capsule(x0: 5.6, y0: 6.8, x1: 5.7, y1: 9.8, r: 0.3),
        .capsule(x0: 5.7, y0: 9.8, x1: 6.9, y1: 11.2, r: 0.3),
    ]

    /// One leg column: angle in degrees from straight down, positive swings the foot forward (left).
    struct Leg: Equatable {
        var angle: Double
        var length: Double
    }

    /// The front and hind leg columns of a pose, and the body offset.
    struct Pose: Equatable {
        var front: Leg
        var hind: Leg
        var bob: Double
    }

    static func pose(_ p: MenuRunPose) -> Pose {
        func l(_ a: Double, _ len: Double) -> Leg { Leg(angle: a, length: len) }
        switch p {
        case .stand:
            return Pose(front: l(0, 4.5), hind: l(0, 4.5), bob: 0)
        case .run(let i):
            switch ((i % MenuRunPose.runFrameCount) + MenuRunPose.runFrameCount) % MenuRunPose.runFrameCount {
            case 0:   // Reach: front column stretched forward, hind column forward under the body.
                return Pose(front: l(40, 4.2), hind: l(30, 3.8), bob: 0)
            case 1:   // Gather: both columns short and under the body, body up.
                return Pose(front: l(-6, 2.4), hind: l(24, 2.8), bob: -0.5)
            case 2:   // Push: both columns slant back, the hind one kicks, body down.
                return Pose(front: l(-28, 4.0), hind: l(-24, 3.4), bob: 0.5)
            default:  // Flight: front far forward, hind folded back, body up.
                return Pose(front: l(64, 4.0), hind: l(-50, 2.6), bob: -0.5)
            }
        }
    }

    static func leg(hip: (x: Double, y: Double), _ leg: Leg, bob: Double) -> MenuRunnerShape {
        let a = leg.angle * Double.pi / 180
        let x0 = hip.x, y0 = hip.y + bob
        return .capsule(x0: x0, y0: y0, x1: x0 - leg.length * sin(a), y1: y0 + leg.length * cos(a), r: legRadius)
    }

    static func figure(_ p: MenuRunPose) -> MenuRunnerFigure {
        let q = pose(p)
        let legs = [leg(hip: frontHip, q.front, bob: q.bob), leg(hip: hindHip, q.hind, bob: q.bob)]
        let cut = ([eye] + earGap).map { $0.moved(dy: q.bob) }
        return MenuRunnerFigure(fill: torso.map { $0.moved(dy: q.bob) } + legs, cut: cut, bob: q.bob, legs: legs)
    }

    /// Coverage raster of a pose (row 0 at the top): `scale` px per pt, 4 x 4 samples per px, values 0 to 1.
    static func alphaGrid(_ p: MenuRunPose, scale: Int) -> [[Double]] {
        let f = figure(p)
        let w = Int(width) * scale, h = Int(height) * scale
        let ss = 4
        var grid = [[Double]](repeating: [Double](repeating: 0, count: w), count: h)
        for y in 0..<h {
            for x in 0..<w {
                var hits = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let px = (Double(x) + (Double(sx) + 0.5) / Double(ss)) / Double(scale)
                        let py = (Double(y) + (Double(sy) + 0.5) / Double(ss)) / Double(scale)
                        if f.fill.contains(where: { $0.contains(px, py) }) && !f.cut.contains(where: { $0.contains(px, py) }) {
                            hits += 1
                        }
                    }
                }
                grid[y][x] = Double(hits) / Double(ss * ss)
            }
        }
        return grid
    }
}
