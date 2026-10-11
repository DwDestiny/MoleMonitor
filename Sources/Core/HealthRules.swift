// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points, app windows, sleep records and the current time (docs/DESIGN.md 8.1, 6.7, 6.8; PROJECT.md 3.2 to 3.6).
// Output: One ItemVerdict per health item, with hysteresis state kept in RuleMemory.
// Pos: CPU, memory, thermal and power rules; pure functions, Foundation only. Owner I1.
//      Every rule is a sub-rule with its own level. The item level is the highest sub-rule level.
//      Without data the verdict is unknown ("collecting") until one sub-rule has judged once.
//      A level is held while a window is too short to judge (after sleep or restart).

import Foundation

/// The level of one sub-rule and when its problem started.
struct SubRule: Codable, Equatable {
    var level: HealthLevel = .green
    var since: Date?
    /// True after the sub-rule judged once.
    var known = false
}

/// Hysteresis state of all rules. Not written to disk: a restart recomputes it from the restored trend.
struct RuleMemory: Codable, Equatable {
    var cpuMachine = SubRule()
    var cpuApp = SubRule()
    var cpuAppKey: String?
    var cpuAppName: String?
    var memoryPressure = SubRule()
    var memorySwap = SubRule()
    var thermal = SubRule()
    var powerAwake = SubRule()
}

enum Hysteresis {
    /// One step of the state machine (PROJECT.md 3.1): an upgrade may jump, a downgrade drops one level per call.
    /// `enter` is the highest level whose entry condition holds now. `exitHolds` is the exit condition of the
    /// current level. Nothing changes when `canJudge` is false.
    static func step(_ s: inout SubRule, enter: HealthLevel, enterSince: Date?, exitHolds: Bool,
                     canJudge: Bool, now: Date) {
        guard canJudge else { return }
        s.known = true
        let current = s.level
        if enter != .green && enter.severity >= current.severity {
            if current == .green { s.since = enterSince ?? now }
            s.level = enter
        } else if current != .green && exitHolds {
            s.level = (current == .red) ? .yellow : .green
            if s.level == .green { s.since = nil }
        }
    }
}

private func earliest(_ dates: [Date?]) -> Date? {
    var best: Date?
    for d in dates {
        guard let d else { continue }
        if let b = best, b <= d { continue }
        best = d
    }
    return best
}

extension TrendMath {
    /// The trailing stretch where the rolling `window` mean satisfies `test`.
    static func meanStreak(_ run: [TrendPoint], window: TimeInterval, value: (TrendPoint) -> Double?,
                           test: (Double) -> Bool) -> (start: Date, duration: TimeInterval)? {
        guard !run.isEmpty else { return nil }
        var means = [Double?](repeating: nil, count: run.count)
        var i = run.count - 1
        var lowest = run.count
        while i >= 0 {
            let m = mean(run, end: i, window: window, value: value)
            if let m, test(m) {
                means[i] = m
                lowest = i
                i -= 1
            } else {
                break
            }
        }
        guard lowest < run.count, means[run.count - 1] != nil else { return nil }
        return (run[lowest].t, run[run.count - 1].t.timeIntervalSince(run[lowest].t))
    }
}

/// Item verdict from sub-rules: highest level, earliest problem start.
private struct Combined {
    var level: HealthLevel
    var since: Date?
}

private func combine(_ subs: [SubRule]) -> Combined {
    let known = subs.filter { $0.known }
    guard !known.isEmpty else { return Combined(level: .unknown, since: nil) }
    var level = HealthLevel.green
    for s in known where s.level.severity > level.severity { level = s.level }
    let starts: [Date?] = known.filter { $0.level != .green }.map { $0.since }
    return Combined(level: level, since: earliest(starts))
}

private func verdict(_ item: HealthItem, _ c: Combined, code: String, headline: String, now: Date) -> ItemVerdict {
    ItemVerdict(item: item, level: c.level, reasonCode: code, headline: headline,
                since: (c.level == .yellow || c.level == .red) ? c.since : nil,
                levelChangedAt: nil, alert: nil)
}

/// `hasData` is false when no point of the run carries the reading this item needs.
private func collecting(_ item: HealthItem, run: [TrendPoint], hasData: Bool) -> ItemVerdict {
    let missing = !hasData && run.count >= 3
    return ItemVerdict(item: item, level: .unknown, reasonCode: missing ? "missing" : "collecting",
                       headline: missing ? "暂无读数" : "统计中", since: nil, levelChangedAt: nil, alert: nil)
}

