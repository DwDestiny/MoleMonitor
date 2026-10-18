// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: CPU percent, thermal state and health levels over time (docs/DESIGN.md 4.3 to 4.7, 8.1).
// Output: DogPose values (part transform parameters per frame) and the transformed layer list of one frame.
// Pos: Pure animation math. It never creates shapes; those come from DogArt. Foundation only. Owner I2.
//
// Angle conventions (degrees): legAngle > 0 swings the paw forward. earAngle < 0 lifts the ear tip.
// tailAngle < 0 lowers the plume backward. bodyPitch > 0 leans the nose down. headTilt > 0 lifts the nose (curious).
// Round 3 (I2): legLift is a distance in u (the paw rises off the ground); planted paws stay on the ground
// while the body bobs. The memory bundle is gone: memory red shows only through the bubble and the menu badge.
// Stage 2 (I2): DogMotor.frame(dt:input:) also returns the art crossfade of a gait switch (lie <-> stand body,
// stand <-> trot body) and pops the bubble once (spring 0.6 -> 1).
// Q4 (2026-10-18): MenuMotion and MenuIconFrame (the v2 menu bar switch animation) are deleted; MenuRunner.swift draws the icon.

import Foundation

enum DogGait: String, CaseIterable { case lie, stand, walk, trot, sprint }

struct DogInput: Equatable {
    var cpuPercent: Double?
    var thermal: ThermalLevel?
    /// Kept for the callers; the dog does not read it since round 3 (no bundle, no slower steps).
    var memoryLevel: HealthLevel
    var worstProblem: HealthItem?
    var worstLevel: HealthLevel
    /// Collecting or stale: the dog stands still and gray. DogView reads Reduce Motion itself (DESIGN.md 8.1).
    var isStatic: Bool
}

