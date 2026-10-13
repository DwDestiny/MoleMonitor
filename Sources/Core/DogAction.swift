// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: DogActionInput: data state, CPU, item levels, night flag and the one-shot action (docs/DESIGN_V2.md 4.3 to 4.6, 4.9).
// Output: DogAction (the 10 first-release actions), DogStagePlan (action, variant, overlays, playback rate, sink, ground speed),
//         DogDirector (the stepped object that smooths the CPU and keeps the gait rules) and DogTransition (how to go from one action to the next).
// Pos: Pure logic of the v2 stage. Foundation only. The view (Sources/App/DogSpriteView.swift) asks the director once per data point
//      (2 s while the panel is open) and never per frame. A1 created the types; WP-D owns the file.

import Foundation

/// The 10 actions of the first release (DESIGN_V2.md 4.3). The raw value is the strip name in `Resources/DogSprites`.
enum DogAction: String, Codable, CaseIterable {
    case lieIdle = "lie_idle"
    case walk
    case trot
    case sprint
    case sniff
    case sitGray = "sit_gray"
    case standUp = "stand_up"
    case wag
    case pantLie = "pant_lie"
    case notice

    /// The CPU gaits (4.5).
    static let gaits: [DogAction] = [.lieIdle, .walk, .trot, .sprint]

    /// Natural step frequency of a moving gait, Hz (4.5 table). Nil for the actions that do not step.
    var naturalStepHz: Double? {
        switch self {
        case .walk: return 1.0
        case .trot: return 1.6
        case .sprint: return 2.4
        default: return nil
        }
    }

    /// The dog lies on the ground (4.6: the "躺类" group).
    var isLying: Bool { self == .lieIdle || self == .pantLie }

    /// One-shot actions (4.3: "一次").
    var isOneShot: Bool { self == .standUp || self == .wag || self == .notice }

    /// The gait of DogGaitRules for this action, for the hysteresis rules.
    var gait: DogGait? {
        switch self {
        case .lieIdle: return .lie
        case .walk: return .walk
        case .trot: return .trot
        case .sprint: return .sprint
        default: return nil
        }
    }

    static func from(_ gait: DogGait) -> DogAction {
        switch gait {
        case .lie, .stand: return .lieIdle
        case .walk: return .walk
        case .trot: return .trot
        case .sprint: return .sprint
        }
    }
}

/// The facts that choose the base action (DESIGN_V2.md 4.4). The levels are the item levels from `ItemVerdict`.
struct DogActionInput: Equatable {
    var dataState: DataState
    /// System CPU, 0 to 100. Nil when not measured.
    var cpuPercent: Double?
    var thermal: HealthLevel
    var memory: HealthLevel
    var disk: HealthLevel
    var power: HealthLevel
    /// Local time between 22:00 and 6:00.
    var isNight: Bool
    /// A one-shot action that is playing now (`standUp`, `wag`, `notice`), if any.
    var oneShot: DogAction?
    /// The CPU item level. "No problem" (4.4 row 6, 4.9) also needs a green CPU item.
    var cpu: HealthLevel = .green

    init(dataState: DataState = .fresh, cpuPercent: Double? = nil, thermal: HealthLevel = .green,
         memory: HealthLevel = .green, disk: HealthLevel = .green, power: HealthLevel = .green,
         isNight: Bool = false, oneShot: DogAction? = nil, cpu: HealthLevel = .green) {
        self.dataState = dataState
        self.cpuPercent = cpuPercent
        self.thermal = thermal
        self.memory = memory
        self.disk = disk
        self.power = power
        self.isNight = isNight
        self.oneShot = oneShot
        self.cpu = cpu
    }

    /// True when one of the five items is yellow or red.
    var hasProblem: Bool {
        [thermal, memory, disk, power, cpu].contains { $0 == .yellow || $0 == .red }
    }
}

/// The procedural variants of 4.4. They use the same strip with another rate, sink and scale (11.6 level 1 means).
enum DogVariant: String, Equatable {
    case normal
    /// Memory red: walk with the body 4 pt lower, 0.97 vertical scale, slow steps.
    case heavy
    /// Power yellow or red with CPU below 40 %: lie_idle at rate 0.6, body 2 pt lower.
    case tired
    /// Night, no problem, CPU below 20 %: lie_idle at rate 0.5, a "z" every 3 s.
    case sleep
}

/// The bed prop of the stage (4.2, 4.4).
enum DogBed: String, Equatable {
    case some = "bed_some"
    case full = "bed_full"
}

/// The overlays that can join any base action (4.4, second table).
struct DogOverlays: Equatable {
    var bed: DogBed?
    /// Temperature yellow: 2 sweat drops, breathing 1.5 times faster.
    var sweat = false
    /// Memory yellow: body 2 pt lower, steps and ground x 0.8.
    var memorySink = false
    /// Night stage (stage.night, moon and 3 stars).
    var night = false
}

