// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk samples, the previous level, thresholds, and notification state.
// Output: Disk verdict (level with hysteresis, reason), alert decisions and Chinese alert text.
// Pos: Disk rules from docs/PROJECT.md 3.5 and 5.2; pure logic, Foundation only.

import Foundation

let gibibyte: Int64 = 1 << 30

/// Decimal GB text for users (Finder style): one decimal below 10 GB, otherwise whole numbers.
enum ByteText {
    static func gb(_ bytes: Int64) -> String {
        let v = Double(bytes) / 1e9
        if abs(v) < 10 { return String(format: "%.1f GB", v) }
        return "\(Int(v.rounded())) GB"
    }

    static func gib(_ bytes: Int64) -> String { "\(Int((Double(bytes) / Double(gibibyte)).rounded())) GiB" }
}

struct AlertItem: Codable {
    var type: String
    var subject: String
    var level: HealthLevel
    var since: Date
    var message: String
    var agentHint: String

    enum CodingKeys: String, CodingKey {
        case type, subject, level, since, message
        case agentHint = "agent_hint"
    }
}

/// Growth rule: threshold = max(absolute bytes, total capacity x fraction).
struct GrowthRule {
    var absolute: Int64
    var fraction: Double
    func threshold(total: Int64) -> Int64 { max(absolute, Int64(Double(total) * fraction)) }
}

/// Defaults from docs/PROJECT.md 3.5. config.json overrides are not parsed yet.
struct DiskThresholds {
    var yellow1d = GrowthRule(absolute: 20 * gibibyte, fraction: 0.03)
    var red1d = GrowthRule(absolute: 60 * gibibyte, fraction: 0.08)
    var yellow5d = GrowthRule(absolute: 60 * gibibyte, fraction: 0.08)
    var red5d = GrowthRule(absolute: 150 * gibibyte, fraction: 0.20)
    /// Yellow when availImportant < total x this.
    var availYellowFraction = 0.15
    /// Red when availImportant < max(total x this, availRedAbsolute).
    var availRedFraction = 0.05
    var availRedAbsolute: Int64 = 15 * gibibyte
    /// Exit: growth below this share of the level's entry threshold.
    var exitGrowthFactor = 0.5
    /// Exit: available space back above the entry line plus this share of total (3 points).
    var exitAvailMargin = 0.03
    /// Newest usable sample must be this fresh (seconds), else the verdict is no_data.
    var maxSampleAge: TimeInterval = 7200
}

struct DiskVerdict {
    var level: HealthLevel
    /// no_data, ok, growth_1d, growth_5d, low_space, recovering, hold
    var reasonCode: String
    var reason: String
    var growth1d: DiskGrowth
    var growth5d: DiskGrowth
    /// Level from the growth rules alone (entry conditions, no hysteresis). unknown when no_data.
    var growthLevel: HealthLevel = .unknown
    /// Level from the free-space rules alone. unknown when no_data.
    var spaceLevel: HealthLevel = .unknown
    var triggerWindow: DiskWindow? = nil
    var triggerBytes: Int64? = nil
    var volume: String = "/System/Volumes/Data"
    var total: Int64? = nil
    var availImportant: Int64? = nil
}

enum DiskHealth {
    static func evaluate(samples: [DiskSample], now: Date, previous: HealthLevel,
                         thresholds: DiskThresholds = DiskThresholds()) -> DiskVerdict {
        let g1 = DiskGrowth.compute(samples: samples, now: now, window: .day1)
        let g5 = DiskGrowth.compute(samples: samples, now: now, window: .day5)
        let usable = samples.filter { $0.realUsed != nil && $0.t <= now }
        guard let cur = usable.max(by: { $0.t < $1.t }), let total = cur.total, let avail = cur.availImportant,
              now.timeIntervalSince(cur.t) <= thresholds.maxSampleAge else {
            return DiskVerdict(level: previous, reasonCode: "no_data", reason: "没有可用的最近磁盘样本，等级不变",
                               growth1d: g1, growth5d: g5)
        }
        let th = thresholds
        let b1 = g1.bytes, b5 = g5.bytes

        // Entry level per rule family.
        var growthRank = 0
        var trigWindow: DiskWindow?
        var trigBytes: Int64?
        if let b = b5, b >= th.red5d.threshold(total: total) {
            growthRank = 2; trigWindow = .day5; trigBytes = b
        } else if let b = b1, b >= th.red1d.threshold(total: total) {
            growthRank = 2; trigWindow = .day1; trigBytes = b
        } else if let b = b5, b >= th.yellow5d.threshold(total: total) {
            growthRank = 1; trigWindow = .day5; trigBytes = b
        } else if let b = b1, b >= th.yellow1d.threshold(total: total) {
            growthRank = 1; trigWindow = .day1; trigBytes = b
        }
        let redLine = max(Int64(Double(total) * th.availRedFraction), th.availRedAbsolute)
        let yellowLine = Int64(Double(total) * th.availYellowFraction)
        let spaceRank = avail < redLine ? 2 : (avail < yellowLine ? 1 : 0)
        let targetRank = max(growthRank, spaceRank)

        // Hysteresis: leave a level only when its exit condition holds, one level per evaluation.
        func canExit(_ rank: Int) -> Bool {
            let rule1 = rank >= 2 ? th.red1d : th.yellow1d
            let rule5 = rank >= 2 ? th.red5d : th.yellow5d
            if let b = b1, Double(b) >= th.exitGrowthFactor * Double(rule1.threshold(total: total)) { return false }
            if let b = b5, Double(b) >= th.exitGrowthFactor * Double(rule5.threshold(total: total)) { return false }
            let entryLine = rank >= 2 ? Double(redLine) : Double(yellowLine)
            return Double(avail) >= entryLine + th.exitAvailMargin * Double(total)
        }
        let prevRank = previous.colorRank ?? 0
        let newRank: Int
        if targetRank >= prevRank {
            newRank = targetRank
        } else {
            newRank = canExit(prevRank) ? prevRank - 1 : prevRank
        }

        var code: String
        var text: String
        if newRank == targetRank {
            if targetRank == 0 {
                (code, text) = ("ok", "磁盘正常")
            } else if growthRank >= spaceRank, let w = trigWindow, let b = trigBytes {
                (code, text) = ("growth_" + w.key, "\(w.days) 天内真实已用增长 \(ByteText.gib(b))")
            } else {
                let pct = Double(avail) / Double(total) * 100
                (code, text) = ("low_space", "可用容量 \(ByteText.gib(avail))，占总容量 \(String(format: "%.1f", pct))%")
            }
        } else if newRank < prevRank {
            (code, text) = ("recovering", "磁盘用量回落中，等级逐级下调")
        } else {
            (code, text) = ("hold", "磁盘等级保持，指标尚未回落到退出线")
        }
        return DiskVerdict(level: HealthLevel.fromColorRank(newRank), reasonCode: code, reason: text,
                           growth1d: g1, growth5d: g5,
                           growthLevel: HealthLevel.fromColorRank(growthRank),
                           spaceLevel: HealthLevel.fromColorRank(spaceRank),
                           triggerWindow: trigWindow, triggerBytes: trigBytes,
                           volume: cur.vol.isEmpty ? "/System/Volumes/Data" : cur.vol,
                           total: total, availImportant: avail)
    }
}

