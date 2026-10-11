// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now) from main.swift; gen and pt from HealthRuleTests.swift.
// Output: Assertions for HealthPipeline, the status.json extras, the CLI prompt input and NotificationPlanner.
// Pos: Called from main.swift via runPipelineTests(); no top-level code in this file. Owner I1.

import Foundation

func runPipelineTests() {
    runPipelineEvalTests()
    runStatusExtrasTests()
    runPromptConsistencyTests()
    runPlannerTests()
}

private func alertFor(_ item: HealthItem, _ level: HealthLevel, type: String, since: Date) -> AlertItem {
    AlertItem(type: type, subject: item.rawValue, level: level, since: since, message: item.label + "出现问题。", agentHint: "")
}

private func verdict(_ item: HealthItem, _ level: HealthLevel, _ code: String, minutesAgo: Double, type: String) -> ItemVerdict {
    let since = now.addingTimeInterval(-minutesAgo * 60)
    return ItemVerdict(item: item, level: level, reasonCode: code, headline: "标题", since: since, levelChangedAt: since,
                       alert: alertFor(item, level, type: type, since: since))
}

private func runPipelineEvalTests() {
    section("HealthPipeline")
    // 40 minutes of critical pressure with growing swap, on a 16 GiB Mac with a battery.
    var points = gen(-70, 0) { m in
        pt(m, cpu: 30, pressure: .critical, swap: Int64(8_000_000_000 + (m + 70) * 50_000_000), thermal: .nominal, battery: 80, power: .battery)
    }
    var cur = CurrentReadings()
    cur.physicalMemory = 17_179_869_184
    cur.sampledAt = now
    var input = PipelineInput(points: points, hasBattery: true, current: cur, now: now)
    var state = PipelineState()
    let out = HealthPipeline.evaluate(input, state: &state)
    let memory = out.verdicts.first { $0.item == .memory }
    expect(out.verdicts.count == 5, "five items with a battery")
    expect(memory?.level == .red && memory?.reasonCode == "pressure_critical", "memory is red: \(String(describing: memory?.reasonCode))")
    expect(out.problems.first?.item == .memory && out.verdicts.first?.item == .memory, "the problem is first in the list")
    expect(memory?.alert?.type == "memory_pressure", "an alert is attached to the memory verdict")
    expect(memory?.levelChangedAt != nil && memory?.since != nil, "levelChangedAt is set for a problem on the first run")
    expect(out.verdicts.first { $0.item == .disk }?.level == .unknown, "a missing disk verdict is unknown")
    expect(out.current.cpuMean5m.map { abs($0 - 30) < 0.01 } ?? false, "cpuMean5m is derived")
    expect(out.current.swapGrowth30m != nil && out.current.swapTrend != nil, "swap growth and trend are derived")
    expect(out.current.awakeDrainPerHour.map { abs($0) < 0.01 } ?? false, "flat battery gives an awake drain of 0")
    // The level change is stamped on the next change only.
    let firstChange = memory?.levelChangedAt
    points.append(pt(0.5, cpu: 30, pressure: .critical, swap: 8_000_000_000, thermal: .nominal, battery: 80, power: .battery))
    input.points = points
    input.now = now.addingTimeInterval(30)
    let again = HealthPipeline.evaluate(input, state: &state)
    expect(again.verdicts.first { $0.item == .memory }?.levelChangedAt == firstChange, "levelChangedAt stays while the level stays")
    var calm = gen(0.5, 30) { pt($0, cpu: 20, pressure: .normal, swap: 8_000_000_000, thermal: .nominal, battery: 80, power: .battery) }
    calm.insert(contentsOf: points, at: 0)
    input.points = calm
    input.now = now.addingTimeInterval(30 * 60)
    let later = HealthPipeline.evaluate(input, state: &state)
    let after = later.verdicts.first { $0.item == .memory }
    expect(after?.level != .red, "memory leaves red after 5 minutes of normal pressure")
    expect(after?.levelChangedAt.map { $0 > firstChange ?? now } ?? false, "levelChangedAt moves on a level change")
    // No battery: the power item does not exist.
    input.hasBattery = false
    var fresh = PipelineState()
    expect(HealthPipeline.evaluate(input, state: &fresh).verdicts.count == 4, "four items without a battery")
    // Disk verdict from the status item.
    let f = PreviewScenario.fixture(.diskRed, full: true, now: now)
    let d = HealthPipeline.diskVerdict(item: f.status.items.disk, alerts: f.status.activeAlerts)
    expect(d.level == .red && d.reasonCode == "growth_5d" && d.headline == "5 天多占用 314 GB", "disk verdict headline: \(d.headline)")
    expect(d.alert?.type == "disk_growth" && d.since != nil, "disk verdict alert and start")
    let g = PreviewScenario.fixture(.allGreen, full: true, now: now)
    let dg = HealthPipeline.diskVerdict(item: g.status.items.disk, alerts: g.status.activeAlerts)
    expect(dg.level == .green && dg.since == nil && dg.alert == nil, "a healthy disk has no start and no alert")
    let c = PreviewScenario.fixture(.collecting, full: true, now: now)
    let dc = HealthPipeline.diskVerdict(item: c.status.items.disk, alerts: [])
    expect(dc.level == .unknown && dc.reasonCode == "collecting", "no data: collecting")
    // The input with disk set is passed through.
    var withDisk = input
    withDisk.disk = d
    var s2 = PipelineState()
    let o2 = HealthPipeline.evaluate(withDisk, state: &s2)
    expect(o2.verdicts.first { $0.item == .disk }?.alert?.type == "disk_growth", "the disk alert is kept")
}

