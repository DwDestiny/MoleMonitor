// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The whole-machine CPU percent of each engine tick, the motion conditions, the icon state (docs/DESIGN_V3.md 4.2).
// Output: The menu bar runner: poses (stand, 4 run frames), the side-view Bichon silhouette of each pose as simple
//         shapes (24 x 18 pt, y down), the run hysteresis (start at >= 35 %, stop after 2 ticks < 25 %), the three
//         speed tiers (4, 6, 8 fps), the motion conditions, the "CPU busy" text suffix, and a coverage raster for tests.
// Pos: Pure logic and geometry, Foundation only, tested on Linux (Tests/CoreTests/MenuRunnerTests.swift). The App draws
//      the shapes (Sources/App/MenuRunnerShapes.swift) and owns the one run timer (Sources/App/StatusIcon.swift).
//      v3 (U10, 2026-10-18): replaces the v2 head postures and the switch animation of the menu bar icon.

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

/// The silhouette of one pose: `fill` shapes in the ink, then `cut` shapes cleared (the eye).
struct MenuRunnerFigure: Equatable {
    var fill: [MenuRunnerShape]
    var cut: [MenuRunnerShape]
    /// Vertical body offset of this pose, pt (positive is down).
    var bob: Double
    /// The leg shapes (also in `fill`), for the leg checks.
    var legs: [MenuRunnerShape]
}

/// Side-view Bichon facing left (DESIGN_V3.md 4.2): a big round head with a small muzzle and a cut-out eye, a curly
/// body (an ellipse with a neck fluff, three bumps on the back and three under the belly), a tail ball on a thick short
/// stalk raised above the back, four short legs (round-ended lines; the far leg of each pair sits 1.5 pt behind and,
/// standing, 0.3 pt shorter, so each pair shows a small step). The mark box (bottom right)
/// stays clear of the dog in every pose.
enum MenuRunnerArt {
    static let width = 24.0
    static let height = 18.0
    /// The health mark (▲ or ■) and the data mark sit in this box, bottom right.
    static let markOrigin = (x: 17.5, y: 11.5)
    static let markSize = 6.5
    /// Clear ring around the mark, pt.
    static let markGap = 0.75

    static let legRadius = 0.95
    static let farOffset = 1.5
    static let frontHip = (x: 8.4, y: 12.2)
    static let hindHip = (x: 12.4, y: 12.2)

    /// Head, muzzle, neck fluff, body puff, tail plume.
    static let torso: [MenuRunnerShape] = [
        .circle(x: 5.0, y: 5.6, r: 4.4),
        .circle(x: 1.65, y: 7.4, r: 1.6),
        .circle(x: 7.6, y: 8.0, r: 2.0),
        .ellipse(x: 11.8, y: 10.6, rx: 4.6, ry: 3.2),
        .circle(x: 9.8, y: 8.2, r: 2.1), .circle(x: 12.6, y: 7.8, r: 2.1), .circle(x: 15.2, y: 8.8, r: 1.9),
        .circle(x: 8.6, y: 11.2, r: 2.2), .circle(x: 11.6, y: 12.4, r: 1.7), .circle(x: 14.6, y: 11.8, r: 1.9),
        .capsule(x0: 15.0, y0: 8.6, x1: 16.3, y1: 6.6, r: 1.25),
        .circle(x: 17.2, y: 4.8, r: 2.4),
    ]
    static let eye: MenuRunnerShape = .circle(x: 3.5, y: 5.0, r: 0.8)

    /// One leg: angle in degrees from straight down, positive swings the foot forward (left).
    struct Leg: Equatable {
        var angle: Double
        var length: Double
    }

    /// Leg angles of a pose: front near, front far, hind near, hind far; and the body offset.
    struct Pose: Equatable {
        var frontNear: Leg
        var frontFar: Leg
        var hindNear: Leg
        var hindFar: Leg
        var bob: Double
    }

    static func pose(_ p: MenuRunPose) -> Pose {
        func l(_ a: Double, _ len: Double) -> Leg { Leg(angle: a, length: len) }
        switch p {
        case .stand:
            return Pose(frontNear: l(0, 4.8), frontFar: l(0, 4.5), hindNear: l(0, 4.8), hindFar: l(0, 4.5), bob: 0)
        case .run(let i):
            switch ((i % MenuRunPose.runFrameCount) + MenuRunPose.runFrameCount) % MenuRunPose.runFrameCount {
            case 0:   // Reach: front legs stretched forward, hind legs under the body.
                return Pose(frontNear: l(55, 4.8), frontFar: l(42, 4.8), hindNear: l(12, 4.6), hindFar: l(0, 4.6), bob: 0)
            case 1:   // Gather: short bent legs under the body, feet off the ground.
                return Pose(frontNear: l(-20, 3.8), frontFar: l(10, 3.8), hindNear: l(22, 3.8), hindFar: l(-8, 3.8), bob: 0)
            case 2:   // Push: hind legs kick back, front legs folded up.
                return Pose(frontNear: l(78, 3.0), frontFar: l(64, 3.0), hindNear: l(-36, 4.6), hindFar: l(-22, 4.6), bob: 0.5)
            default:  // Flight: front forward, hind back, body up.
                return Pose(frontNear: l(42, 4.2), frontFar: l(30, 4.2), hindNear: l(-44, 4.0), hindFar: l(-26, 4.0), bob: -0.5)
            }
        }
    }

    static func leg(hip: (x: Double, y: Double), dx: Double, _ leg: Leg, bob: Double) -> MenuRunnerShape {
        let a = leg.angle * Double.pi / 180
        let x0 = hip.x + dx, y0 = hip.y + bob
        return .capsule(x0: x0, y0: y0, x1: x0 - leg.length * sin(a), y1: y0 + leg.length * cos(a), r: legRadius)
    }

    static func figure(_ p: MenuRunPose) -> MenuRunnerFigure {
        let q = pose(p)
        let legs = [
            leg(hip: frontHip, dx: farOffset, q.frontFar, bob: q.bob),
            leg(hip: hindHip, dx: farOffset, q.hindFar, bob: q.bob),
            leg(hip: frontHip, dx: 0, q.frontNear, bob: q.bob),
            leg(hip: hindHip, dx: 0, q.hindNear, bob: q.bob),
        ]
        return MenuRunnerFigure(fill: torso.map { $0.moved(dy: q.bob) } + legs, cut: [eye.moved(dy: q.bob)], bob: q.bob, legs: legs)
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
