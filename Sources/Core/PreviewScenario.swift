// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A level (green, yellow, red) and a reference time.
// Output: Invented disk samples (30 days), the engine result computed from them, a 60 second live snapshot,
//         and the 7 fixed panel scenarios of docs/DESIGN.md 8.5 (`fixture`) with their fixed `DogInput`.
// Pos: Example data for `--preview` renders and tests only; the app never calls it at run time. The numbers describe no real machine.
// Owner I1 (shared by I1, I2, I3). `fixture` data is shared: change DESIGN.md 8.5 first, then this file.

import Foundation

enum PreviewLevel: String, CaseIterable {
    case green, yellow, red
}

enum PreviewScenario {
    static let totalGB = 995.0

    /// Invented used space in GB, `daysAgo` days before now (30 down to 0).
    static func usedGB(_ level: PreviewLevel, daysAgo d: Double) -> Double {
        let wobble = 1.2 * sin(d * 0.9) + 0.4 * sin(d * 2.3)
        switch level {
        case .green:
            return 380 + 0.5 * (30 - d) + wobble
        case .yellow:
            let ramp = max(0, min(1, (4.6 - d) / 4.6))
            return 450 + 0.3 * (30 - d) + 105 * ramp + wobble
        case .red:
            let ramp = max(0, min(1, (4.8 - d) / 4.8))
            return 271 + 0.4 * (30 - d) + 310 * ramp * ramp * (3 - 2 * ramp) + wobble
        }
    }

    /// One sample every 3 hours for 30 days, with invented cumulative network counters.
    static func samples(_ level: PreviewLevel, now: Date) -> [DiskSample] {
        let step = 3 * 3600.0
        let count = Int(30 * 86400 / step)
        var out = [DiskSample]()
        var rx: Int64 = 2_000_000_000_000
        var tx: Int64 = 300_000_000_000
        for i in 0...count {
            let age = Double(count - i) * step
            rx += 1_020_000_000
            tx += 140_000_000
            let used = Int64(usedGB(level, daysAgo: age / 86400) * 1e9)
            let total = Int64(totalGB * 1e9)
            out.append(DiskSample(t: now.addingTimeInterval(-age), src: .timer, total: total,
                                  availImportant: total - used, avail: total - used - 14_000_000_000,
                                  netRx: rx, netTx: tx))
        }
        return out
    }

    /// The real engine logic applied to the invented samples. Alerts start 3 hours before `now`.
    static func result(_ level: PreviewLevel, now: Date) -> (result: DiskEngineResult, samples: [DiskSample]) {
        let s = samples(level, now: now)
        var state = DiskEngineState()
        let since = now.addingTimeInterval(-3 * 3600)
        state.alertSince = ["disk_growth": since, "disk_low_space": since]
        let (r, _) = DiskEngineLogic.step(samples: s, now: now, todayStart: Calendar.current.startOfDay(for: now), state: state)
        return (r, s)
    }

    /// 30 points, 2 seconds apart, ending at `now`. Smooth invented curves.
    static func live(now: Date) -> LiveSnapshot {
        var buffer = LiveBuffer()
        let n = 30
        for i in 0..<n {
            let t = now.addingTimeInterval(-Double(n - 1 - i) * LiveSnapshot.interval)
            let x = Double(i)
            let burst = exp(-pow((x - 20) / 3.5, 2))
            let rx = 350_000 + 220_000 * (sin(x * 0.45) + 1) + 2_300_000 * burst
            let tx = 60_000 + 40_000 * (sin(x * 0.9 + 1) + 1) + 260_000 * burst
            let cpu = min(100, max(1, 17 + 9 * sin(x * 0.5) + 5 * sin(x * 1.7) + 24 * burst))
            buffer.add(at: t, rate: NetworkRate(rxPerSecond: rx, txPerSecond: tx), cpuPercent: cpu)
        }
        return buffer.snapshot
    }
}

// MARK: - Panel fixtures (docs/DESIGN.md 8.1, 8.5)