// MARK: - CPU

enum CPUHealth {
    static let machineYellowEnter = 70.0
    static let machineYellowExit = 55.0
    static let machineRedEnter = 90.0
    static let machineRedExit = 75.0
    static let appEnter = 90.0
    static let appExit = 50.0
    static let appWindow: TimeInterval = 1800

    static func evaluate(points: [TrendPoint], apps: [AppWindowStat], now: Date,
                         state: inout RuleMemory) -> ItemVerdict {
        let run = TrendMath.run(points, now: now)
        let cpu: (TrendPoint) -> Double? = { $0.cpu }

        // Whole machine.
        if !run.isEmpty, TrendMath.mean(run, end: run.count - 1, window: 300, value: cpu) != nil {
            let yellowStreak = TrendMath.meanStreak(run, window: 300, value: cpu) { $0 >= CPUHealth.machineYellowEnter }
            let redStreak = TrendMath.meanStreak(run, window: 600, value: cpu) { $0 >= CPUHealth.machineRedEnter }
            var enter = HealthLevel.green
            var starts = [Date?]()
            if TrendMath.lasted(yellowStreak, 300) {
                enter = .yellow
                starts.append(yellowStreak?.start)
            }
            if TrendMath.lasted(redStreak, 600) {
                enter = .red
                starts.append(redStreak?.start)
            }
            let exitRed = TrendMath.lasted(
                TrendMath.meanStreak(run, window: 300, value: cpu) { $0 < CPUHealth.machineRedExit }, 180)
            let exitYellow = TrendMath.lasted(
                TrendMath.meanStreak(run, window: 300, value: cpu) { $0 < CPUHealth.machineYellowExit }, 120)
            let exit = state.cpuMachine.level == .red ? exitRed : exitYellow
            Hysteresis.step(&state.cpuMachine, enter: enter, enterSince: earliest(starts), exitHolds: exit,
                            canJudge: true, now: now)
        }

        // One app that keeps one core busy (PROJECT.md 3.2). The window start stands for the problem start.
        if !apps.isEmpty {
            var hot: AppWindowStat?
            for a in apps {
                guard let m = a.mean30m, m >= CPUHealth.appEnter else { continue }
                if let h = hot, let hm = h.mean30m, hm >= m { continue }
                hot = a
            }
            if let hot {
                state.cpuAppKey = hot.key
                state.cpuAppName = hot.name
            }
            var exit = false
            if let key = state.cpuAppKey {
                let tracked = apps.first { $0.key == key }
                if let tracked {
                    if let m10 = tracked.mean10m { exit = m10 < CPUHealth.appExit }
                } else {
                    exit = true
                }
            }
            Hysteresis.step(&state.cpuApp, enter: hot == nil ? .green : .yellow,
                            enterSince: now.addingTimeInterval(-CPUHealth.appWindow), exitHolds: exit,
                            canJudge: true, now: now)
            if state.cpuApp.level == .green {
                state.cpuAppKey = nil
                state.cpuAppName = nil
            }
        }

        let combined = combine([state.cpuMachine, state.cpuApp])
        if combined.level == .unknown { return collecting(.cpu, run: run, hasData: run.contains { $0.cpu != nil }) }

        // Text: the machine rule wins a tie, because it is the bigger signal.
        let machine = state.cpuMachine
        let app = state.cpuApp
        if machine.known, machine.level.severity >= app.level.severity, machine.level != .green {
            let window = machine.level == .red ? 600.0 : 300.0
            let m = TrendMath.mean(run, end: max(0, run.count - 1), window: window, value: cpu)
            let label = machine.level == .red ? "10 分钟均值 " : "5 分钟均值 "
            let code = machine.level == .red ? "cpu_mean_10m" : "cpu_mean_5m"
            var v = verdict(.cpu, combined, code: code, headline: label + TextFormat.percent(m), now: now)
            if m == nil { v.headline = "CPU 持续偏高" }
            return v
        }
        if app.known, app.level != .green {
            let name = state.cpuAppName ?? "某个 App"
            return verdict(.cpu, combined, code: "app_saturated", headline: name + " 占满一个核", now: now)
        }
        let mean5 = run.isEmpty ? nil : TrendMath.mean(run, end: run.count - 1, window: 300, value: cpu)
        let text = mean5 == nil ? "CPU 正常" : "CPU 5 分钟均值 " + TextFormat.percent(mean5)
        return verdict(.cpu, combined, code: "ok", headline: text, now: now)
    }
}

