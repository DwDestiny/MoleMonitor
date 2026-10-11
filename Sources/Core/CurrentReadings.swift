// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (type definitions; the engine fills them).
// Output: The latest readings for the card, the prompt and status.json, and the data state of the card.
// Pos: Plain value types (docs/DESIGN.md 8.1); Foundation only. Owner I1. Nil means "not measured", never zero.

import Foundation

struct CurrentReadings: Codable, Equatable {
    var cpuPercent: Double?
    var cpuMean5m: Double?
    var cpuMean10m: Double?
    var pressure: MemoryPressure?
    var swapUsed: Int64?
    var swapGrowth30m: Int64?
    var swapTrend: SwapTrend?
    var physicalMemory: Int64?
    var thermal: ThermalLevel?
    var batteryPercent: Double?
    var powerSource: PowerSource?
    var lastSleep: SleepRecord?
    var awakeDrainPerHour: Double?     // Drain rate over a 60 minute window, % per hour
    var rx: Double?
    var tx: Double?
    var smcCPUTemperature: Double?
    var fanRPMs: [Double]?
    /// Disk available capacity for important usage, bytes (prompt line and status.json).
    var diskAvailable: Int64?
    var sampledAt: Date?
}

/// Whether the card data is still being collected, fresh, or stale since a given time.
enum DataState: Equatable {
    case collecting
    case fresh
    case stale(Date)
}