enum PreviewCase: String, CaseIterable {
    /// One-to-one with the 7 scenarios in DESIGN.md 8.5. `multi` is wireframe D: disk red, memory red, power yellow, CPU yellow.
    case allGreen, cpuYellow, diskRed, powerYellow, multi, collecting, stale
}

struct PreviewFixture {
    /// All health items in display order: problem items first (in `ProblemOrder` order), then the rest by fixed priority.
    var verdicts: [ItemVerdict]
    var current: CurrentReadings
    var trend: TrendSeries
    var sleeps: [SleepRecord]
    var apps: [AppUsage]
    var status: StatusFile
    var diskSeries: [DiskPoint]
    var diskTrigger: DiskTrigger?
    /// The fixed dog input of the scenario (DESIGN.md 8.5). Added to 8.1: the gallery and the screenshots read it.
    var dogInput: DogInput
}

private struct TrendShape {
    /// Minutes ago -> value.
    var cpu: (Double) -> Double
    var swap: (Double) -> Int64
    var pressure: (Double) -> MemoryPressure
    var battery: (Double) -> Double
    var power: (Double) -> PowerSource
}

extension PreviewScenario {
    /// Physical memory of the invented machine: 16 GiB.
    static let fixturePhysicalMemory: Int64 = 17_179_869_184

    /// Fixed data for one scenario. Every value is invented. `full: false` removes the trend, the apps, the sleep
    /// records and the disk series (an empty first run); verdicts, current readings and status stay.
    /// `status` is built from the disk engine only: the new status.json items of DESIGN.md 8.1 are I1's work.
    static func fixture(_ c: PreviewCase, full: Bool, now: Date) -> PreviewFixture {
        let statusNow = c == .stale ? now.addingTimeInterval(-25 * 60) : now

        // Disk: the real engine logic on invented samples. Collecting has no samples at all.
        let diskLevel: PreviewLevel = (c == .diskRed || c == .multi) ? .red : .green
        var samples = [DiskSample]()
        let engine: DiskEngineResult
        if c == .collecting {
            let start = Calendar.current.startOfDay(for: statusNow)
            engine = DiskEngineLogic.step(samples: [], now: statusNow, todayStart: start, state: DiskEngineState()).0
        } else {
            let (r, s) = result(diskLevel, now: statusNow)
            engine = r
            samples = s
        }
        let status = StatusFile(appVersion: AppInfo.version, writtenAt: statusNow, writerPid: 0,
                                overall: engine.overall, items: engine.items, activeAlerts: engine.activeAlerts,
                                notifications: .init(authorization: "authorized"))

        var current = fixtureCurrent(c, at: statusNow)
        if c != .collecting { current.diskAvailable = engine.items.disk.availableImportant.value }
        let verdicts = fixtureVerdicts(c, current: current, engine: engine, now: statusNow)
        let dog = fixtureDogInput(c)

        var trend = TrendSeries.empty
        var apps = [AppUsage]()
        var sleeps = [SleepRecord]()
        var diskSeries = [DiskPoint]()
        var diskTrigger: DiskTrigger?
        if full {
            trend = fixtureTrend(c, now: now)
            apps = c == .collecting ? [] : fixtureApps(c)   // A first run has not scanned processes yet.
            if c == .powerYellow, let s = current.lastSleep { sleeps = [s] }
            diskSeries = DiskSeries.downsample(samples: samples, now: statusNow)
            diskTrigger = DiskSeries.trigger(verdict: engine.verdict, samples: samples)
        }
        return PreviewFixture(verdicts: verdicts, current: current, trend: trend, sleeps: sleeps, apps: apps,
                              status: status, diskSeries: diskSeries, diskTrigger: diskTrigger, dogInput: dog)
    }

    // MARK: Prompt input (golden tests and the CLI tests)

    /// Environment of the invented machine. The user name is "tester", so it never meets a bundle id.
    static let fixtureEnvironment = PromptEnvironment(
        model: "Mac14,15", chip: "Apple M2", memoryBytes: fixturePhysicalMemory, os: "15.1", appVersion: AppInfo.version,
        cliPath: "/Users/tester/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli",
        dataDir: "/Users/tester/Library/Application Support/MoleMonitor")