/// What was already notified. Persist it so a restart does not repeat a notification.
struct DiskAlertState: Codable {
    var lastGrowthNotifiedBytes: Int64?
    var lastGrowthLevel: HealthLevel?
    var lastLowSpaceNotifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case lastGrowthNotifiedBytes = "last_growth_notified_bytes"
        case lastGrowthLevel = "last_growth_level"
        case lastLowSpaceNotifiedAt = "last_low_space_notified_at"
    }
}

enum DiskAlertPolicy {
    static let renotifyFactorNumerator: Int64 = 3   // 1.5x = 3/2
    static let renotifyFactorDenominator: Int64 = 2
    static let lowSpaceCooldown: TimeInterval = 24 * 3600

    /// Notification title for a growth alert, e.g. "磁盘 5 天多占用了 312 GB".
    static func growthTitle(_ v: DiskVerdict) -> String {
        "磁盘 \(v.triggerWindow?.days ?? 0) 天多占用了 \(ByteText.gb(v.triggerBytes ?? 0))"
    }

    static func lowSpaceTitle(_ v: DiskVerdict) -> String {
        "磁盘剩余空间只有 \(ByteText.gb(v.availImportant ?? 0))"
    }

    static func growthAlert(verdict: DiskVerdict, since: Date, state: DiskAlertState) -> AlertItem? {
        guard let level = verdict.growthLevel.colorRank, level >= 1,
              let bytes = verdict.triggerBytes, let window = verdict.triggerWindow else { return nil }
        var notify = false
        if let last = state.lastGrowthNotifiedBytes {
            let lastRank = state.lastGrowthLevel?.colorRank ?? 0
            if level > lastRank { notify = true }
            else if last <= 0 { notify = true }
            else if bytes * renotifyFactorDenominator >= last * renotifyFactorNumerator { notify = true }
        } else {
            notify = true
        }
        guard notify else { return nil }
        return AlertItem(type: "disk_growth", subject: verdict.volume, level: verdict.growthLevel, since: since,
                         message: growthTitle(verdict) + "。已排除可清除空间（快照、缓存）。",
                         agentHint: "用 Mole CLI 的磁盘分析功能找出最近 \(window.days) 天增长最多的目录，先列出来，不要删除")
    }

    static func lowSpaceAlert(verdict: DiskVerdict, since: Date, state: DiskAlertState, now: Date) -> AlertItem? {
        guard verdict.spaceLevel == .red, let avail = verdict.availImportant, let total = verdict.total, total > 0 else { return nil }
        if let last = state.lastLowSpaceNotifiedAt, now.timeIntervalSince(last) < lowSpaceCooldown { return nil }
        let pct = String(format: "%.1f", Double(avail) / Double(total) * 100)
        return AlertItem(type: "disk_low_space", subject: verdict.volume, level: .red, since: since,
                         message: lowSpaceTitle(verdict) + "（占总容量 \(pct)%）。该数值已含可清除空间（快照、缓存）。",
                         agentHint: "用 Mole CLI 的磁盘分析功能找出占用最大的目录，先列出来，不要删除")
    }

    static func record(growth: AlertItem, bytes: Int64, into state: inout DiskAlertState) {
        state.lastGrowthNotifiedBytes = bytes
        state.lastGrowthLevel = growth.level
    }

    static func recordLowSpace(at now: Date, into state: inout DiskAlertState) {
        state.lastLowSpaceNotifiedAt = now
    }

    /// Call after every evaluation. When growth rules are green again, forget the last growth notification.
    static func settle(verdict: DiskVerdict, into state: inout DiskAlertState) {
        if verdict.growthLevel == .green {
            state.lastGrowthNotifiedBytes = nil
            state.lastGrowthLevel = nil
        }
    }
}
