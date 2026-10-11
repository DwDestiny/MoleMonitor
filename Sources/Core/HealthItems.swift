// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (type definitions).
// Output: The five health items, the memory, thermal, power and swap vocabulary, and ItemVerdict (docs/DESIGN.md 8.1).
// Pos: Core vocabulary of the problem-first status card; Foundation only. Owner I1. Constants only, no rules.
// SKELETON: the types are final (DESIGN.md 8.1); I1 may add private members but must not change public signatures.

import Foundation

enum HealthItem: String, Codable, CaseIterable {
    case memory, cpu, thermal, disk, power

    /// Fixed priority, smaller first: thermal 0, memory 1, disk 2, power 3, cpu 4.
    var fixedPriority: Int {
        switch self {
        case .thermal: return 0
        case .memory: return 1
        case .disk: return 2
        case .power: return 3
        case .cpu: return 4
        }
    }

    /// Chinese name: 内存, CPU, 温度, 磁盘, 耗电.
    var label: String {
        switch self {
        case .memory: return "内存"
        case .cpu: return "CPU"
        case .thermal: return "温度"
        case .disk: return "磁盘"
        case .power: return "耗电"
        }
    }
}

enum MemoryPressure: String, Codable { case normal, warning, critical }
enum ThermalLevel: String, Codable { case nominal, fair, serious, critical }
enum PowerSource: String, Codable { case battery = "b", ac = "a" }
enum SwapTrend: String, Codable { case steepUp = "steep_up", up, flat, down }

struct ItemVerdict: Codable, Equatable {
    var item: HealthItem
    var level: HealthLevel
    var reasonCode: String
    /// One-line title, for example "5 天多占用 314 GB".
    var headline: String
    /// When the problem started (DESIGN.md 6.8). Nil while healthy.
    var since: Date?
    var levelChangedAt: Date?
    var alert: AlertItem?
}

/// `AlertItem` (DiskHealth.swift) is only Codable. `ItemVerdict: Equatable` needs it, so the conformance lives here.
/// Compares every field. Keep this list in step with `AlertItem`; I1 may move `Equatable` to the declaration later.
extension AlertItem: Equatable {
    static func == (a: AlertItem, b: AlertItem) -> Bool {
        if a.type != b.type || a.subject != b.subject || a.level != b.level { return false }
        if a.since != b.since { return false }
        return a.message == b.message && a.agentHint == b.agentHint
    }
}