// MARK: - Memory

enum MemoryHealth {
    static let swapYellowAbsolute: Int64 = 2 * 1_073_741_824
    static let swapYellowFraction = 0.125
    static let swapSmall: Int64 = 512 * 1_048_576

    /// Growth of the swap file over the last 30 minutes. Nil without a point near 30 minutes ago.
    static func swapGrowth30m(points: [TrendPoint], now: Date) -> Int64? {
        let withSwap: [TrendPoint] = points.filter { $0.swapUsed != nil }
        guard let latest = withSwap.last, now.timeIntervalSince(latest.t) <= TrendMath.maxGap,
              let nowValue = latest.swapUsed else { return nil }
        let target = latest.t.addingTimeInterval(-1800)
        guard let ref = TrendMath.nearest(withSwap, to: target, tolerance: 120), let old = ref.swapUsed,
              ref.t < latest.t else { return nil }
        return nowValue - old
    }

    static func swapTrend(points: [TrendPoint], physicalBytes: Int64, now: Date) -> SwapTrend? {
        guard let growth = swapGrowth30m(points: points, now: now) else { return nil }
        let steep = max(swapYellowAbsolute, Int64(Double(physicalBytes) * swapYellowFraction))
        if growth >= steep { return .steepUp }
        if growth >= swapSmall { return .up }
        if growth <= -swapSmall { return .down }
        return .flat
    }

    static func evaluate(points: [TrendPoint], physicalBytes: Int64, now: Date,
                         state: inout RuleMemory) -> ItemVerdict {
        let run = TrendMath.run(points, now: now)
        let pressureOf: (Int) -> MemoryPressure? = { run[$0].pressure }

        // Pressure: warning for 60 s, critical for 30 s. Exit: normal for 5 min, at most warning for 5 min.
        if let latest = run.last?.pressure {
            let atLeastWarning = TrendMath.streak(run) { pressureOf($0).map { $0.rank >= 1 } }
            let critical = TrendMath.streak(run) { pressureOf($0).map { $0.rank >= 2 } }
            var enter = HealthLevel.green
            var starts = [Date?]()
            if TrendMath.lasted(atLeastWarning, 60) {
                enter = .yellow
                starts.append(atLeastWarning?.start)
            }
            if TrendMath.lasted(critical, 30) {
                enter = .red
                starts.append(critical?.start)
            }
            let normal = TrendMath.streak(run) { pressureOf($0).map { $0.rank == 0 } }
            let notCritical = TrendMath.streak(run) { pressureOf($0).map { $0.rank <= 1 } }
            let exit = state.memoryPressure.level == .red ? TrendMath.lasted(notCritical, 300) : TrendMath.lasted(normal, 300)
            _ = latest
            Hysteresis.step(&state.memoryPressure, enter: enter, enterSince: earliest(starts), exitHolds: exit,
                            canJudge: true, now: now)
        }

        // Swap growth in 30 minutes: yellow at max(2 GiB, 12.5 % of memory), exit below 512 MiB.
        let growth = swapGrowth30m(points: points, now: now)
        if let growth {
            let limit = max(swapYellowAbsolute, Int64(Double(physicalBytes) * swapYellowFraction))
            Hysteresis.step(&state.memorySwap, enter: growth >= limit ? .yellow : .green,
                            enterSince: now.addingTimeInterval(-1800), exitHolds: growth < swapSmall,
                            canJudge: true, now: now)
        }

        let combined = combine([state.memoryPressure, state.memorySwap])
        if combined.level == .unknown { return collecting(.memory, run: run, hasData: run.contains { $0.pressure != nil || $0.swapUsed != nil }) }

        let swapNow: Int64? = points.last { $0.swapUsed != nil }?.swapUsed
        let swapText = TextFormat.bytes(swapNow)
        let pressure = run.last?.pressure
        let pLevel = state.memoryPressure
        if pLevel.known, pLevel.level != .green {
            let label = pLevel.level == .red ? "压力严重" : "压力警告"
            let code = pLevel.level == .red ? "pressure_critical" : "pressure_warning"
            return verdict(.memory, combined, code: code, headline: label + " · swap " + swapText, now: now)
        }
        if state.memorySwap.known, state.memorySwap.level != .green {
            let g = TextFormat.bytes(growth.map { max(0, $0) })
            return verdict(.memory, combined, code: "swap_growth", headline: "swap 30 分钟增加 " + g, now: now)
        }
        let pressureText = (pressure ?? .normal).label
        return verdict(.memory, combined, code: "ok", headline: "内存压力" + pressureText + " · swap " + swapText, now: now)
    }
}