    static let fixturePromptOptions = PromptOptions(
        includeAppNames: true, maxLength: 3000, homeDirectory: "/Users/tester", userNames: ["tester", "Tina Tester"],
        timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current)

    /// The prompt input of one scenario (full data), as the engine would build it.
    static func promptInput(_ c: PreviewCase, now: Date) -> PromptInput {
        let f = fixture(c, full: true, now: now)
        var summary: CPUSummary?
        let cpuValues: [Double] = f.trend.segments.flatMap { $0 }.compactMap { $0.cpu }
        if !cpuValues.isEmpty {
            summary = CPUSummary(mean: cpuValues.reduce(0, +) / Double(cpuValues.count), peak: cpuValues.max() ?? 0)
        }
        let sampled = f.current.sampledAt ?? now
        var freshness = PromptFreshness.fresh
        if c == .stale { freshness = .stale(minutes: 25) }
        return PromptInput(env: fixtureEnvironment, sampledAt: sampled, freshness: freshness, verdicts: f.verdicts,
                           current: f.current, apps: f.apps, appsBasis: "近 5 分钟", cpuSummary: summary,
                           diskGrowth: f.status.items.disk.growth)
    }

    // MARK: DogInput (fixed values of DESIGN.md 8.5, table 2)

    private static func fixtureDogInput(_ c: PreviewCase) -> DogInput {
        switch c {
        case .allGreen:
            return DogInput(cpuPercent: 8, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)
        case .cpuYellow:
            return DogInput(cpuPercent: 76, thermal: .nominal, memoryLevel: .green, worstProblem: .cpu, worstLevel: .yellow, isStatic: false)
        case .diskRed:
            return DogInput(cpuPercent: 23, thermal: .nominal, memoryLevel: .green, worstProblem: .disk, worstLevel: .red, isStatic: false)
        case .powerYellow:
            return DogInput(cpuPercent: 12, thermal: .nominal, memoryLevel: .green, worstProblem: .power, worstLevel: .yellow, isStatic: false)
        case .multi:
            return DogInput(cpuPercent: 74, thermal: .nominal, memoryLevel: .red, worstProblem: .disk, worstLevel: .red, isStatic: false)
        case .collecting:
            return DogInput(cpuPercent: nil, thermal: nil, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: true)
        case .stale:
            return DogInput(cpuPercent: 8, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: true)
        }
    }

    // MARK: Current readings

    private static func fixtureCurrent(_ c: PreviewCase, at t: Date) -> CurrentReadings {
        let gib = Double(1 << 30)
        var r = CurrentReadings()
        if c == .collecting { return r }   // Nothing is measured yet: every field is nil, never zero.
        r.physicalMemory = fixturePhysicalMemory
        r.thermal = .nominal
        r.sampledAt = t
        r.rx = 1_200_000
        r.tx = 220_000
        switch c {
        case .allGreen, .stale, .collecting:
            r.cpuPercent = 8; r.cpuMean5m = 8; r.cpuMean10m = 9
            r.pressure = .normal; r.swapUsed = Int64(1.2 * gib); r.swapGrowth30m = 20_000_000; r.swapTrend = .flat
            r.batteryPercent = 83; r.powerSource = .ac
            r.smcCPUTemperature = 41; r.fanRPMs = [1200, 1215]
        case .cpuYellow:
            r.cpuPercent = 76; r.cpuMean5m = 76; r.cpuMean10m = 74
            r.pressure = .normal; r.swapUsed = Int64(2.1 * gib); r.swapGrowth30m = 60_000_000; r.swapTrend = .flat
            r.batteryPercent = 83; r.powerSource = .ac
            r.smcCPUTemperature = 49; r.fanRPMs = [2400, 2410]
        case .diskRed:
            r.cpuPercent = 23; r.cpuMean5m = 22; r.cpuMean10m = 21
            r.pressure = .normal; r.swapUsed = Int64(1.8 * gib); r.swapGrowth30m = 30_000_000; r.swapTrend = .flat
            r.batteryPercent = 83; r.powerSource = .ac
            r.smcCPUTemperature = 44; r.fanRPMs = [1400, 1405]
        case .powerYellow:
            r.cpuPercent = 12; r.cpuMean5m = 12; r.cpuMean10m = 11
            r.pressure = .normal; r.swapUsed = Int64(1.3 * gib); r.swapGrowth30m = 10_000_000; r.swapTrend = .flat
            r.batteryPercent = 61; r.powerSource = .battery
            let sleptAgo: Double = 8.0 * 3600.0 + 30.0 * 60.0
            let wokeAgo: Double = 2.0 * 3600.0 + 10.0 * 60.0
            r.lastSleep = SleepRecord(sleptAt: t.addingTimeInterval(-sleptAgo), wokeAt: t.addingTimeInterval(-wokeAgo),
                                      batteryBefore: 82, batteryAfter: 61, onBatteryBeforeSleep: true)
            r.awakeDrainPerHour = 0.8
            r.smcCPUTemperature = 38; r.fanRPMs = [0, 0]
        case .multi:
            r.cpuPercent = 74; r.cpuMean5m = 74; r.cpuMean10m = 72
            r.pressure = .critical; r.swapUsed = 9_800_000_000; r.swapGrowth30m = 2_400_000_000; r.swapTrend = .steepUp
            r.batteryPercent = 42; r.powerSource = .battery
            r.awakeDrainPerHour = 34
            r.smcCPUTemperature = 52; r.fanRPMs = [3100, 3120]
        }
        return r
    }

