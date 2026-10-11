// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (type definitions and text helpers).
// Output: The five health items, the memory, thermal, power and swap vocabulary, ItemVerdict (docs/DESIGN.md 8.1),
//         and the shared Chinese texts: levels, pressure, thermal state, "已持续", byte and percent formats.
// Pos: Core vocabulary of the problem-first status card; Foundation only. Owner I1. No rules here.

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

extension ItemVerdict {
    /// Yellow or red.
    var isProblem: Bool { level == .yellow || level == .red }
}

extension MemoryPressure {
    /// 正常, 警告, 严重 (DESIGN.md 6.7).
    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "严重"
        }
    }

    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}

extension ThermalLevel {
    /// 正常, 偏热, 很热, 过热 (DESIGN.md 6.8).
    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "很热"
        case .critical: return "过热"
        }
    }

    var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }
}

extension SwapTrend {
    /// Arrow of DESIGN.md 6.7.
    var arrow: String {
        switch self {
        case .steepUp: return "\u{2191}\u{2191}"
        case .up: return "\u{2191}"
        case .flat: return "\u{2192}"
        case .down: return "\u{2193}"
        }
    }
}

/// Texts shared by the card, the notifications and the prompt. Pure functions.
enum TextFormat {
    /// Level word in tables: 红, 黄, 正常, 统计中, 过期, 不适用.
    static func levelWord(_ level: HealthLevel) -> String {
        switch level {
        case .red: return "红"
        case .yellow: return "黄"
        case .green: return "正常"
        case .unknown: return "统计中"
        case .stale: return "过期"
        case .notApplicable: return "不适用"
        }
    }

    /// "已持续" of DESIGN.md 6.8: 刚刚, N 分, N 小时 M 分, N 天 M 小时. "—" without a start time.
    static func duration(since start: Date?, now: Date) -> String {
        guard let start else { return "\u{2014}" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }

    /// CPU style percent: integer, "<1%" below one, "—" when missing. A multi-core app may exceed 100.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "\u{2014}" }
        if value > 0 && value < 1 { return "<1%" }
        return String(format: "%.0f%%", max(0, value))
    }

    /// Memory style size, decimal units: 1 decimal from 1 GB, whole MB below.
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "\u{2014}" }
        let v = Double(max(0, value))
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        return String(format: "%.0f MB", v / 1e6)
    }

    /// Signed size for growth: "+2.4 GB", "-0.5 GB", "0 MB".
    static func signedBytes(_ value: Int64?) -> String {
        guard let value else { return "\u{2014}" }
        if value == 0 { return "0 MB" }
        let text = bytes(abs(value))
        return (value > 0 ? "+" : "-") + text
    }

    /// Disk growth style (ByteText.gb) with a sign.
    static func signedDiskGB(_ value: Int64?) -> String {
        guard let value else { return "\u{2014}" }
        return (value >= 0 ? "+" : "-") + ByteText.gb(abs(value))
    }

    /// Local time "M月d日 HH:mm" for a time zone, without DateFormatter.
    static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        let local = date.addingTimeInterval(Double(timeZone.secondsFromGMT(for: date)))
        let secs = Int64(local.timeIntervalSince1970.rounded(.down))
        let day = UTCTime.floorDiv(secs, 86400)
        let rem = Int(secs - day * 86400)
        let c = UTCTime.civil(fromDayIndex: day)
        return "\(c.month)月\(c.day)日 " + two(rem / 3600) + ":" + two(rem % 3600 / 60)
    }

    /// Local time "HH:mm".
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let local = date.addingTimeInterval(Double(timeZone.secondsFromGMT(for: date)))
        let secs = Int64(local.timeIntervalSince1970.rounded(.down))
        let rem = Int(secs - UTCTime.floorDiv(secs, 86400) * 86400)
        return two(rem / 3600) + ":" + two(rem % 3600 / 60)
    }

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
