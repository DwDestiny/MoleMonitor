// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: CPU percent, thermal state and health levels over time (docs/DESIGN.md 4.3 to 4.7, 8.1).
// Output: DogPose values (part transform parameters per frame) and the transformed layer list of one frame.
// Pos: Pure animation math. It never creates shapes; those come from DogArt. Foundation only. Owner I2.
//
// Angle conventions (degrees): legAngle > 0 swings the paw forward. earAngle < 0 lifts the ear tip.
// tailAngle < 0 lowers the plume backward. bodyPitch > 0 leans the nose down. headTilt > 0 lifts the nose (curious).

import Foundation

enum DogGait: String, CaseIterable { case lie, stand, walk, trot, sprint }

struct DogInput: Equatable {
    var cpuPercent: Double?
    var thermal: ThermalLevel?
    var memoryLevel: HealthLevel
    var worstProblem: HealthItem?
    var worstLevel: HealthLevel
    /// Collecting or stale: the dog stands still and gray. DogView reads Reduce Motion itself (DESIGN.md 8.1).
    var isStatic: Bool
}

struct DogPose: Equatable {
    var bodyY = 0.0, bodyPitch = 0.0, breath = 0.0, headY = 0.0, headTilt = 0.0, earAngle = 0.0, tailAngle = 0.0
    var legAngle: [Double] = [0, 0, 0, 0]      // 4 items: far hind, far fore, near hind, near fore
    var legLift: [Double] = [0, 0, 0, 0]       // 4 items
    var mouthOpen = 0.0, tongue = 0.0, eyesClosed = 0.0, bundle = 0.0, bubble = 0.0, speedLines = 0.0
    var opacity = 1.0
}

// MARK: - Gait rules (DESIGN.md 4.5)

enum DogGaitRules {
    static let tau = 8.0                  // Smoothing time constant, s
    static let minHold = 4.0              // Minimum time in one gait, s
    static let switchWindow = 10.0        // At most `maxSwitches` switches in this window, s
    static let maxSwitches = 2
    static let maxFrequencySlope = 0.6    // Hz per s
    /// Enter (going up) and leave (going down) thresholds for walk, trot and sprint.
    static let enter: [DogGait: Double] = [.walk: 10, .trot: 40, .sprint: 80]
    static let leave: [DogGait: Double] = [.walk: 7, .trot: 34, .sprint: 72]
    static let frequencyRange: [DogGait: (lo: Double, hi: Double)] = [.walk: (0.8, 1.4), .trot: (1.6, 2.4), .sprint: (2.8, 3.6)]
    static let moving: [DogGait] = [.lie, .walk, .trot, .sprint]

    static func rank(_ g: DogGait) -> Int {
        switch g {
        case .lie, .stand: return 0
        case .walk: return 1
        case .trot: return 2
        case .sprint: return 3
        }
    }

    /// Gait for a smoothed CPU value without history (first value, or the static frame).
    static func plainGait(_ s: Double) -> DogGait {
        if s >= 80 { return .sprint }
        if s >= 40 { return .trot }
        if s >= 10 { return .walk }
        return .lie
    }

    /// Next gait with hysteresis: up at the enter value, down below the leave value. May skip levels.
    static func nextGait(from current: DogGait, s: Double) -> DogGait {
        if current == .stand { return plainGait(s) }
        var r = rank(current)
        while r < 3, s >= enter[moving[r + 1]]! { r += 1 }
        while r > 0, s < leave[moving[r]]! { r -= 1 }
        return moving[r]
    }

    /// Continuous step frequency inside a gait, Hz. Lie and stand do not step.
    static func frequency(_ g: DogGait, s: Double) -> Double {
        guard let range = frequencyRange[g], let lo = enter[g] else { return 0 }
        let hi: Double
        switch g {
        case .walk: hi = 40
        case .trot: hi = 80
        default: hi = 100
        }
        let t = min(max((s - lo) / (hi - lo), 0), 1)
        return range.lo + (range.hi - range.lo) * t
    }
}

// MARK: - Motor

struct DogMotor {
    private(set) var gait: DogGait
    private(set) var smoothed: Double?
    private(set) var frequency = 0.0
    private(set) var phase = 0.0
    private(set) var time = 0.0
    private var lastSwitch = -Double.infinity
    private var switchTimes = [Double]()
    private var previousGait: DogGait?
    private var blendStart = 0.0
    private var blendDuration = 0.35