    // MARK: Verdicts

    private static func fixtureVerdicts(_ c: PreviewCase, current: CurrentReadings, engine: DiskEngineResult,
                                        now: Date) -> [ItemVerdict] {
        func minutes(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        func problem(_ item: HealthItem, _ level: HealthLevel, _ code: String, _ headline: String, ago: Double,
                     alert: AlertItem? = nil) -> ItemVerdict {
            var v = ItemVerdict(item: item, level: level, reasonCode: code, headline: headline, since: minutes(ago),
                                levelChangedAt: minutes(ago), alert: alert)
            if alert == nil { v.alert = HealthAlerts.alert(for: v, current: current) }
            return v
        }
        func other(_ item: HealthItem) -> ItemVerdict {
            switch c {
            case .collecting:
                return ItemVerdict(item: item, level: .unknown, reasonCode: "collecting", headline: "统计中",
                                   since: nil, levelChangedAt: nil, alert: nil)
            case .stale:
                return ItemVerdict(item: item, level: .stale, reasonCode: "stale", headline: "数据已过期",
                                   since: nil, levelChangedAt: nil, alert: nil)
            default:
                let swap = current.swapUsed.map { ByteText.gb($0) } ?? "—"
                let battery = current.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—"
                let text: String
                switch item {
                case .thermal: text = "温度正常"
                case .memory: text = "内存压力正常 · swap " + swap
                case .cpu: text = "CPU 5 分钟均值 " + RateText.percent(current.cpuMean5m)
                case .disk: text = "磁盘正常"
                case .power:
                    let source: String = current.powerSource == .ac ? " · 接电源" : " · 电池供电"
                    text = "电量 " + battery + source
                }
                return ItemVerdict(item: item, level: .green, reasonCode: "ok", headline: text,
                                   since: nil, levelChangedAt: nil, alert: nil)
            }
        }

        let growth5d = engine.items.disk.growth["5d"]?.bytes ?? 0
        let diskProblem = problem(.disk, .red, "growth_5d", "5 天多占用 " + ByteText.gb(growth5d), ago: 180,
                                  alert: engine.activeAlerts.first)
        var problems = [ItemVerdict]()
        switch c {
        case .allGreen, .collecting, .stale:
            break
        case .cpuYellow:
            problems = [problem(.cpu, .yellow, "cpu_mean_5m", "5 分钟均值 76%", ago: 18)]
        case .diskRed:
            problems = [diskProblem]
        case .powerYellow:
            problems = [problem(.power, .yellow, "sleep_drain", "睡眠掉电 3.3%/小时", ago: 130)]
        case .multi:
            problems = [diskProblem,
                        problem(.memory, .red, "pressure_critical", "压力严重 · swap 9.8 GB", ago: 25),
                        problem(.power, .yellow, "awake_drain", "电池供电 · 掉电 34%/小时", ago: 40),
                        problem(.cpu, .yellow, "cpu_mean_5m", "5 分钟均值 74%", ago: 40)]
        }
        let problemItems: [HealthItem] = problems.map { $0.item }
        var restItems = [HealthItem]()
        for item in HealthItem.allCases where !problemItems.contains(item) { restItems.append(item) }
        restItems.sort { $0.fixedPriority < $1.fixedPriority }
        var rest = [ItemVerdict]()
        for item in restItems { rest.append(other(item)) }
        return problems + rest
    }

    // MARK: Trend (2 hours: 30 s points, then 2 s points for the last 5 minutes)

    private static func fixtureTrend(_ c: PreviewCase, now: Date) -> TrendSeries {
        func calm(_ m: Double) -> Double {
            let slow: Double = 4.0 * sin(m * 0.35)
            let fast: Double = 3.0 * sin(m * 1.1)
            let burst: Double = 25.0 * exp(-pow((m - 70.0) / 3.0, 2.0))
            return max(2.0, 8.0 + slow + fast + burst)
        }
        func wave(_ base: Double, _ amp: Double, _ m: Double) -> Double {
            let first: Double = amp * sin(m * 0.9)
            let second: Double = 0.4 * amp * sin(m * 2.7)
            return base + first + second
        }
        func flatSwap(_ gb: Double) -> (Double) -> Int64 {
            return { (m: Double) -> Int64 in
                let wobble: Double = 0.03 * sin(m * 0.5)
                return Int64((gb + wobble) * 1_073_741_824.0)
            }
        }
        var shape = TrendShape(cpu: calm, swap: flatSwap(1.2), pressure: { _ in .normal },
                               battery: { _ in 83 }, power: { _ in .ac })
        var end = now
        var fine = true
        switch c {
        case .allGreen:
            break
        case .cpuYellow:
            shape.cpu = { (m: Double) -> Double in m <= 22.0 ? wave(76, 6, m) : wave(20, 7, m) }
            shape.swap = flatSwap(2.1)
        case .diskRed:
            shape.cpu = { (m: Double) -> Double in max(5.0, wave(23, 8, m)) }
            shape.swap = flatSwap(1.8)
        case .powerYellow:
            shape.cpu = { (m: Double) -> Double in max(3.0, wave(12, 5, m)) }
            shape.swap = flatSwap(1.3)
            shape.battery = { (m: Double) -> Double in 61.0 + 0.75 * m / 60.0 }
            shape.power = { _ in .battery }
        case .multi:
            shape.cpu = { (m: Double) -> Double in m <= 40.0 ? wave(74, 7, m) : max(5.0, wave(30, 10, m)) }
            shape.swap = { (m: Double) -> Int64 in
                // 5.2 GB two hours ago, 7.4 GB 30 minutes ago, 9.8 GB now.
                let early: Double = 2_200_000_000.0 / 90.0
                let late: Double = 2_400_000_000.0 / 30.0
                var bytes: Double = 7_400_000_000.0
                if m >= 30 {
                    bytes -= (m - 30) * early
                } else {
                    bytes += (30 - m) * late
                }
                return Int64(bytes)
            }
            shape.pressure = { m in m <= 25 ? .critical : (m <= 60 ? .warning : .normal) }
            shape.battery = { (m: Double) -> Double in m <= 70.0 ? 42.0 + 34.0 * m / 60.0 : 82.0 }
            shape.power = { m in m <= 70 ? .battery : .ac }
        case .collecting:
            // A trend file restored from the last run: coarse points only, ending 12 minutes ago.
            end = now.addingTimeInterval(-12 * 60)
            fine = false
        case .stale:
            end = now.addingTimeInterval(-25 * 60)
        }

        func point(_ secondsAgo: Double) -> TrendPoint {
            let m: Double = secondsAgo / 60.0
            let burst: Double = exp(-pow((m - 40.0) / 2.5, 2.0))
            let rxWave: Double = 300_000.0 * (sin(m * 0.8) + 1.0)
            let txWave: Double = 50_000.0 * (sin(m * 1.7 + 1.0) + 1.0)
            let rx: Double = 450_000.0 + rxWave + 2_000_000.0 * burst
            let tx: Double = 70_000.0 + txWave + 250_000.0 * burst
            let cpu: Double = min(100.0, max(0.0, shape.cpu(m)))
            return TrendPoint(t: end.addingTimeInterval(-secondsAgo), cpu: cpu,
                              rx: rx, tx: tx, swapUsed: shape.swap(m), battery: shape.battery(m),
                              pressure: shape.pressure(m), thermal: .nominal, power: shape.power(m))
        }
        var points = [TrendPoint]()
        for s in stride(from: 7200.0, to: fine ? 300.0 : -1.0, by: -30.0) { points.append(point(s)) }
        if fine {
            for s in stride(from: 298.0, through: 0.0, by: -2.0) { points.append(point(s)) }
        }
        return TrendSeries(segments: [points])
    }

    // MARK: Top apps (invented names; bundle ids use the reserved example domain)

    private static func fixtureApps(_ c: PreviewCase) -> [AppUsage] {
        func app(_ key: String, _ name: String, cpu: Double, gb: Double, procs: Int, system: Bool = false) -> AppUsage {
            AppUsage(key: key, name: name, bundleID: key.hasPrefix("proc:") ? nil : key, cpuPercent: cpu,
                     memoryBytes: Int64(gb * 1e9), memoryBasis: "footprint", processCount: procs, isSystem: system)
        }
        switch c {
        case .cpuYellow:
            return [app("com.example.kiln-studio", "Kiln Studio", cpu: 312, gb: 3.8, procs: 6),
                    app("proc:kiln-compile", "kiln-compile", cpu: 88, gb: 1.1, procs: 4),
                    app("com.example.orchard", "Orchard Browser", cpu: 41, gb: 5.1, procs: 23),
                    app("proc:WindowServer", "WindowServer", cpu: 12, gb: 0.9, procs: 1, system: true),
                    app("com.example.aster-chat", "Aster Chat", cpu: 4, gb: 1.1, procs: 5)]
        case .diskRed:
            return [app("com.example.orchard", "Orchard Browser", cpu: 86, gb: 5.1, procs: 23),
                    app("com.example.kiln-studio", "Kiln Studio", cpu: 41, gb: 3.2, procs: 5),
                    app("proc:WindowServer", "WindowServer", cpu: 9, gb: 0.8, procs: 1, system: true),
                    app("com.example.aster-chat", "Aster Chat", cpu: 5, gb: 1.0, procs: 5),
                    app("com.example.aster-notes", "Aster Notes", cpu: 2, gb: 0.6, procs: 2)]
        case .multi:
            return [app("com.example.orchard", "Orchard Browser", cpu: 52, gb: 6.4, procs: 31),
                    app("com.example.kiln-studio", "Kiln Studio", cpu: 38, gb: 4.2, procs: 6),
                    app("proc:kiln-compile", "kiln-compile", cpu: 24, gb: 1.5, procs: 4),
                    app("com.example.aster-chat", "Aster Chat", cpu: 6, gb: 1.4, procs: 5),
                    app("proc:WindowServer", "WindowServer", cpu: 11, gb: 0.9, procs: 1, system: true)]
        default:
            return [app("com.example.orchard", "Orchard Browser", cpu: 6, gb: 1.9, procs: 14),
                    app("com.example.kiln-studio", "Kiln Studio", cpu: 2, gb: 1.2, procs: 3),
                    app("com.example.aster-notes", "Aster Notes", cpu: 1.5, gb: 0.8, procs: 2),
                    app("proc:WindowServer", "WindowServer", cpu: 1.2, gb: 0.5, procs: 1, system: true),
                    app("com.example.aster-chat", "Aster Chat", cpu: 0.8, gb: 0.9, procs: 5)]
        }
    }
}
