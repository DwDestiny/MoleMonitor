// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: CPU percent, thermal state and health levels over time (docs/DESIGN.md 4.3 to 4.7, 8.1).
// Output: DogPose values: part transform parameters (translate, rotate, scale) per frame.
// Pos: Pure animation math; it never creates shapes (those come from DogArt). Foundation only. Owner I2.
// SKELETON: DogMotor never changes gait and every pose is the neutral pose.

import Foundation

enum DogGait: String, CaseIterable { case lie, stand, walk, trot, sprint }

struct DogInput: Equatable {
    var cpuPercent: Double?
    var thermal: ThermalLevel?
    var memoryLevel: HealthLevel
    var worstProblem: HealthItem?
    var worstLevel: HealthLevel
    var isStatic: Bool          // Collecting, stale, or Reduce Motion
}

struct DogPose: Equatable {
    var bodyY = 0.0, bodyPitch = 0.0, breath = 0.0, headY = 0.0, headTilt = 0.0, earAngle = 0.0, tailAngle = 0.0
    var legAngle: [Double] = [0, 0, 0, 0]      // 4 items
    var legLift: [Double] = [0, 0, 0, 0]       // 4 items
    var mouthOpen = 0.0, tongue = 0.0, eyesClosed = 0.0, bundle = 0.0, bubble = 0.0, speedLines = 0.0
    var opacity = 1.0
}

struct DogMotor {
    private(set) var gait: DogGait

    init(initialCPU: Double?) {
        gait = .lie // SKELETON
    }

    /// Advances time by `dt` seconds with the newest input and returns the pose of this frame.
    mutating func step(dt: Double, input: DogInput) -> DogPose {
        DogPose() // SKELETON
    }

    /// Static pose: phase = pi / 2. For Reduce Motion and the gallery.
    static func staticPose(gait: DogGait, input: DogInput) -> DogPose {
        DogPose() // SKELETON
    }
}