    init(initialCPU: Double?) {
        smoothed = initialCPU
        if let s = initialCPU {
            gait = DogGaitRules.plainGait(s)
            frequency = DogGaitRules.frequency(gait, s: s)
        } else {
            gait = .stand
        }
    }

    /// Advances time by `dt` seconds with the newest input and returns the pose of this frame.
    mutating func step(dt: Double, input: DogInput) -> DogPose {
        let dt = max(0, min(dt, 1))
        time += dt
        if input.isStatic { return DogMotor.staticPose(gait: .stand, input: input) }

        if let x = input.cpuPercent {
            if let s = smoothed {
                let alpha = 1 - exp(-dt / DogGaitRules.tau)
                smoothed = s + alpha * (x - s)
            } else {
                smoothed = x
            }
        }
        if let s = smoothed {
            let wanted = DogGaitRules.nextGait(from: gait, s: s)
            switchTimes = switchTimes.filter { time - $0 < DogGaitRules.switchWindow }
            let firstValue = (gait == .stand)
            let held = time - lastSwitch >= DogGaitRules.minHold
            if wanted != gait, firstValue || (held && switchTimes.count < DogGaitRules.maxSwitches) {
                previousGait = gait
                blendStart = time
                let lieChange = (gait == .lie) != (wanted == .lie)
                blendDuration = lieChange ? 0.6 : 0.35
                gait = wanted
                lastSwitch = time
                switchTimes.append(time)
            }
        }

        let load = (input.memoryLevel == .red) ? 0.85 : 1.0
        let target = DogGaitRules.frequency(gait, s: smoothed ?? 0) * load
        let maxStep = DogGaitRules.maxFrequencySlope * dt
        frequency += min(max(target - frequency, -maxStep), maxStep)
        phase += 2 * Double.pi * frequency * dt
        if phase > 2000 * Double.pi { phase -= 2000 * Double.pi }   // Keeps precision; a whole number of cycles

        var pose = DogMotor.gaitPose(gait, phase: phase, time: time, load: load)
        if let from = previousGait {
            let k = (time - blendStart) / blendDuration
            if k >= 1 {
                previousGait = nil
            } else {
                let old = DogMotor.gaitPose(from, phase: phase, time: time, load: load)
                pose = DogMotor.blend(old, pose, smoothstep(k))
            }
        }
        return DogMotor.applyOverlays(pose, input: input, time: time, animated: true)
    }

    /// Static pose: phase = pi / 2. For Reduce Motion and the gallery.
    static func staticPose(gait: DogGait, input: DogInput) -> DogPose {
        if input.isStatic {
            var pose = gaitPose(.stand, phase: Double.pi / 2, time: 0, load: 1)
            pose.tailAngle = 0
            pose.breath = 0
            pose.opacity = 0.45
            return pose
        }
        let load = (input.memoryLevel == .red) ? 0.85 : 1.0
        var pose = gaitPose(gait, phase: Double.pi / 2, time: 0, load: load)
        pose.breath = 0
        return applyOverlays(pose, input: input, time: 0, animated: false)
    }

    /// The gait the motor would show for a fixed input (the gallery and the first frame).
    static func staticGait(for input: DogInput) -> DogGait {
        guard !input.isStatic, let cpu = input.cpuPercent else { return .stand }
        return DogGaitRules.plainGait(cpu)
    }

    // MARK: Pose math (DESIGN.md 4.4)

    /// Pure gait pose at phase `phase` (radians) and time `time` (s). `load` is 0.85 with the bundle.
    static func gaitPose(_ gait: DogGait, phase: Double, time t: Double, load: Double) -> DogPose {
        var p = DogPose()
        let tau = 2 * Double.pi
        func legs(_ amp: Double, _ offsets: [Double], lift: Double) {
            for i in 0..<4 {
                let a = phase + tau * offsets[i]
                p.legAngle[i] = amp * load * sin(a)
                p.legLift[i] = lift * max(0, cos(a))
            }
        }
        switch gait {
        case .lie:
            p.breath = 0.025 * sin(tau * t / 2.0)
            p.tailAngle = 3 * sin(tau * 0.5 * t)
            p.eyesClosed = 0.6
        case .stand:
            p.breath = 0.012 * sin(tau * t / 2.5)
            p.tailAngle = 6 * sin(tau * 1.2 * t)
        case .walk:
            legs(16, [0, 0.25, 0.5, 0.75], lift: 0.08)
            p.bodyY = -0.8 * abs(sin(2 * phase))
            p.headY = -0.5 * abs(sin(2 * (phase - tau * 0.1)))
            p.tailAngle = 8 * sin(phase)
        case .trot:
            legs(26, [0, 0.5, 0.5, 0], lift: 0.15)
            p.bodyY = -1.6 * abs(sin(phase))
            p.earAngle = 8 * sin(phase - tau * 0.15)
            p.tailAngle = 10 + 6 * sin(phase)
        case .sprint:
            legs(40, [0.5, 0, 0.58, 0.08], lift: 0.2)
            p.bodyPitch = 5 * sin(phase)
            p.bodyY = -2.5 * abs(sin(phase))
            p.earAngle = -30 + 5 * sin(phase - tau * 0.15)
            p.tailAngle = -20
            p.speedLines = 1
        }
        return p
    }

