// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Verdicts in problem order, trend points, the disk engine's pending notifications, the wake time.
// Output: The notifications to post, in delivery order (docs/PROJECT.md 5, docs/DESIGN.md 6.9).
// Pos: Pure notification rules shared by the engine and the tests; Foundation only. Owner I1.
//      Events (cooldown): memory red (2 h), CPU load 85 % for 30 min (once per episode), one app at 100 % for 60 min
//      (24 h per app), thermal serious 5 min or critical (1 h), sleep drain red (6 h), awake drain red (6 h, a design
//      addition), disk (the disk engine decides). No recovery message. The budget is consumed in problem order and
//      the posts are delivered in the reverse order, so the most serious one is on top of the notification centre.
//      v2 (WP-B, R-14): a tap on a notification opens the panel and pins the sidebar of `sidebarItem(for:)`.

import Foundation

struct PlannedNotification: Equatable {
    var key: String
    var item: HealthItem
    var level: HealthLevel
    var title: String
    var body: String
    var alert: AlertItem
    /// The topic copied by the action "复制给 Agent".
    var topic: PromptTopic
}

struct NotificationPlannerState: Equatable {
    var lastSent = [String: Date]()
    var cpuLoadSent = false
}

enum NotificationPlanner {
    static let memoryCooldown: TimeInterval = 2 * 3600
    static let cpuAppCooldown: TimeInterval = 24 * 3600
    static let thermalCooldown: TimeInterval = 3600
    static let powerCooldown: TimeInterval = 6 * 3600
    static let cpuLoadMean = 85.0
    static let cpuLoadDuration: TimeInterval = 1800
    static let cpuAppDuration: TimeInterval = 3600
    static let thermalDuration: TimeInterval = 300
    static let wakeQuiet: TimeInterval = 300
    static let bodyTail = "点按查看，或复制给 Agent 排查。"

    /// Events that are due now, in problem order. `state` changes only for the events that are returned: the caller
    /// keeps the new state only when it will deliver them (notifications allowed).
    static func candidates(verdicts: [ItemVerdict], points: [TrendPoint], cpuAppKey: String?, disk: [PendingNotification],
                           wokeAt: Date?, now: Date, state: inout NotificationPlannerState) -> [PlannedNotification] {
        var out = [PlannedNotification]()
        let quiet: Bool = wokeAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < wakeQuiet } ?? false

        func due(_ key: String, cooldown: TimeInterval) -> Bool {
            guard let last = state.lastSent[key] else { return true }
            return now.timeIntervalSince(last) >= cooldown || last > now
        }
        func add(_ key: String, _ v: ItemVerdict, title: String, cooldown: TimeInterval) {
            guard let alert = v.alert, due(key, cooldown: cooldown) else { return }
            let spent = TextFormat.duration(since: v.since, now: now)
            out.append(PlannedNotification(key: key, item: v.item, level: v.level, title: title + " · 已持续 " + spent,
                                           body: alert.message + bodyTail, alert: alert,
                                           topic: ProblemOrder.topic(for: v.item) ?? .disk))
            state.lastSent[key] = now
        }

        for v in verdicts where v.isProblem {
            let spent: TimeInterval = v.since.map { max(0, now.timeIntervalSince($0)) } ?? 0
            switch v.item {
            case .memory:
                if v.level == .red && v.reasonCode == "pressure_critical" {
                    add("memory_critical", v, title: "内存严重不足", cooldown: memoryCooldown)
                }
            case .cpu:
                if quiet { continue }
                if v.reasonCode == "app_saturated" {
                    if spent >= cpuAppDuration {
                        add("cpu_app:" + (cpuAppKey ?? "unknown"), v, title: "有 App 占满 CPU", cooldown: cpuAppCooldown)
                    }
                } else if !state.cpuLoadSent, loadEpisodeDue(points: points, now: now) {
                    state.cpuLoadSent = true
                    add("cpu_load", v, title: "CPU 持续高负载", cooldown: 0)
                }
            case .thermal:
                if quiet { continue }
                let critical: Bool = v.reasonCode == "thermal_critical"
                if critical || (v.reasonCode == "thermal_serious" && spent >= thermalDuration) {
                    add("thermal", v, title: critical ? "温度过高" : "温度很高", cooldown: thermalCooldown)
                }
            case .power:
                if v.level == .red && v.reasonCode == "sleep_drain" {
                    add("power_sleep_drain", v, title: "睡眠掉电异常", cooldown: powerCooldown)
                } else if v.level == .red && v.reasonCode == "awake_drain" {
                    add("power_awake_drain", v, title: "耗电异常", cooldown: powerCooldown)
                }
            case .disk:
                break
            }
        }
        // The CPU load episode ends when the 5 minute mean falls below the limit.
        if state.cpuLoadSent && !loadActive(points: points, now: now) { state.cpuLoadSent = false }

        for p in disk {
            let v: ItemVerdict? = verdicts.first { $0.item == .disk }
            let spent = TextFormat.duration(since: v?.since ?? p.alert.since, now: now)
            out.append(PlannedNotification(key: p.alert.type + ":" + p.alert.subject, item: .disk, level: p.alert.level,
                                           title: p.title + " · 已持续 " + spent, body: p.alert.message + bodyTail,
                                           alert: p.alert, topic: .disk))
        }

        // Problem order: red before yellow, then the order of the verdict list.
        var rank = [HealthItem: Int]()
        for (index, v) in verdicts.enumerated() { rank[v.item] = index }
        return out.enumerated().sorted { a, b in
            let ra = rank[a.element.item] ?? 99
            let rb = rank[b.element.item] ?? 99
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
    }

    /// The 5 minute mean has been at least 85 % for 30 minutes.
    private static func loadEpisodeDue(points: [TrendPoint], now: Date) -> Bool {
        let run = TrendMath.run(points, now: now)
        let value: (TrendPoint) -> Double? = { $0.cpu }
        guard let streak = TrendMath.meanStreak(run, window: 300, value: value, test: { $0 >= cpuLoadMean }) else { return false }
        return streak.duration >= cpuLoadDuration
    }

    private static func loadActive(points: [TrendPoint], now: Date) -> Bool {
        let run = TrendMath.run(points, now: now)
        let value: (TrendPoint) -> Double? = { $0.cpu }
        return TrendMath.meanStreak(run, window: 300, value: value, test: { $0 >= cpuLoadMean }) != nil
    }

    /// The sidebar that a tap on the notification of `item` pins (docs/DESIGN_V2.md 14.3 boundary "通知点击 R-14").
    /// The power item shows in the battery sidebar. Nil means the panel opens without a pinned sidebar.
    static func sidebarItem(for item: HealthItem?) -> SidebarItem? {
        guard let item else { return nil }
        switch item {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .thermal: return .thermal
        case .power: return .battery
        }
    }

    /// Consumes the budget in priority order and returns the posts in delivery order (reverse of priority).
    /// A candidate that the budget refuses is dropped: it shows only on the card.
    static func schedule(_ candidates: [PlannedNotification], budget: inout NotificationBudget, now: Date) -> [PlannedNotification] {
        var granted = [PlannedNotification]()
        for c in candidates where budget.tryConsume(now: now) { granted.append(c) }
        return granted.reversed()
    }
}
