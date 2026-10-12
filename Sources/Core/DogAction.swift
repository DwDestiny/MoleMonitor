// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (type definitions).
// Output: DogAction: the 10 actions of the first release, and DogActionInput: the facts the action choice reads.
// Pos: A1 contract skeleton (docs/DESIGN_V2.md 4.3, 4.4): types only, no selection logic. Foundation only. A1 creates it, WP-D owns it after the A1 merge.

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

    init(dataState: DataState = .fresh, cpuPercent: Double? = nil, thermal: HealthLevel = .green,
         memory: HealthLevel = .green, disk: HealthLevel = .green, power: HealthLevel = .green,
         isNight: Bool = false, oneShot: DogAction? = nil) {
        self.dataState = dataState
        self.cpuPercent = cpuPercent
        self.thermal = thermal
        self.memory = memory
        self.disk = disk
        self.power = power
        self.isNight = isNight
        self.oneShot = oneShot
    }
}