/// What the stage shows after one data point. All values are final: the view only applies them.
struct DogStagePlan: Equatable {
    var action: DogAction
    var variant: DogVariant
    var overlays: DogOverlays
    /// Playback speed of the strip (CALayer.speed). 1 is the natural frame rate of the manifest.
    var rate: Double
    /// Step frequency, Hz. 0 for the actions that do not step.
    var stepHz: Double
    /// Body sink, pt (positive is lower).
    var sink: Double
    /// Vertical scale of the body (heavy walk 0.97).
    var scaleY: Double
    /// Ground texture speed, pt/s. 0 when the dog does not move forward.
    var groundSpeed: Double
    /// A "z" rises every 3 s (sleep variant).
    var showsZ: Bool
}

/// How the view goes from the action on screen to the next one (4.6).
enum DogTransition: Equatable {
    /// Wait for the next contact frame of the current gait, then start the target at its contact frame 0.
    case atContact
    /// Play `stand_up` forward, then the target.
    case standUp
    /// Play `stand_up` backward (`lie_down`), then the target.
    case lieDown
    /// Crossfade over the given seconds.
    case crossfade(Double)
    /// Same action, other variant: tween sink, scale and rate over 0.4 s without a new picture.
    case tween
    /// Same action and variant: nothing to do.
    case none
}

enum DogStage {
    /// f(s) nodes of 4.5: CPU percent to step frequency in Hz.
    static let frequencyNodes: [(s: Double, f: Double)] = [(10, 0.70), (40, 1.30), (80, 2.08), (100, 3.00)]
    /// Smoothing time constant of the CPU while the panel is open, s (4.5 rule 2).
    static let tau = 6.0
    /// Largest change of the playback rate between two samples (4.5 rule 6).
    static let maxRateStep = 0.25
    /// Highest frame rate of a strip, fps (4.5 rule 7, 11.2 rule 5).
    static let maxFPS = 18.0
    /// Ground speed per step frequency, pt per step (4.5 rule 8).
    static let groundPerStep = 24.0
    /// Heavy walk: step factor and upper limit (4.4 row 3).
    static let heavyFactor = 0.6, heavyMaxHz = 0.8
    /// Memory yellow step factor (4.4 overlays).
    static let memoryYellowFactor = 0.8
    /// Temperature yellow breathing factor (4.4 overlays).
    static let sweatBreathFactor = 1.5
    /// Natural frame rates of the manifest (4.3). The view reads the manifest; these copies keep Core self-contained.
    static let naturalFPS: [DogAction: Double] = [.lieIdle: 4, .walk: 8, .trot: 12.8, .sprint: 14.4, .sniff: 8,
                                                  .standUp: 18, .wag: 12, .pantLie: 10, .notice: 10]

    /// f(s), Hz. Linear between the nodes, flat outside them.
    static func stepFrequency(_ s: Double) -> Double {
        let nodes = frequencyNodes
        if s <= nodes[0].s { return nodes[0].f }
        for i in 1..<nodes.count where s <= nodes[i].s {
            let a = nodes[i - 1], b = nodes[i]
            return a.f + (b.f - a.f) * (s - a.s) / (b.s - a.s)
        }
        return nodes[nodes.count - 1].f
    }

    /// Local night: 22:00 to 6:00 (4.9 rule 1).
    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 6
    }

    /// The base action and variant of 4.4 for a gait that the director already smoothed.
    static func base(_ input: DogActionInput, gait: DogAction) -> (DogAction, DogVariant) {
        switch input.dataState {
        case .stale: return (.sitGray, .normal)
        case .collecting: return (.sniff, .normal)
        case .fresh: break
        }
        if input.thermal == .red { return (.pantLie, .normal) }
        if input.memory == .red { return (.walk, .heavy) }
        if input.power == .yellow || input.power == .red, (input.cpuPercent ?? 0) < 40 { return (.lieIdle, .tired) }
        if let one = input.oneShot { return (one, .normal) }
        if input.isNight, !input.hasProblem, (input.cpuPercent ?? 0) < 20 { return (.lieIdle, .sleep) }
        return (gait, .normal)
    }

    static func overlays(_ input: DogActionInput) -> DogOverlays {
        var o = DogOverlays()
        if case .fresh = input.dataState {
            if input.disk == .yellow { o.bed = .some }
            if input.disk == .red { o.bed = .full }
            o.sweat = input.thermal == .yellow
            o.memorySink = input.memory == .yellow
        }
        o.night = input.isNight
        return o
    }

    /// The transition of 4.6 from the action on screen to the target.
    static func transition(from: DogAction, _ fromVariant: DogVariant = .normal,
                           to: DogAction, _ toVariant: DogVariant = .normal) -> DogTransition {
        if from == to { return fromVariant == toVariant ? .none : .tween }
        if to == .sitGray { return .crossfade(0.2) }
        if to == .sniff { return .crossfade(0.16) }
        if from.isOneShot && from != .standUp { return .crossfade(0.12) }
        if from.naturalStepHz != nil, to.naturalStepHz != nil { return .atContact }
        if from.isLying, !to.isLying, to != .standUp { return .standUp }
        if !from.isLying, from != .standUp, to.isLying { return .lieDown }
        return .crossfade(0.16)
    }
}