// MARK: - Thermal

enum ThermalHealth {
    static func evaluate(points: [TrendPoint], now: Date, state: inout RuleMemory) -> ItemVerdict {
        let run = TrendMath.run(points, now: now)
        let rankOf: (Int) -> Int? = { run[$0].thermal?.rank }
        if run.last?.thermal != nil {
            let fair = TrendMath.streak(run) { rankOf($0).map { $0 >= 1 } }
            let serious = TrendMath.streak(run) { rankOf($0).map { $0 >= 2 } }
            let critical = TrendMath.streak(run) { rankOf($0).map { $0 >= 3 } }
            var enter = HealthLevel.green
            var starts = [Date?]()
            if TrendMath.lasted(fair, 600) {
                enter = .yellow
                starts.append(fair?.start)
            }
            if TrendMath.lasted(serious, 60) {
                enter = .red
                starts.append(serious?.start)
            }
            if critical != nil {
                enter = .red
                starts.append(critical?.start)
            }
            let nominal = TrendMath.streak(run) { rankOf($0).map { $0 == 0 } }
            let upToFair = TrendMath.streak(run) { rankOf($0).map { $0 <= 1 } }
            let exit = state.thermal.level == .red ? TrendMath.lasted(upToFair, 180) : TrendMath.lasted(nominal, 180)
            Hysteresis.step(&state.thermal, enter: enter, enterSince: earliest(starts), exitHolds: exit,
                            canJudge: true, now: now)
        }
        let combined = combine([state.thermal])
        if combined.level == .unknown { return collecting(.thermal, run: run, hasData: run.contains { $0.thermal != nil }) }
        let level = run.last?.thermal ?? .nominal
        switch combined.level {
        case .red:
            let code = level.rank >= 3 ? "thermal_critical" : "thermal_serious"
            return verdict(.thermal, combined, code: code, headline: "热状态" + level.label, now: now)
        case .yellow:
            return verdict(.thermal, combined, code: "thermal_fair", headline: "热状态" + level.label, now: now)
        default:
            return verdict(.thermal, combined, code: "ok", headline: "温度正常", now: now)
        }
    }
}

// MARK: - Power

/// A record from one battery reading before sleep and one after. It is not created when one reading is missing.
struct SleepRecord: Codable, Equatable {
    var sleptAt: Date
    var wokeAt: Date
    var batteryBefore: Double
    var batteryAfter: Double
    var onBatteryBeforeSleep: Bool
}

enum PowerHealth {
    static let sleepMinimum: TimeInterval = 2 * 3600
    static let sleepYellow = 3.0
    static let sleepRed = 6.0
    static let sleepExpiry: TimeInterval = 24 * 3600
    static let awakeWindow: TimeInterval = 3600
    static let awakeYellow = 30.0
    static let awakeRed = 45.0
    static let awakeExitFactor = 0.8

    /// Drain in percent per hour of one sleep. Nil when the sleep is too short or ran on power.
    static func sleepDrain(_ r: SleepRecord) -> Double? {
        guard r.onBatteryBeforeSleep else { return nil }
        let seconds = r.wokeAt.timeIntervalSince(r.sleptAt)
        guard seconds >= sleepMinimum else { return nil }
        return (r.batteryBefore - r.batteryAfter) / (seconds / 3600)
    }

    /// The level of the newest qualifying battery sleep. Nil without one. A problem ends 24 hours after the wake.
    static func sleepLevel(sleeps: [SleepRecord], now: Date) -> (level: HealthLevel, since: Date, rate: Double)? {
        let ordered = sleeps.sorted { $0.wokeAt < $1.wokeAt }
        guard let latest = ordered.last(where: { sleepDrain($0) != nil }), let rate = sleepDrain(latest) else { return nil }
        var level = HealthLevel.green
        if rate >= sleepRed { level = .red } else if rate >= sleepYellow { level = .yellow }
        if level != .green && now.timeIntervalSince(latest.wokeAt) > sleepExpiry { level = .green }
        return (level, latest.wokeAt, rate)
    }