    /// Thermal pant, memory bundle and the attention bubble on top of the gait pose.
    static func applyOverlays(_ base: DogPose, input: DogInput, time t: Double, animated: Bool) -> DogPose {
        var p = base
        let tau = 2 * Double.pi
        if input.memoryLevel == .red {
            // bundle > 0 shows the pack. Its scale is 0.96 + 0.04 x bundle: it puffs by 4 % on a 1.6 s cycle.
            p.bundle = animated ? max(0.01, 0.5 + 0.5 * cos(tau * t / 1.6)) : 1
            p.bodyY += 2
        }
        if input.thermal == .serious || input.thermal == .critical {
            p.mouthOpen = 1
            p.tongue = animated ? 8 + sin(tau * 2.5 * t) : 8
            p.breath = animated ? 0.03 * sin(tau * 2.5 * t) : 0
            p.eyesClosed = min(p.eyesClosed, 0.2)
        }
        if input.worstProblem != nil, input.worstLevel == .yellow || input.worstLevel == .red {
            p.earAngle += -25
            p.headTilt = 8
            p.bubble = 1
        }
        return p
    }

    static func blend(_ a: DogPose, _ b: DogPose, _ k: Double) -> DogPose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var p = DogPose()
        p.bodyY = m(a.bodyY, b.bodyY); p.bodyPitch = m(a.bodyPitch, b.bodyPitch); p.breath = m(a.breath, b.breath)
        p.headY = m(a.headY, b.headY); p.headTilt = m(a.headTilt, b.headTilt)
        p.earAngle = m(a.earAngle, b.earAngle); p.tailAngle = m(a.tailAngle, b.tailAngle)
        p.legAngle = (0..<4).map { m(a.legAngle[$0], b.legAngle[$0]) }
        p.legLift = (0..<4).map { m(a.legLift[$0], b.legLift[$0]) }
        p.mouthOpen = m(a.mouthOpen, b.mouthOpen); p.tongue = m(a.tongue, b.tongue); p.eyesClosed = m(a.eyesClosed, b.eyesClosed)
        p.bundle = m(a.bundle, b.bundle); p.bubble = m(a.bubble, b.bubble); p.speedLines = m(a.speedLines, b.speedLines)
        p.opacity = m(a.opacity, b.opacity)
        return p
    }
}

func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Layers of one frame

/// A 2D affine transform, CGAffineTransform layout: x' = a x + c y + tx, y' = b x + d y + ty. y down.
struct DogAffine: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    static let identity = DogAffine()

    static func translate(_ x: Double, _ y: Double) -> DogAffine { DogAffine(tx: x, ty: y) }

    /// Rotation by `degrees` about `p`. Positive turns clockwise on screen (y down).
    static func rotate(_ degrees: Double, about p: (x: Double, y: Double)) -> DogAffine {
        let r = degrees * Double.pi / 180
        let cs = cos(r), sn = sin(r)
        return DogAffine(a: cs, b: sn, c: -sn, d: cs, tx: p.x - cs * p.x + sn * p.y, ty: p.y - sn * p.x - cs * p.y)
    }

    static func scale(_ sx: Double, _ sy: Double, about p: (x: Double, y: Double)) -> DogAffine {
        DogAffine(a: sx, d: sy, tx: p.x - sx * p.x, ty: p.y - sy * p.y)
    }

    /// Applies `self`, then `next`.
    func then(_ n: DogAffine) -> DogAffine {
        DogAffine(a: a * n.a + b * n.c, b: a * n.b + b * n.d, c: c * n.a + d * n.c, d: c * n.b + d * n.d,
                  tx: tx * n.a + ty * n.c + n.tx, ty: tx * n.b + ty * n.d + n.ty)
    }

    func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }
}

/// One part of one frame: the art, its transform and its opacity.
struct DogLayer {
    var part: DogPart
    var transform: DogAffine
    var alpha: Double
}

