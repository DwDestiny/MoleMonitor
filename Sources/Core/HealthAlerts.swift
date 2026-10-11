// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A problem verdict and the current readings (docs/DESIGN.md 6.9, 7.4).
// Output: The AlertItem that belongs to the verdict: one evidence sentence and one agent hint.
// Pos: Shared by the engine, the fixtures and the notification planner; Foundation only. Owner I1.
//      Messages carry no duration: "已持续" is shown next to them. No App name appears except in the CPU
//      single-app message, which the prompt hides when the setting "包含 App 名称" is off.

import Foundation

enum HealthAlerts {
    /// The alert of a yellow or red verdict. Disk keeps the alert of the disk engine, so this returns the verdict's own
    /// alert for disk and nil for a verdict that is not a problem.
    static func alert(for v: ItemVerdict, current: CurrentReadings) -> AlertItem? {
        guard v.isProblem, let since = v.since else { return nil }
        if v.item == .disk { return v.alert }
        let text: (type: String, message: String, hint: String)
        switch v.item {
        case .memory:
            var message: String
            switch v.reasonCode {
            case "pressure_critical": message = "内存压力严重"
            case "pressure_warning": message = "内存压力为警告"
            default: message = "内存 swap 在增长"
            }
            if let swap = current.swapUsed { message += "，swap " + TextFormat.bytes(swap) }
            if let g = current.swapGrowth30m, g > 0 { message += "，30 分钟增加 " + TextFormat.bytes(g) }
            text = ("memory_" + (v.reasonCode.hasPrefix("pressure") ? "pressure" : "swap"), message + "。",
                    "用 vm_stat 与 ps 找出占用内存最多的 App，先列出来，不要结束进程")
        case .cpu:
            if v.reasonCode == "app_saturated" {
                text = ("cpu_app", v.headline + "。", "找出该 App 的进程，说明它在做什么，先建议正常退出，不要直接结束")
            } else {
                let window = v.reasonCode == "cpu_mean_10m" ? "10" : "5"
                text = ("cpu_load", "CPU " + window + " 分钟均值持续偏高。", "找出占用 CPU 最高的进程，说明用途，先建议正常退出，不要直接结束")
            }
        case .thermal:
            text = ("thermal", v.headline + "。", "对照 CPU 占用找出热源，只建议降低负载，不要控制风扇")
        case .power:
            let message = v.reasonCode == "awake_drain" ? "整机耗电异常：" + v.headline + "。" : v.headline + "。"
            text = ("power_" + v.reasonCode, message, "用 pmset -g assertions 找出阻止睡眠或耗电的进程，只读，不要改电源设置")
        case .disk:
            return v.alert
        }
        return AlertItem(type: text.type, subject: v.item.rawValue, level: v.level, since: since,
                         message: text.message, agentHint: text.hint)
    }
}