    /// Drain rate (percent per hour) over the 60 minutes that end at `run[end]`. Nil when the window is too short.
    static func awakeRate(_ battery: [TrendPoint], end: Int) -> Double? {
        guard end >= 0, end < battery.count, let now = battery[end].battery else { return nil }
        let target = battery[end].t.addingTimeInterval(-awakeWindow)
        guard let ref = TrendMath.nearest(Array(battery[0...end]), to: target, tolerance: 90),
              let old = ref.battery else { return nil }
        let hours = battery[end].t.timeIntervalSince(ref.t) / 3600
        guard hours >= 0.9 * awakeWindow / 3600 else { return nil }
        return (old - now) / hours
    }

    /// A Mac without a battery returns nil and the power item does not appear.
    static func evaluate(points: [TrendPoint], sleeps: [SleepRecord], hasBattery: Bool,
                         now: Date, state: inout RuleMemory) -> ItemVerdict? {
        guard hasBattery else { return nil }
        let run = TrendMath.run(points, now: now)
        let lastPower = run.last?.power
        let batteryNow: Double? = run.last { $0.battery != nil }?.battery

        // Awake drain: the stretch since the last point on power, battery points only.
        var stretch = [TrendPoint]()
        for p in run.reversed() {
            if p.power == .ac { break }
            if p.battery != nil { stretch.append(p) }
        }
        stretch.reverse()
        var windowReady = false
        if lastPower == .ac {
            state.powerAwake = SubRule(level: .green, since: nil, known: true)
        } else if lastPower == .battery {
            let last = stretch.count - 1
            if last >= 0, let rate = awakeRate(stretch, end: last) {
                windowReady = true
                var enter = HealthLevel.green
                if rate >= awakeRed { enter = .red } else if rate >= awakeYellow { enter = .yellow }
                var start: Date?
                if enter != .green {
                    let floor = enter == .red ? awakeRed : awakeYellow
                    var i = last
                    start = stretch[last].t
                    while i > 0, let r = awakeRate(stretch, end: i - 1), r >= floor {
                        i -= 1
                        start = stretch[i].t
                    }
                }
                let cut = (state.powerAwake.level == .red ? awakeRed : awakeYellow) * awakeExitFactor
                Hysteresis.step(&state.powerAwake, enter: enter, enterSince: start, exitHolds: rate < cut,
                                canJudge: true, now: now)
            }
        }

        // Sleep drain.
        let sleep = sleepLevel(sleeps: sleeps, now: now)

        // Merge: higher level wins, then the earlier start.
        struct Candidate { var level: HealthLevel; var since: Date?; var code: String; var headline: String }
        var candidates = [Candidate]()
        if let sleep, sleep.level != .green {
            let text = "睡眠掉电 " + String(format: "%.1f", sleep.rate) + "%/小时"
            candidates.append(Candidate(level: sleep.level, since: sleep.since, code: "sleep_drain", headline: text))
        }
        if state.powerAwake.known, state.powerAwake.level != .green {
            let rate = awakeRate(stretch, end: stretch.count - 1)
            let text = "电池供电 · 掉电 " + (rate.map { String(format: "%.0f", $0) } ?? "—") + "%/小时"
            candidates.append(Candidate(level: state.powerAwake.level, since: state.powerAwake.since, code: "awake_drain", headline: text))
        }
        let batteryText = batteryNow.map { String(format: "%.0f%%", $0) } ?? "—"
        let source = lastPower == .ac ? " · 接电源" : " · 电池供电"
        if candidates.isEmpty {
            if batteryNow == nil && sleep == nil {
                return collecting(.power, run: run, hasData: run.contains { $0.battery != nil })
            }
            let onBatteryShort = lastPower == .battery && !windowReady && sleep == nil
            return ItemVerdict(item: .power, level: .green, reasonCode: onBatteryShort ? "insufficient_window" : "ok",
                               headline: "电量 " + batteryText + source, since: nil, levelChangedAt: nil, alert: nil)
        }
        var best = candidates[0]
        for c in candidates.dropFirst() {
            if c.level.severity > best.level.severity {
                best = c
            } else if c.level == best.level, let cs = c.since, let bs = best.since, cs < bs {
                best = c
            }
        }
        return ItemVerdict(item: .power, level: best.level, reasonCode: best.code, headline: best.headline,
                           since: best.since, levelChangedAt: nil, alert: nil)
    }
}
