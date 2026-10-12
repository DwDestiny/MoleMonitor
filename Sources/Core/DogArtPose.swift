// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A DogInput (docs/DESIGN.md 4.9) and the data points that arrive while the status card is open.
// Output: DogArtPose, the bitmap that the status card shows, and DogArtSelector, the small stepped object that smooths the CPU gait.
// Pos: Pure logic of the bitmap dog (stage "bitmap"). Foundation only. It reuses DogGaitRules (smoothing, hysteresis, 4 s minimum hold),
//      so the picture does not flicker when the CPU wobbles around a threshold. It has no timer: the caller advances it once per new data point.

import Foundation

/// The eight bitmaps of `Resources/DogArt` (dog_<name>.png).
enum DogArtPose: String, CaseIterable {
    case lie, stand, walk, trot, sprint, pant, alert, gray

    /// File name without the extension, for example `dog_lie`.
    var fileName: String { "dog_" + rawValue }

    /// The bitmap for an input and a gait that was already smoothed.
    /// Priority: static (collecting, stale) is gray, then a red temperature is pant, then a yellow or red problem is alert,
    /// then the CPU gait.
    static func select(input: DogInput, gait: DogGait) -> DogArtPose {
        if input.isStatic { return .gray }
        if input.thermal == .serious || input.thermal == .critical { return .pant }
        if input.worstProblem != nil, input.worstLevel == .yellow || input.worstLevel == .red { return .alert }
        return fromGait(gait)
    }

    /// The bitmap of a CPU gait.
    static func fromGait(_ gait: DogGait) -> DogArtPose {
        switch gait {
        case .lie: return .lie
        case .stand: return .stand
        case .walk: return .walk
        case .trot: return .trot
        case .sprint: return .sprint
        }
    }
}

/// Smooths the CPU and picks the bitmap. One step per data point (about 30 s when the card is closed to the live sampler,
/// 2 s while it is open). The caller gives the time since the previous point. The rules are the ones of `DogMotor`
/// (docs/DESIGN.md 4.5): exponential smoothing (tau 8 s), enter and leave thresholds, at least 4 s in one gait, at most
/// 2 switches in 10 s. The first CPU value picks its gait at once.
struct DogArtSelector {
    /// Longest step accepted, s. A longer pause (for example a sleep) counts as this long.
    static let maxStep = 300.0

    private(set) var gait: DogGait
    private(set) var smoothed: Double?
    private(set) var pose: DogArtPose
    private var time = 0.0
    private var lastSwitch = -Double.infinity
    private var switchTimes = [Double]()

    /// Starts from the first input, like `DogMotor(initialCPU:)`: the first CPU value picks the gait without smoothing.
    init(initial input: DogInput) {
        smoothed = input.cpuPercent
        if let s = input.cpuPercent {
            gait = DogGaitRules.plainGait(s)
        } else {
            gait = .stand
        }
        pose = DogArtPose.select(input: input, gait: gait)
    }

    /// Takes the next data point, `dt` seconds after the previous one. Returns the bitmap to show.
    @discardableResult
    mutating func advance(dt: Double, input: DogInput) -> DogArtPose {
        let dt = max(0, min(dt, DogArtSelector.maxStep))
        time += dt
        // A static input (collecting, stale) does not move the smoothing, like the motor.
        if !input.isStatic {
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
                    gait = wanted
                    lastSwitch = time
                    switchTimes.append(time)
                }
            }
        }
        pose = DogArtPose.select(input: input, gait: gait)
        return pose
    }
}