/// Smooths the CPU, keeps the gait rules and makes the stage plan. One step per data point.
/// Rules (4.5): the first value is not smoothed; tau 6 s; enter and leave thresholds of DogGaitRules; at least 4 s in one gait;
/// at most 2 switches in 10 s; the rate changes by at most 0.25 per sample inside one gait; no strip plays faster than 18 fps.
/// At a gait switch the step frequency stays continuous and only the rate (frequency / natural frequency) is set anew.
struct DogDirector {
    private(set) var smoothed: Double?
    private(set) var gait: DogAction = .lieIdle
    private(set) var plan: DogStagePlan?
    private var time = 0.0
    private var lastSwitch = -Double.infinity
    private var switchTimes = [Double]()
    private var started = false
    private var hasGait = false

    init() {}

    /// Takes the next data point, `dt` seconds after the previous one (ignored for the first point).
    @discardableResult
    mutating func step(dt: Double, input: DogActionInput) -> DogStagePlan {
        let dt = max(0, min(dt, DogArtSelector.maxStep))
        if started { time += dt }
        if case .fresh = input.dataState, let x = input.cpuPercent {
            if let s = smoothed, started {
                smoothed = s + (1 - exp(-dt / DogStage.tau)) * (x - s)
            } else {
                smoothed = x
            }
            moveGait(smoothed!)
        }
        started = true
        let (action, variant) = DogStage.base(input, gait: gait)
        let next = makePlan(action: action, variant: variant, input: input, previous: plan)
        plan = next
        return next
    }

    private mutating func moveGait(_ s: Double) {
        let current = gait.gait ?? .lie
        let first = !hasGait
        hasGait = true
        let wanted = DogAction.from(first ? DogGaitRules.plainGait(s) : DogGaitRules.nextGait(from: current, s: s))
        guard wanted != gait else { return }
        switchTimes = switchTimes.filter { time - $0 < DogGaitRules.switchWindow }
        if first || (time - lastSwitch >= DogGaitRules.minHold && switchTimes.count < DogGaitRules.maxSwitches) {
            gait = wanted
            if !first {
                lastSwitch = time
                switchTimes.append(time)
            }
        }
    }

    private func makePlan(action: DogAction, variant: DogVariant, input: DogActionInput, previous: DogStagePlan?) -> DogStagePlan {
        let o = DogStage.overlays(input)
        var rate = 1.0, stepHz = 0.0, sink = 0.0, scaleY = 1.0, ground = 0.0
        let s = smoothed ?? 0
        if let natural = action.naturalStepHz {
            var f = DogStage.stepFrequency(s)
            if variant == .heavy {
                f = min(f * DogStage.heavyFactor, DogStage.heavyMaxHz)
                sink = 4
                scaleY = 0.97
            } else if o.memorySink {
                f *= DogStage.memoryYellowFactor
            }
            var r = f / natural
            // Inside one gait and variant the rate moves by at most 0.25 per sample.
            if let p = previous, p.action == action, p.variant == variant {
                r = min(max(r, p.rate - DogStage.maxRateStep), p.rate + DogStage.maxRateStep)
            }
            let cap = DogStage.maxFPS / (DogStage.naturalFPS[action] ?? DogStage.maxFPS)
            rate = min(r, cap)
            stepHz = rate * natural
            ground = DogStage.groundPerStep * stepHz
        } else if action == .lieIdle {
            switch variant {
            case .tired: rate = 0.6; sink = 2
            case .sleep: rate = 0.5
            default: rate = 1
            }
            if o.sweat { rate *= DogStage.sweatBreathFactor }
        } else if action == .pantLie, o.sweat {
            rate = DogStage.sweatBreathFactor
        }
        if o.memorySink, variant != .heavy, !action.isLying { sink = max(sink, 2) }
        return DogStagePlan(action: action, variant: variant, overlays: o, rate: rate, stepHz: stepHz, sink: sink,
                            scaleY: scaleY, groundSpeed: ground, showsZ: variant == .sleep)
    }
}
