// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: StatusFile and its freshness.
// Output: One short Chinese line for `--status --brief`.
// Pos: CLI text output; pure function.

import Foundation

/// Format: `磁盘 <级别>（<细节>）` plus an optional suffix when data is not fresh.
///   磁盘 红（5 天 +312 GB）          growth rule, window and growth
///   磁盘 红（剩余 12 GB）            free-space rule
///   磁盘 绿（剩余 412 GB）           normal
///   磁盘 黄（回落观察）              hysteresis hold or recovering
///   磁盘 未知                        no figure available
/// Suffix: ` · App 未运行（数据 2 小时前）` or ` · 数据已过期（12 分钟前）`.
enum Brief {
    static func line(_ s: StatusFile, freshness: StatusStore.Freshness) -> String {
        let d = s.items.disk
        var detail: String?
        switch d.reasonCode {
        case "growth_1d", "growth_5d":
            let key = d.reasonCode == "growth_1d" ? "1d" : "5d"
            if let b = d.growth[key]?.bytes { detail = "\(key.dropLast()) 天 +\(ByteText.gb(b))" }
        case "hold", "recovering":
            detail = "回落观察"
        default:
            if let a = d.availableImportant.value { detail = "剩余 \(ByteText.gb(a))" }
        }
        var out = "磁盘 \(d.level.label)"
        if let detail { out += "（\(detail)）" }
        if !freshness.fresh {
            let age = ageText(freshness.ageSeconds)
            out += freshness.appRunning ? " · 数据已过期（\(age)）" : " · App 未运行（数据 \(age)）"
        }
        return out
    }

    static func ageText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}