private func fullStatus(_ c: PreviewCase) -> (StatusFile, PreviewFixture) {
    let f = PreviewScenario.fixture(c, full: true, now: now)
    var status = f.status
    let input = PreviewScenario.promptInput(c, now: now)
    status.items.memory = StatusExtras.itemStatus(for: f.verdicts.first { $0.item == .memory }!, current: f.current, cpuSummary: input.cpuSummary)
    status.items.cpu = StatusExtras.itemStatus(for: f.verdicts.first { $0.item == .cpu }!, current: f.current, cpuSummary: input.cpuSummary)
    status.items.thermal = StatusExtras.itemStatus(for: f.verdicts.first { $0.item == .thermal }!, current: f.current, cpuSummary: input.cpuSummary)
    status.items.power = StatusExtras.itemStatus(for: f.verdicts.first { $0.item == .power }!, current: f.current, cpuSummary: input.cpuSummary)
    status.activeAlerts = f.verdicts.compactMap { $0.alert }
    status.topApps = StatusExtras.topApps(f.apps, coverage: ProcessCoverage(readable: 300, unreadable: 40), sampledAt: now, basis: "5m")
    status.env = StatusExtras.env(PreviewScenario.fixtureEnvironment)
    status.promptPrefs = PromptPrefs(includeAppNames: true)
    return (status, f)
}