enum DogRig {
    static let legNames = ["leg.farHind", "leg.farFore", "leg.nearHind", "leg.nearFore"]

    /// Which body art a gait uses.
    static func body(for gait: DogGait) -> DogBasePose {
        switch gait {
        case .lie: return .lie
        case .stand, .walk: return .stand
        case .trot, .sprint: return .trot
        }
    }

    /// Which head art a pose uses.
    static func head(for gait: DogGait, pose: DogPose) -> DogHeadVariant {
        if pose.mouthOpen >= 0.5 { return .pant }
        return (gait == .trot || gait == .sprint) ? .open : .smile
    }

    /// All layers of one frame in drawing order. `glyph` is the bubble glyph art (DogArt.badge), or nil.
    static func layers(gait: DogGait, pose: DogPose, glyph: [DogPart]? = nil) -> [DogLayer] {
        let bodyArt = body(for: gait)
        let headArt = head(for: gait, pose: pose)
        let lie = (bodyArt == .lie)
        let center: (x: Double, y: Double) = lie ? (52, 70) : (55, 55)
        let base = DogAffine.rotate(pose.bodyPitch, about: center).then(.translate(0, pose.bodyY))
        let headPivot: (x: Double, y: Double) = lie ? (80, 65) : (80, 45)
        let head = DogAffine.rotate(-pose.headTilt, about: headPivot).then(.translate(0, pose.headY)).then(base)
        var out = [DogLayer]()

        func add(_ part: DogPart, _ t: DogAffine, _ alpha: Double = 1) {
            out.append(DogLayer(part: part, transform: t, alpha: alpha * pose.opacity))
        }
        for part in DogArt.parts(body: bodyArt, head: headArt) {
            let n = part.name
            if n == "shadow" {
                let sx = 1 + max(-0.1, min(0.05, pose.bodyY * 0.04))
                add(part, .scale(sx, 1, about: part.pivot))
            } else if let i = legNames.firstIndex(of: n) {
                let t = DogAffine.scale(1, 1 - pose.legLift[i], about: part.pivot)
                    .then(.rotate(-pose.legAngle[i], about: part.pivot)).then(base)
                add(part, t)
            } else if n == "tail" {
                add(part, DogAffine.rotate(pose.tailAngle, about: part.pivot).then(base))
            } else if n == "body" {
                let s = 1 + pose.breath
                add(part, DogAffine.scale(1 + pose.breath * 0.3, s, about: part.pivot).then(base))
            } else if n == "head.ear" {
                add(part, DogAffine.rotate(-pose.earAngle, about: part.pivot).then(head))
            } else if n.hasPrefix("head.eye") {
                let closed = max(0, min(1, pose.eyesClosed))
                let t = DogAffine.scale(1, 1 - 0.75 * closed, about: part.pivot).then(head)
                add(part, t, n.hasSuffix(".hi") ? max(0, 1 - 1.6 * closed) : 1)
            } else if n.hasPrefix("head.tongue"), headArt == .pant {
                let k = max(0.2, pose.tongue / 8)
                add(part, DogAffine.scale(1, k, about: part.pivot).then(head))
            } else if n.hasPrefix("head") {
                add(part, head)
            } else {
                add(part, base)
            }
        }
        if pose.bundle > 0 {
            for part in DogArt.overlay(.bundle) {
                let s = 0.96 + 0.04 * min(1, pose.bundle)
                add(part, DogAffine.scale(s, s, about: part.pivot).then(base))
            }
        }
        if headArt == .pant {
            for part in DogArt.overlay(.heat) { add(part, head, 1) }
        }
        if pose.speedLines > 0 {
            for part in DogArt.overlay(.speed) { add(part, .identity, pose.speedLines) }
        }
        if pose.bubble > 0 {
            let k = min(1, pose.bubble)
            for part in DogArt.overlay(.bubble) {
                add(part, .scale(k, k, about: part.pivot))
            }
            if let glyph {
                let f = DogArt.bubbleGlyphFrame
                let pivot = DogArt.overlay(.bubble).last?.pivot ?? (108.5, 9.5)
                let place = DogAffine.scale(f.size / DogArt.badgeSize, f.size / DogArt.badgeSize, about: (0, 0))
                    .then(.translate(f.x, f.y)).then(.scale(k, k, about: pivot))
                for part in glyph {
                    var g = part
                    g.name = "glyph." + part.name
                    add(g, place)
                }
            }
        }
        return out
    }
}