struct DogPose: Equatable {
    var bodyY = 0.0, bodyPitch = 0.0, breath = 0.0, headY = 0.0, headTilt = 0.0, earAngle = 0.0, tailAngle = 0.0
    var legAngle: [Double] = [0, 0, 0, 0]      // 4 items: far hind, far fore, near hind, near fore
    var legLift: [Double] = [0, 0, 0, 0]       // 4 items, u: how far the paw rises off the ground
    var mouthOpen = 0.0, tongue = 0.0, eyesClosed = 0.0, bubble = 0.0
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
    /// Natural upper limit of the leg swing speed, degrees per second (DESIGN.md 4.5 step 5, stage 2): the steady
    /// sprint peak 40 deg x 2 pi x 3.6 Hz = 905 deg/s, times 1.2. A gait switch must never move a leg faster.
    static let maxLegRate = 1100.0
    /// The view never advances the motor by more than this in one frame, s (DESIGN.md 4.6, stage 2).
    static let maxFrameStep = 0.1

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

/// One animated frame: the gait art, the pose and, during a gait switch that changes the art, the old gait and
/// the crossfade amount (0 = all old art, 1 = all new art).
struct DogFrame: Equatable {
    var gait: DogGait
    var pose: DogPose
    var fadeFrom: DogGait?
    var fade = 1.0
    /// Steady frames only (no gait blend, the bubble absent or settled): the place in the gait loop, 0 to 1. The pose
    /// is then `DogMotor.loopPose(gait:loop:input:)` of this value, so the view may draw a cached strip frame instead.
    var loop: Double?
}

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
    private var bubbleSince: Double?

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
        frame(dt: dt, input: input).pose
    }

    /// Advances time by `dt` seconds and returns the whole frame: pose, art and the crossfade of a gait switch.
    mutating func frame(dt: Double, input: DogInput) -> DogFrame {
        let dt = max(0, min(dt, 1))
        time += dt
        if input.isStatic { return DogFrame(gait: .stand, pose: DogMotor.staticPose(gait: .stand, input: input)) }

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

        let target = DogGaitRules.frequency(gait, s: smoothed ?? 0)
        let maxStep = DogGaitRules.maxFrequencySlope * dt
        frequency += min(max(target - frequency, -maxStep), maxStep)
        phase += 2 * Double.pi * frequency * dt
        if phase > 2000 * Double.pi { phase -= 2000 * Double.pi }   // Keeps precision; a whole number of cycles

        var pose = DogMotor.loopedPose(gait, phase: phase, time: time, input: input)
        var out = DogFrame(gait: gait, pose: pose)
        var steady = true
        if let from = previousGait {
            let k = (time - blendStart) / blendDuration
            if k >= 1 {
                previousGait = nil
            } else {
                let s = smoothstep(k)
                let old = DogMotor.loopedPose(from, phase: phase, time: time, input: input)
                pose = DogMotor.blend(old, pose, s)
                steady = false
                if DogRig.artChanges(from, gait) {
                    out.fadeFrom = from
                    out.fade = s
                }
            }
        }
        // The bubble pops once when it appears (scale 0.6 -> 1, DESIGN.md 5.3), then stays still.
        if pose.bubble > 0 {
            let since = bubbleSince ?? time
            bubbleSince = since
            pose.bubble = DogMotor.pop(time - since)
            if pose.bubble != 1 { steady = false }
        } else {
            bubbleSince = nil
        }
        out.pose = pose
        if steady { out.loop = DogMotor.loopFraction(gait, phase: phase, time: time) }
        return out
    }

    // MARK: Gait loops (stage 2, frame cost)

    /// Loop period of the idle gaits, s: lie breathes and wags once in 2 s, stand breathes once and wags 3 times in 2.5 s.
    static func idlePeriod(_ g: DogGait) -> Double? {
        switch g {
        case .lie: return 2.0
        case .stand: return 2.5
        default: return nil
        }
    }

    /// Pant cycles per gait loop, so the pant repeats with the loop: lie 5 (2.5 Hz), stand 6 (2.4 Hz),
    /// walk 2 (1.6 to 2.8 Hz), trot and sprint 1 (1.6 to 3.6 Hz, one pant per stride).
    static func pantCycles(_ g: DogGait) -> Double {
        switch g {
        case .lie: return 5
        case .stand: return 6
        case .walk: return 2
        case .trot, .sprint: return 1
        }
    }

    /// The place in the gait loop, 0 to 1: the stride phase for the moving gaits, the time in the idle loop for lie
    /// and stand.
    static func loopFraction(_ g: DogGait, phase: Double, time: Double) -> Double {
        let tau = 2 * Double.pi
        let x: Double
        if let period = idlePeriod(g) { x = time / period } else { x = phase / tau }
        let f = x - x.rounded(.down)
        return f >= 1 ? 0 : f
    }

    /// Gait pose plus the overlays, all periodic in the gait loop.
    static func loopedPose(_ g: DogGait, phase: Double, time: Double, input: DogInput) -> DogPose {
        let loop = loopFraction(g, phase: phase, time: time)
        return applyOverlays(gaitPose(g, phase: phase, time: time), input: input, loop: loop, gait: g, animated: true)
    }

    /// The pose of a steady frame at loop place `loop` (0 to 1). Equal to the motor pose of a steady frame with the
    /// same gait, loop place and input: the view caches the drawing of each loop place (DESIGN.md 4.6, stage 2).
    static func loopPose(gait g: DogGait, loop: Double, input: DogInput) -> DogPose {
        let tau = 2 * Double.pi
        let phase = idlePeriod(g) == nil ? tau * loop : 0
        let time = (idlePeriod(g) ?? 0) * loop
        var pose = loopedPose(g, phase: phase, time: time, input: input)
        if pose.bubble > 0 { pose.bubble = 1 }
        return pose
    }

    /// The bubble pop: spring(response 0.40, dampingFraction 0.78) from 0.6 to 1 (DESIGN.md 5.3). 1 after 1.2 s.
    static func pop(_ t: Double) -> Double {
        if t >= 1.2 { return 1 }
        let zeta = 0.78, w = 2 * Double.pi / 0.40
        let root = (1 - zeta * zeta).squareRoot(), wd = w * root
        let t = max(0, t)
        return 1 - 0.4 * exp(-zeta * w * t) * (cos(wd * t) + zeta / root * sin(wd * t))
    }

    /// Group opacity of the gray dog (collecting, stale). The renderer also uses the muted gray palette for it.
    /// Stage 2: 0.45 with the normal palette was too faint in light mode (0.9 % ink in the M19 gate), so the gray look
    /// now comes from the palette and the opacity only softens it.
    static let grayOpacity = 0.85

    /// Static pose. The default phase pi / 2 is the key frame for Reduce Motion and the card.
    /// The gallery also asks for phase 0 and pi (frames A and B of one stride).
    static func staticPose(gait: DogGait, input: DogInput, phase: Double = Double.pi / 2) -> DogPose {
        if input.isStatic {
            var pose = gaitPose(.stand, phase: Double.pi / 2, time: 0)
            pose.tailAngle = 0
            pose.breath = 0
            pose.opacity = DogMotor.grayOpacity
            return pose
        }
        var pose = gaitPose(gait, phase: phase, time: 0)
        pose.breath = 0
        return applyOverlays(pose, input: input, loop: 0, gait: gait, animated: false)
    }

    /// The gait the motor would show for a fixed input (the gallery and the first frame).
    static func staticGait(for input: DogInput) -> DogGait {
        guard !input.isStatic, let cpu = input.cpuPercent else { return .stand }
        return DogGaitRules.plainGait(cpu)
    }

    // MARK: Pose math (DESIGN.md 4.4)

    /// Pure gait pose at phase `phase` (radians) and time `time` (s).
    static func gaitPose(_ gait: DogGait, phase: Double, time t: Double) -> DogPose {
        var p = DogPose()
        let tau = 2 * Double.pi
        /// `lift` is the highest paw point above the ground (u). `liftShift` moves it later in the swing
        /// (radians): 0 lifts the paw as it passes under the body, pi / 4 lifts it while it reaches forward.
        func legs(_ amp: Double, _ offsets: [Double], lift: Double, liftShift: Double = 0) {
            for i in 0..<4 {
                let a = phase + tau * offsets[i]
                p.legAngle[i] = amp * sin(a)
                p.legLift[i] = lift * max(0, cos(a - liftShift))
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
            // Four-beat walk. At phase pi / 2 the near fore paw is 11 u up and forward (6.6 px at the 72 pt card);
            // the body bobs 4 u (2.4 px) twice per stride.
            legs(26, [0.125, 0.375, 0.625, 0.875], lift: 11, liftShift: Double.pi / 4)
            p.bodyY = -2 + 2 * cos(2 * phase)
            p.headY = -0.5 * abs(sin(2 * (phase - tau * 0.1)))
            p.earAngle = 10 * sin(phase)
            p.tailAngle = 8 * sin(phase)
        case .trot:
            // Diagonal pairs cross wide and the forward pair is in the air, the body leans forward.
            legs(34, [0, 0.5, 0.5, 0], lift: 15, liftShift: Double.pi / 4)
            p.bodyPitch = 4
            p.bodyY = -4 * abs(sin(phase))
            p.earAngle = 8 * sin(phase - tau * 0.15)
            p.tailAngle = 10 + 6 * sin(phase)
        case .sprint:
            // Gallop: strong forward lean and ears blown back. No speed lines (round 2).
            legs(40, [0.5, 0, 0.58, 0.08], lift: 12, liftShift: Double.pi / 4)
            p.bodyPitch = 8 + 3 * sin(phase)
            p.bodyY = -4 * abs(sin(phase))
            p.earAngle = -40 + 5 * sin(phase - tau * 0.15)
            p.headTilt = -4
            p.tailAngle = -20
        }
        return p
    }

    /// Thermal pant, the attention bubble and memory red on top of the gait pose. Stage 2: the pant runs
    /// `pantCycles(gait)` times per gait loop (`loop` 0 to 1), so a steady frame repeats with the loop.
    static func applyOverlays(_ base: DogPose, input: DogInput, loop: Double, gait: DogGait, animated: Bool) -> DogPose {
        var p = base
        let tau = 2 * Double.pi
        if input.thermal == .serious || input.thermal == .critical {
            let a = tau * pantCycles(gait) * loop
            p.mouthOpen = 1
            p.tongue = animated ? 8 + sin(a) : 8
            p.breath = animated ? 0.03 * sin(a) : 0
            p.eyesClosed = min(p.eyesClosed, 0.2)
        }
        if input.worstProblem != nil, input.worstLevel == .yellow || input.worstLevel == .red {
            p.earAngle += -25
            p.headTilt = 8
            p.bubble = 1
        }
        // Memory red (stage 2, I3 request 2): the plume droops and wags less, the dog looks loaded. It also shows when
        // another item is the worst problem and owns the bubble (the multi case), so memory red is never silent.
        if input.memoryLevel == .red {
            p.tailAngle = DogMotor.memoryTailWag * p.tailAngle + DogMotor.memoryTailDrop
        }
        return p
    }

    /// Memory red: tail angle = wag x tail + drop (degrees; negative lowers the plume).
    static let memoryTailWag = 0.4
    static let memoryTailDrop = -12.0

    static func blend(_ a: DogPose, _ b: DogPose, _ k: Double) -> DogPose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var p = DogPose()
        p.bodyY = m(a.bodyY, b.bodyY); p.bodyPitch = m(a.bodyPitch, b.bodyPitch); p.breath = m(a.breath, b.breath)
        p.headY = m(a.headY, b.headY); p.headTilt = m(a.headTilt, b.headTilt)
        p.earAngle = m(a.earAngle, b.earAngle); p.tailAngle = m(a.tailAngle, b.tailAngle)
        p.legAngle = (0..<4).map { m(a.legAngle[$0], b.legAngle[$0]) }
        p.legLift = (0..<4).map { m(a.legLift[$0], b.legLift[$0]) }
        p.mouthOpen = m(a.mouthOpen, b.mouthOpen); p.tongue = m(a.tongue, b.tongue); p.eyesClosed = m(a.eyesClosed, b.eyesClosed)
        p.bubble = m(a.bubble, b.bubble)
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

    /// True when a switch between the two gaits changes the body or the head art, so the view crossfades.
    static func artChanges(_ a: DogGait, _ b: DogGait) -> Bool {
        let open: (DogGait) -> Bool = { $0 == .trot || $0 == .sprint }
        return body(for: a) != body(for: b) || open(a) != open(b)
    }

    /// Which head art a pose uses.
    static func head(for gait: DogGait, pose: DogPose) -> DogHeadVariant {
        if pose.mouthOpen >= 0.5 { return .pant }
        return (gait == .trot || gait == .sprint) ? .open : .smile
    }

    /// The thought bubble alone (circle, tail dot and, when `glyph` is given, the problem glyph), scaled about the bubble
    /// center by `scale` (the pop). The bitmap dog draws it over the picture (docs/DESIGN.md 4.9).
    static func bubbleLayers(glyph: [DogPart]?, scale k: Double) -> [DogLayer] {
        var out = [DogLayer]()
        for part in DogArt.overlay(.bubble) {
            out.append(DogLayer(part: part, transform: .scale(k, k, about: part.pivot), alpha: 1))
        }
        if let glyph {
            let f = DogArt.bubbleGlyphFrame
            let pivot = (DogArt.bubbleCircle.x, DogArt.bubbleCircle.y)
            let place = DogAffine.scale(f.size / DogArt.badgeSize, f.size / DogArt.badgeSize, about: (0, 0))
                .then(.translate(f.x, f.y)).then(.scale(k, k, about: pivot))
            for part in glyph {
                var g = part
                g.name = "glyph." + part.name
                out.append(DogLayer(part: g, transform: place, alpha: 1))
            }
        }
        return out
    }

    /// All layers of one frame in drawing order. `glyph` is the bubble glyph art (DogArt.badge), or nil.
    /// `pose.opacity` is not in the layer alphas: the renderer applies it to the whole dog as one group.
    static func layers(gait: DogGait, pose: DogPose, glyph: [DogPart]? = nil) -> [DogLayer] {
        let bodyArt = body(for: gait)
        let headArt = head(for: gait, pose: pose)
        let lie = (bodyArt == .lie)
        let center: (x: Double, y: Double) = lie ? (52, 70) : (55, 55)
        // While the bubble shows, the whole dog shrinks about a ground point at the tail side (round 3).
        let k = min(1, max(0, pose.bubble))
        let shrink = 1 - (1 - DogArt.bubbleShrink) * k
        let fit = DogAffine.scale(shrink, shrink, about: DogArt.bubbleShrinkAnchor)
        let pitch = DogAffine.rotate(pose.bodyPitch, about: center)
        let base = pitch.then(.translate(0, pose.bodyY)).then(fit)
        let headPivot: (x: Double, y: Double) = lie ? (80, 65) : (80, 45)
        let head = DogAffine.rotate(-pose.headTilt, about: headPivot).then(.translate(0, pose.headY)).then(base)
        var out = [DogLayer]()

        func add(_ part: DogPart, _ t: DogAffine, _ alpha: Double = 1) {
            out.append(DogLayer(part: part, transform: t, alpha: alpha))
        }
        for part in DogArt.parts(body: bodyArt, head: headArt) {
            let n = part.name
            if n == "shadow" {
                let sx = 1 + max(-0.1, min(0.05, pose.bodyY * 0.04))
                add(part, DogAffine.scale(sx, 1, about: part.pivot).then(fit))
            } else if let i = legNames.firstIndex(of: n) {
                // Legs do not bob with the body. Swing about the hip and lean with the body, then move the leg
                // so its lowest paw corner is on the ground again, then lift it by legLift (u).
                let hip = pitch.apply(part.pivot.x, part.pivot.y)
                let turn = (pose.bodyPitch - pose.legAngle[i]) * Double.pi / 180
                let length = DogArt.groundY - part.pivot.y
                let low = hip.y + length * cos(turn) + DogArt.pawHalfWidth * abs(sin(turn))
                let t = DogAffine.rotate(-pose.legAngle[i], about: part.pivot).then(pitch)
                    .then(.translate(0, DogArt.groundY - low - pose.legLift[i])).then(fit)
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
        if headArt == .pant {
            for part in DogArt.overlay(.sweat) { add(part, head, 1) }
        }
        if pose.bubble > 0 {
            out.append(contentsOf: bubbleLayers(glyph: glyph, scale: k))
        }
        return out
    }
}