private func runStatusExtrasTests() {
    section("status.json extras")
    let (status, _) = fullStatus(.multi)
    let encoder = CoreJSON.encoder()
    guard let data = try? encoder.encode(status), let back = try? CoreJSON.decoder().decode(StatusFile.self, from: data) else {
        expect(false, "a status with the extras encodes and decodes")
        return
    }
    let text = String(decoding: data, as: UTF8.self)
    expect(text.contains("\"top_apps\"") && text.contains("\"prompt_prefs\"") && text.contains("\"include_app_names\":true"), "new keys are snake_case")
    expect(text.contains("\"swap_growth_30m\"") && text.contains("\"reason_code\":\"pressure_critical\"") && text.contains("\"awake_drain_per_hour\""), "item keys are snake_case")
    expect(back.items.memory == status.items.memory && back.items.power == status.items.power, "memory and power items round-trip")
    expect(back.items.cpu == status.items.cpu && back.items.thermal == status.items.thermal, "cpu and thermal items round-trip")
    expect(back.topApps == status.topApps && back.env == status.env && back.promptPrefs == status.promptPrefs, "top apps, env and prefs round-trip")
    expect(back.items.power?.powerSource == "battery" && back.items.memory?.pressure == .critical, "readings survive the round trip")
    // Old file: no new keys at all.
    let (plain, _) = (PreviewScenario.fixture(.diskRed, full: true, now: now).status, 0)
    guard let oldData = try? encoder.encode(plain) else { expect(false, "plain status encodes"); return }
    let oldText = String(decoding: oldData, as: UTF8.self)
    expect(!oldText.contains("top_apps") && !oldText.contains("prompt_prefs") && !oldText.contains("\"memory\""), "nil extras are left out")
    guard let old = try? CoreJSON.decoder().decode(StatusFile.self, from: oldData) else { expect(false, "an old file decodes"); return }
    expect(old.items.memory == nil && old.topApps == nil && old.env == nil && old.promptPrefs == nil, "an old file has nil extras")
    let v = StatusExtras.verdicts(from: old)
    expect(v.count == 5 && v.first?.item == .disk && v.first?.level == .red, "old file: the disk problem is first")
    expect(v.filter { $0.reasonCode == "missing" }.count == 4, "old file: four items are missing, not green")
    let input = StatusExtras.promptInput(status: old, freshness: StatusStore.Freshness(fresh: true, ageSeconds: 10, appRunning: true),
                                         cliPath: "x", dataDir: "y", timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current)
    expect(input.apps.isEmpty && input.env.os == "未知", "old file: no apps, unknown os")
    let promptText = PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(promptText.contains("磁盘") && !promptText.isEmpty, "old file: a prompt can still be built")

    // top_apps: union of the top 8 by CPU and the top 8 by memory, at most 16.
    var apps = [AppUsage]()
    for i in 0..<30 {
        let cpu = Double(100 - i)
        let mem = Int64(i) * 200_000_000 + 60_000_000
        apps.append(AppUsage(key: "k\(i)", name: "App\(i)", bundleID: nil, cpuPercent: cpu, memoryBytes: mem, memoryBasis: "footprint",
                             processCount: 1, isSystem: false))
    }
    let top = StatusExtras.topApps(apps, coverage: nil, sampledAt: now, basis: "5m")
    expect(top?.apps.count == 16, "30 apps: 16 entries")
    let names = Set((top?.apps ?? []).map { $0.name })
    expect(names.contains("App0") && names.contains("App7") && names.contains("App29") && names.contains("App22"), "union of both top 8")
    expect(!names.contains("App10") && !names.contains("App15"), "the middle is left out")
    var overlap = apps
    overlap = overlap.map { var a = $0; a.memoryBytes = Int64(1_000_000_000 - (Int64($0.name.dropFirst(3)) ?? 0) * 1_000_000); return a }
    expect(StatusExtras.topApps(overlap, coverage: nil, sampledAt: now, basis: "5m")?.apps.count == 8, "the same apps in both lists count once")
    expect(StatusExtras.topApps([], coverage: nil, sampledAt: now, basis: "5m") == nil, "no apps: no field")
    // Overall roll-up.
    let multi = PreviewScenario.fixture(.multi, full: true, now: now)
    let overall = StatusExtras.overall(verdicts: multi.verdicts, diskSummary: "x")
    expect(overall.level == .red && overall.summary.hasPrefix("磁盘："), "overall: worst level, first problem: \(overall.summary)")
    let calm = PreviewScenario.fixture(.allGreen, full: true, now: now)
    expect(StatusExtras.overall(verdicts: calm.verdicts, diskSummary: "磁盘正常").level == .green, "overall: green")
    expect(StatusExtras.item(forAlertType: "power_awake_drain") == .power && StatusExtras.item(forAlertType: "disk_low_space") == .disk
           && StatusExtras.item(forAlertType: "thermal") == .thermal && StatusExtras.item(forAlertType: "other") == nil, "alert type owners")
}

private func runPromptConsistencyTests() {
    section("App and CLI build the same prompt")
    let zone = TimeZone(identifier: "UTC") ?? TimeZone.current
    for c in PreviewCase.allCases where c != .stale {
        let (status, f) = fullStatus(c)
        let freshness = StatusStore.Freshness(fresh: true, ageSeconds: 0, appRunning: true)
        var cli = StatusExtras.promptInput(status: status, freshness: freshness, cliPath: PreviewScenario.fixtureEnvironment.cliPath,
                                           dataDir: PreviewScenario.fixtureEnvironment.dataDir, timeZone: zone)
        var app = PreviewScenario.promptInput(c, now: now)
        app.appsBasis = cli.appsBasis
        // The CLI knows the apps only through top_apps, so compare with the same entries.
        cli.apps = app.apps.isEmpty ? [] : cli.apps
        for scope in [PromptScope.overview, PromptScope.topic(.cpu), PromptScope.topic(.disk), PromptScope.topic(.power)] {
            let a = PromptBuilder.build(app, scope: scope, options: PreviewScenario.fixturePromptOptions)
            let b = PromptBuilder.build(cli, scope: scope, options: PreviewScenario.fixturePromptOptions)
            expect(a == b, "\(c.rawValue) \(scope): CLI text equals app text")
            if a != b {
                let la = a.components(separatedBy: "\n")
                let lb = b.components(separatedBy: "\n")
                for i in 0..<min(la.count, lb.count) where la[i] != lb[i] { print("  A: \(la[i])\n  B: \(lb[i])"); break }
            }
        }
        _ = f
    }
    // A stale status keeps the last levels and names the age. The fixture "stale" shows the app's own stale state.
    let (status, _) = fullStatus(.cpuYellow)
    let staleInput = StatusExtras.promptInput(status: status, freshness: StatusStore.Freshness(fresh: false, ageSeconds: 25 * 60, appRunning: true),
                                              cliPath: "c", dataDir: "d", timeZone: zone)
    expect(staleInput.freshness == .stale(minutes: 25), "stale status: freshness text")
    let down = StatusStore.Freshness(fresh: false, ageSeconds: 90 * 60, appRunning: false)
    let input = StatusExtras.promptInput(status: status, freshness: down, cliPath: "c", dataDir: "d", timeZone: zone)
    expect(input.freshness == .notRunning(minutes: 90), "app not running: freshness text")
    expect(input.appsBasis == "采样于 12:00", "the CLI names the scan time: \(input.appsBasis)")
}

private func runPlannerTests() {
    section("NotificationPlanner")
    let quietPoints = gen(-40, 0) { pt($0, cpu: 20) }
    func plan(_ verdicts: [ItemVerdict], points: [TrendPoint]? = nil, disk: [PendingNotification] = [], woke: Date? = nil,
              at: Date = now, state: inout NotificationPlannerState) -> [PlannedNotification] {
        NotificationPlanner.candidates(verdicts: verdicts, points: points ?? quietPoints, cpuAppKey: "com.example.kiln", disk: disk,
                                       wokeAt: woke, now: at, state: &state)
    }
    var state = NotificationPlannerState()
    // Memory.
    let red = verdict(.memory, .red, "pressure_critical", minutesAgo: 32, type: "memory_pressure")
    let c1 = plan([red], state: &state)
    expect(c1.count == 1 && c1[0].title == "内存严重不足 · 已持续 32 分", "memory red title: \(c1.first?.title ?? "")")
    expect(c1.first?.body.hasSuffix("点按查看，或复制给 Agent 排查。") ?? false && c1.first?.topic == .memory, "body tail and topic")
    expect(plan([red], at: now.addingTimeInterval(3600), state: &state).isEmpty, "memory red: 2 h cooldown")
    expect(plan([red], at: now.addingTimeInterval(2 * 3600 + 1), state: &state).count == 1, "memory red: after 2 h again")
    var s2 = NotificationPlannerState()
    let yellowMem = verdict(.memory, .yellow, "pressure_warning", minutesAgo: 60, type: "memory_pressure")
    expect(plan([yellowMem], state: &s2).isEmpty, "memory yellow: no notification")
    // No recovery message: a green list gives nothing.
    let green = ItemVerdict(item: .memory, level: .green, reasonCode: "ok", headline: "ok", since: nil, levelChangedAt: nil, alert: nil)
    expect(plan([green], state: &s2).isEmpty, "recovery: no message")
    // Thermal.
    var s3 = NotificationPlannerState()
    let serious3 = verdict(.thermal, .yellow, "thermal_serious", minutesAgo: 3, type: "thermal")
    expect(plan([serious3], state: &s3).isEmpty, "thermal serious for 3 min: not yet")
    let serious6 = verdict(.thermal, .red, "thermal_serious", minutesAgo: 6, type: "thermal")
    expect(plan([serious6], state: &s3).count == 1, "thermal serious for 6 min: notify")
    expect(plan([serious6], state: &s3).isEmpty, "thermal: 1 h cooldown")
    var s4 = NotificationPlannerState()
    let crit = verdict(.thermal, .red, "thermal_critical", minutesAgo: 0, type: "thermal")
    expect(plan([crit], state: &s4).first?.title.hasPrefix("温度过高") ?? false, "thermal critical: at once")
    // Quiet time after wake: no CPU and no thermal, but memory goes on.
    var s5 = NotificationPlannerState()
    let woke = now.addingTimeInterval(-120)
    expect(plan([crit], woke: woke, state: &s5).isEmpty, "wake: thermal is quiet for 5 min")
    expect(plan([red], woke: woke, state: &s5).count == 1, "wake: memory is not quiet")
    expect(plan([crit], woke: woke, at: now.addingTimeInterval(240), state: &s5).count == 1, "wake: thermal after the quiet time")
    // CPU load: 85 % for 30 minutes, once per episode.
    var s6 = NotificationPlannerState()
    let hot = gen(-45, 0) { pt($0, cpu: 92) }
    let cpuV = verdict(.cpu, .red, "cpu_mean_10m", minutesAgo: 40, type: "cpu_load")
    let n1 = plan([cpuV], points: hot, state: &s6)
    expect(n1.count == 1 && n1[0].title.hasPrefix("CPU 持续高负载"), "cpu load: notify after 30 min")
    expect(plan([cpuV], points: hot, at: now.addingTimeInterval(30), state: &s6).isEmpty, "cpu load: once per episode")
    let shortHot = gen(-20, 0) { pt($0, cpu: 92) }
    var s7 = NotificationPlannerState()
    expect(plan([cpuV], points: shortHot, state: &s7).isEmpty, "cpu load: 20 min is not enough")
    // The episode ends when the mean falls, then a new one can notify.
    let cooled = hot + gen(0.5, 10) { pt($0, cpu: 10) }
    _ = plan([cpuV], points: cooled, at: now.addingTimeInterval(600), state: &s6)
    expect(s6.cpuLoadSent == false, "cpu load: episode reset after a cool-down")
    // Single app: 60 minutes, 24 h per app.
    var s8 = NotificationPlannerState()
    let appShort = verdict(.cpu, .yellow, "app_saturated", minutesAgo: 40, type: "cpu_app")
    let appLong = verdict(.cpu, .yellow, "app_saturated", minutesAgo: 70, type: "cpu_app")
    expect(plan([appShort], state: &s8).isEmpty, "single app: 40 min is not enough")
    let appN = plan([appLong], state: &s8)
    expect(appN.count == 1 && appN[0].key == "cpu_app:com.example.kiln", "single app: 70 min notifies per app key")
    expect(plan([appLong], at: now.addingTimeInterval(3600 * 5), state: &s8).isEmpty, "single app: 24 h cooldown")
    // Power: red only, 6 h.
    var s9 = NotificationPlannerState()
    let awakeYellow = verdict(.power, .yellow, "awake_drain", minutesAgo: 30, type: "power_awake_drain")
    let awakeRed = verdict(.power, .red, "awake_drain", minutesAgo: 130, type: "power_awake_drain")
    let sleepRed = verdict(.power, .red, "sleep_drain", minutesAgo: 20, type: "power_sleep_drain")
    expect(plan([awakeYellow], state: &s9).isEmpty, "awake drain yellow: no notification")
    let pn = plan([awakeRed], state: &s9)
    expect(pn.count == 1 && pn[0].key == "power_awake_drain" && pn[0].title == "耗电异常 · 已持续 2 小时 10 分", "awake drain red: \(pn.first?.title ?? "")")
    expect(plan([awakeRed], at: now.addingTimeInterval(3 * 3600), state: &s9).isEmpty, "awake drain: 6 h cooldown")
    var s10 = NotificationPlannerState()
    expect(plan([sleepRed], state: &s10).first?.key == "power_sleep_drain", "sleep drain red notifies")

    // Disk events come from the disk engine; problem order and the budget.
    var s11 = NotificationPlannerState()
    let diskV = verdict(.disk, .red, "growth_5d", minutesAgo: 180, type: "disk_growth")
    let diskPending = PendingNotification(alert: diskV.alert!, title: "磁盘 5 天多占用了 314 GB")
    let both = plan([diskV, red, verdict(.power, .red, "awake_drain", minutesAgo: 10, type: "power_awake_drain")], disk: [diskPending], state: &s11)
    expect(both.map { $0.item } == [.disk, .memory, .power], "candidates follow the verdict order: \(both.map { $0.item.rawValue })")
    expect(both[0].title == "磁盘 5 天多占用了 314 GB · 已持续 3 小时 0 分", "disk title gets the duration: \(both[0].title)")
    var budget = NotificationBudget()
    let sent = NotificationPlanner.schedule(both, budget: &budget, now: now)
    expect(sent.map { $0.item } == [.power, .memory, .disk], "delivery is in reverse order")
    var tight = NotificationBudget(perHour: 2, perDay: 10)
    let part = NotificationPlanner.schedule(both, budget: &tight, now: now)
    expect(part.map { $0.item } == [.memory, .disk], "the budget goes to the most serious first: \(part.map { $0.item.rawValue })")
    expect(NotificationPlanner.schedule(both, budget: &tight, now: now.addingTimeInterval(60)).isEmpty, "budget is spent")
}
