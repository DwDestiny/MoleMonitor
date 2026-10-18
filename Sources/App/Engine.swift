// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk, CPU, network, memory, thermal and battery readings; process scans; sleep and wake events; panel open and close; the data directory.
// Output: Published health verdicts, readings, trend and top apps for the UI; status.json and trend.json (every 5 minutes and on change),
//         disk-YYYY-MM.ndjson, alert-state.json, sleeps.json; notifications in problem order; prompts for the agent.
// Pos: Engine of the problem-first card (docs/DESIGN.md 6, 8.2). With the card closed exactly one 30 s timer runs. It samples CPU, network,
//      memory pressure, swap and thermal state, reads the battery (60 s on battery, 5 min on AC), scans processes by throttle
//      (300 s all green, 180 s any yellow or red) and evaluates the rules. A 2 s timer exists only while the card is open (own points,
//      not saved) and then also scans processes every 4 s. All logic that does not need a Mac is in Core (HealthPipeline, NotificationPlanner).
//      v3: each tick also hands its CPU percent to the menu bar runner (`cpuTickHandler`); the icon owns its own run timer.

import Foundation
import Combine
import AppKit

final class MonitorEngine: ObservableObject {
    /// Latest complete status.
    @Published private(set) var status: StatusFile?
    @Published private(set) var diskLevel: HealthLevel
    /// Alerts whose condition still holds, for all items. Never contains a "recovered" entry.
    @Published private(set) var alerts: [AlertItem]
    /// "authorized" | "denied" | "not_determined" | "unavailable"
    @Published private(set) var authorization: String
    /// Down-sampled used space of the last 30 days (at most 120 points), oldest first. Read-only copy of the history.
    @Published private(set) var diskSeries: [DiskPoint] = []
    /// The growth segment behind a growth alert. Nil when growth does not trigger.
    @Published private(set) var diskTrigger: DiskTrigger?
    /// 60 second window of network rates and CPU use. Filled only while the card is open; empty otherwise. Memory only.
    /// Kept for the current Panel (DESIGN.md 8.2 deletes it when the new card lands).
    @Published private(set) var live: LiveSnapshot = .empty

    /// All health items, problem items first (problem order), then the rest by fixed priority.
    @Published private(set) var verdicts: [ItemVerdict] = []
    /// Yellow and red items in problem order.
    @Published private(set) var problems: [ItemVerdict] = []
    @Published private(set) var current = CurrentReadings()
    /// Two hours of trend: 30 s points, and 2 s points while the card is open.
    @Published private(set) var trend: TrendSeries = .empty
    /// Union of the top 8 by CPU and the top 8 by memory (at most 16), CPU order first. The card shows the first 5 by CPU.
    @Published private(set) var topApps: [AppUsage] = []
    /// "实时", "近 N 分钟" (N at most 5) or "采样于 HH:mm".
    @Published private(set) var appsBasis: String = "\u{2014}"
    @Published private(set) var coverage = ProcessCoverage(readable: 0, unreadable: 0)
    /// Top 5 disk writers of the last 5 minutes (DESIGN_V2.md 6.5). Empty until two scans exist. Writes are not disk growth.
    @Published private(set) var diskWriters: [AppDiskWriteTracker.Row] = []
    /// Speed and totals per physical interface, updated by the 2 s tick while the panel is open and by the 30 s tick
    /// otherwise (DESIGN_V2.md D9). Empty until the counters are read.
    @Published private(set) var interfaces: [InterfaceRate] = []
    @Published private(set) var dataState: DataState = .collecting
    /// Latest sleep records, for the power item.
    @Published private(set) var sleeps: [SleepRecord] = []
    /// Anomaly records of the last 7 days, newest first (DESIGN_V2.md 12.2 D2). Nil until the engine has loaded them.
    private(set) var recentEvents: [EventRecord]?
    /// The last result of `readSleepBlockers`. Nil until the battery sidebar has read it once.
    private(set) var latestSleepBlockers: [SleepBlocker]?

    /// True when the data directory had no history and no alert-state.json at init time.
    let isFirstLaunch: Bool

    /// Main thread. Called when the user taps a notification: open the card, expand the item.
    var openCardHandler: ((HealthItem?) -> Void)?
    /// Called on the main thread after each 30 s tick (and the warm-up tick) with the whole-machine CPU percent of that
    /// tick, or nil when the tick read none. The menu bar runner uses it (docs/DESIGN_V3.md 4.2).
    var cpuTickHandler: ((Double?) -> Void)?

    /// "提示词包含 App 名称" (default on). The setting is written to status.json for the CLI.
    var includeAppNamesInPrompt: Bool {
        get { UserDefaults.standard.object(forKey: MonitorEngine.promptNamesKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: MonitorEngine.promptNamesKey)
            queue.async { [weak self] in
                guard let self, self.started, self.lastResult != nil else { return }
                self.writeStatus(now: Date(), publish: true)
            }
        }
    }
    private static let promptNamesKey = "molemonitor.promptIncludeAppNames"

    // Timing (docs/DESIGN.md 6.1). One 30 s timer; the disk sample every 30th tick (15 min); trend.json every 10th tick (5 min).
    static let tickPeriod: TimeInterval = 30
    static let ticksPerDiskSample = 30
    static let ticksPerSave = 10
    static let warmUpDelay: TimeInterval = 3
    static let wakeSampleDelay: TimeInterval = 30
    static let historyDays = 35
    /// A card open within this time after the previous disk sample does not sample again (avoids a flood of rows).
    static let panelSampleMinGap: TimeInterval = 30
    static let fineInterval: TimeInterval = 2
    /// Process scan periods in seconds: card open, any yellow or red, all green.
    static let scanPeriodOpen: TimeInterval = 4
    static let scanPeriodProblem: TimeInterval = 180
    static let scanPeriodCalm: TimeInterval = 300
    /// A scan is due when this much less than the period has passed: the 30 s tick would otherwise miss it by one tick.
    static let scanTolerance: TimeInterval = 10
    static let batteryPeriod: TimeInterval = 60
    static let acPeriod: TimeInterval = 300
    /// status.json is rewritten at least this often.
    static let statusPeriod: TimeInterval = 300

    private let dataDir: URL
    private let queue = DispatchQueue(label: "molemonitor.engine", qos: .utility)
    private let notifier: Notifier
    private let machine = SystemSampler.machineInfo()
    /// Touched only by start() and stop(), which the app calls on the main thread.
    private var observers = [NSObjectProtocol]()

    // State below is confined to `queue`.
    private var started = false
    private var sleeping = false
    private var panelOpen = false
    private var timer: DispatchSourceTimer?
    private var fineTimer: DispatchSourceTimer?
    private var wakeSample: DispatchWorkItem?
    private var warmUp: DispatchWorkItem?
    private var tickCount = 0
    private var fineCount = 0

    // Disk.
    private var samples = [DiskSample]()
    private var logicState = DiskEngineState()
    private var lastResult: DiskEngineResult?
    private var pendingDisk = [PendingNotification]()
    private var forceWrite = false
    private var lastSampleAt: Date?
    private var lastBoot: Date?
    private var lastWriteAt: Date?
    private var lastSavedAlertData: Data?
    private var authorizationValue: String
    private var cachedSeries = [DiskPoint]()
    private var cachedTrigger: DiskTrigger?

    // Health.
    private var trendBuffer = TrendBuffer()
    private var pipeline = PipelineState()
    private var planner = NotificationPlannerState()
    private var budget = NotificationBudget()
    private var lastOutput: PipelineOutput?
    private var lastLevelKey: String?
    private var sleepRecords = [SleepRecord]()
    private var sleepStart: (at: Date, power: PowerSnapshot)?
    private var lastWakeAt: Date?
    private var tracker = AppCPUTracker()
    private var diskTracker = AppDiskWriteTracker()

    // Samplers.
    private var coarseSampler = SystemSampler()
    private var fineSampler: SystemSampler?
    private let processSampler = ProcessSampler()
    private var liveBuffer = LiveBuffer()
    private var latestCPU: Double?
    private var latestRate: NetworkRate?
    private var latestInterfaces = [InterfaceRate]()
    /// Newest memory pressure percent and memory split. Nil after a failed read, so a failure is never shown as a value.
    private var latestPressurePercent: Int?
    /// Anomaly records (events.json) and the end of the last 5 minute window written to rollup-YYYY-MM.ndjson.
    private var eventTracker = EventTracker(records: [], previousStatusAt: nil)
    private var lastRollupEnd: Date?
    private var latestMemory: MemoryBreakdown?
    private var cachedPower: PowerSnapshot?
    private var powerReadAt: Date?
    private var smc: SupplementalSample?

    // Processes.
    private var baseline = [ProcessSample]()
    private var baselineAt: Date?
    private var lastScanAt: Date?
    private var latestApps = [AppUsage]()
    private var appsSampledAt: Date?
    private var appsInterval: TimeInterval = 0
    private var latestCoverage = ProcessCoverage(readable: 0, unreadable: 0)

    /// Changes at every start and stop of the 2 s timer. Results of an older session are dropped on the main thread.
    private let sessionLock = NSLock()
    private var fineSession = 0

    /// Main thread only: the 2 hour CPU summary of the last publish, for the prompt.
    private var publishedCPUSummary: CPUSummary?

    init(dataDir: URL = MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)) {
        let notifier = Notifier()
        self.dataDir = dataDir
        self.notifier = notifier
        self.isFirstLaunch = !DataDirInspector.hasHistory(dir: dataDir)
        self.diskLevel = .unknown
        self.alerts = []
        let initial = notifier.isAvailable ? "not_determined" : "unavailable"
        self.authorization = initial
        self.authorizationValue = initial
        notifier.onCopyPrompt = { [weak self] topic in
            DispatchQueue.main.async {
                guard let self else { return }
                _ = Clipboard.copy(self.prompt(scope: .topic(topic)))
            }
        }
        notifier.onOpenCard = { [weak self] item in
            DispatchQueue.main.async { self?.openCardHandler?(item) }
        }
    }

    // MARK: Public interface

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleWake() }
        })
        queue.async { [weak self] in self?.startOnQueue() }
    }

    /// Stops timers and observers and writes status.json and trend.json once. Blocks until the queue has finished.
    /// On the main thread the published status is updated at once, so a caller can read the final status right after.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
        let final: StatusFile? = queue.sync { stopOnQueue() }
        if Thread.isMainThread, let final { status = final }
    }

    /// True while the 2 second timer exists. Must not be called on the engine queue.
    var isLiveSampling: Bool { queue.sync { fineTimer != nil } }

#if UITEST
    /// Test only: rewrites each disk sample, so the UI regression has a fixed red scenario on any machine.
    static var sampleTransform: ((DiskSample) -> DiskSample)?

    /// Test only: trend points restored at start instead of trend.json (a cold start with data for the first frame).
    static var trendSeed: [TrendPoint]?

    /// Test only: number of dispatch timers (the 30 s tick, plus the 2 second timer while the card is open).
    var activeTimerCount: Int {
        queue.sync { (timer != nil ? 1 : 0) + (fineTimer != nil ? 1 : 0) }
    }
#endif

    /// Starts the 2 second timer, scans processes at once and takes one extra disk sample (src=panel).
    /// The 15 minute rhythm does not change.
    func panelOpened() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.panelOpen = true
            guard !self.sleeping else { return }
            self.startFineOnQueue()
            let now = Date()
            if let last = self.lastSampleAt, now.timeIntervalSince(last) < MonitorEngine.panelSampleMinGap {
                self.runPipeline(now: now)
                return
            }
            self.takeSample(src: .panel)
        }
    }

    /// Cancels the 2 second timer, drops the fine points and the live buffer, and publishes an empty live snapshot.
    /// The process scan period returns to 300 s (all green) or 180 s (any yellow or red).
    func panelClosed() {
        queue.async { [weak self] in
            guard let self else { return }
            self.panelOpen = false
            self.stopFineOnQueue()
        }
    }

    func requestNotificationAuthorization() {
        notifier.requestAuthorization { [weak self] value in
            guard let self else { return }
            self.queue.async { self.setAuthorization(value) }
        }
    }

    // MARK: Prompt (main thread)

    /// The input of the prompt builder, from the published state. Main thread.
    func promptInput() -> PromptInput {
        var freshness = PromptFreshness.fresh
        if case .stale(let since) = dataState {
            freshness = .stale(minutes: max(0, Int(Date().timeIntervalSince(since) / 60)))
        }
        let environment = PromptEnvironment(model: machine.model, chip: machine.chip, memoryBytes: machine.memoryBytes,
                                            os: machine.os, appVersion: AppInfo.version,
                                            cliPath: Bundle.main.bundlePath + "/Contents/Helpers/molemonitor-cli",
                                            dataDir: dataDir.path)
        let growth: [String: DiskGrowth] = status?.items.disk.growth ?? [:]
        var input = PromptInput(env: environment, sampledAt: current.sampledAt ?? Date(), freshness: freshness, verdicts: verdicts,
                                current: current, apps: topApps, appsBasis: appsBasis, cpuSummary: publishedCPUSummary,
                                diskGrowth: growth)
        input.sleeps = sleeps
        input.pressure2h = PressureSummary.make(points: trend.segments.flatMap { $0 }, now: Date())
        input.diskWriters = diskWriters
        input.sleepBlockers = latestSleepBlockers
        input.events = recentEvents
        return input
    }

    /// The prompt text for the agent (docs/DESIGN.md 7). Main thread.
    func prompt(scope: PromptScope) -> String {
        let options = PromptOptions.forCurrentUser(includeAppNames: includeAppNamesInPrompt)
        return PromptBuilder.build(promptInput(), scope: scope, options: options)
    }

    // MARK: Diagnostics (any thread except the engine queue)

    /// Real readings, the top 5 apps and the timer count for `--diagnose`.
    func diagnosticSnapshot() -> DiagnosticSnapshot {
        queue.sync {
            let now = Date()
            var lines = [DiagnosticSnapshot.ItemLine]()
            for v in lastOutput?.verdicts ?? [] {
                lines.append(DiagnosticSnapshot.ItemLine(item: v.item.rawValue, level: v.level.rawValue,
                                                         reasonCode: v.reasonCode, headline: v.headline))
            }
            let latest = trendBuffer.latest
            let readings = lastOutput?.current
            let source: String? = cachedPower?.source.map { $0 == .battery ? "battery" : "ac" }
            let top: [AppUsage] = AppRanking.top(latestApps, by: .cpu, count: 5)
            let timers = (timer != nil ? 1 : 0) + (fineTimer != nil ? 1 : 0)
            return DiagnosticSnapshot(
                sampledAt: readings?.sampledAt, cpuPercent: latestCPU ?? latest?.cpu, cpuMean5m: readings?.cpuMean5m,
                memoryPressure: latest?.pressure?.rawValue, swapUsedBytes: latest?.swapUsed,
                thermalState: latest?.thermal?.rawValue, batteryPercent: cachedPower?.percent,
                powerSource: source, physicalMemoryBytes: machine.memoryBytes, items: lines,
                topApps: top, appsBasis: basisText(now: now),
                processesReadable: latestCoverage.readable, processesUnreadable: latestCoverage.unreadable,
                trendCoarsePoints: trendBuffer.coarse.count, trendFinePoints: trendBuffer.fine.count,
                timerCount: timers, processScanPeriod: scanPeriod(), panelOpen: panelOpen)
        }
    }

    // MARK: Fine timer (queue)

    private func nextSession() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        fineSession += 1
        return fineSession
    }

    private func isCurrent(session: Int) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return fineSession == session
    }

    private func startFineOnQueue() {
        guard fineTimer == nil, started, !sleeping else { return }
        let session = nextSession()
        liveBuffer.removeAll()
        fineCount = 0
        let sampler = SystemSampler()
        _ = sampler.read(at: Date(), slow: false)  // baseline: stores counters, adds no point
        fineSampler = sampler
        scanProcesses(now: Date())
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: .milliseconds(Int(MonitorEngine.fineInterval * 1000)),
                        leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.fineTick(session: session) }
        source.resume()
        fineTimer = source
    }

    private func stopFineOnQueue() {
        let hadTimer = fineTimer != nil
        fineTimer?.cancel()
        fineTimer = nil
        fineSampler = nil
        fineCount = 0
        trendBuffer.clearFine()
        liveBuffer.removeAll()
        _ = nextSession()
        guard hadTimer, started else { return }
        let series = trendBuffer.series(now: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.live != .empty { self.live = .empty }
            if self.trend != series { self.trend = series }
        }
    }

    private func fineTick(session: Int) {
        guard let sampler = fineSampler, fineTimer != nil else { return }
        let now = Date()
        let reading = sampler.read(at: now, slow: false)
        var point = TrendPoint(t: now)
        point.cpu = reading.cpuPercent
        point.rx = reading.rate?.rxPerSecond
        point.tx = reading.rate?.txPerSecond
        point.pressurePercent = reading.pressurePercent
        latestPressurePercent = reading.pressurePercent
        latestMemory = reading.memory
        if reading.cpuPercent != nil || reading.rate != nil || reading.pressurePercent != nil { trendBuffer.appendFine(point) }
        liveBuffer.add(at: now, rate: reading.rate, cpuPercent: reading.cpuPercent)
        if reading.cpuPercent != nil { latestCPU = reading.cpuPercent }
        if reading.rate != nil { latestRate = reading.rate }
        if let list = reading.interfaces { latestInterfaces = list }
        fineCount += 1
        if fineCount % 2 == 0 { scanProcesses(now: now) }
        // The SMC reading is for display only and costs an IOKit call, so it runs every 10 s and only while the card is open.
        if fineCount % 5 == 1 { smc = SupplementalSensors.read() }

        var snapshot = currentReadings(now: now)
        snapshot.cpuPercent = latestCPU
        let liveSnapshot = liveBuffer.snapshot
        let series = trendBuffer.series(now: now)
        let apps: [AppUsage] = StatusExtras.unionApps(latestApps)
        let basis = basisText(now: now)
        let cover = latestCoverage
        let writers = diskTracker.top(now: now)
        let nics = latestInterfaces
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(session: session) else { return }
            if self.diskWriters != writers { self.diskWriters = writers }
            if self.interfaces != nics { self.interfaces = nics }
            if self.live != liveSnapshot { self.live = liveSnapshot }
            if self.trend != series { self.trend = series }
            if self.current != snapshot { self.current = snapshot }
            if self.topApps != apps { self.topApps = apps }
            if self.appsBasis != basis { self.appsBasis = basis }
            if self.coverage != cover { self.coverage = cover }
        }
    }

    // MARK: Lifecycle on the queue

    private func startOnQueue() {
        guard !started else { return }
        started = true
        let now = Date()
        let loaded = DiskHistory.load(dir: dataDir, now: now, days: MonitorEngine.historyDays)
        samples = loaded.samples
        DiskHistory.prune(dir: dataDir, now: now)
        if let saved = AlertStateStore.load(dir: dataDir) {
            logicState.alertState = saved
            lastSavedAlertData = try? AlertStateStore.encode(saved)
        }
        lastBoot = samples.last(where: { $0.boot != nil })?.boot
        // The last two hours of the trend come back from trend.json: the rules see the time before the restart.
        var restored: [TrendPoint] = TrendStore.load(dir: dataDir, now: now)
#if UITEST
        if let seed = MonitorEngine.trendSeed { restored = seed }
#endif
        trendBuffer = TrendBuffer(restoring: restored)
        sleepRecords = SleepStore.load(dir: dataDir, now: now)
        // Records of the last run: an open record whose item is green now ends at the last status time (estimated).
        let previousStatusAt: Date? = (try? StatusStore.read(from: MoleMonitorPaths.statusURL(dir: dataDir)))?.writtenAt
        eventTracker = EventTracker(records: EventLog.readAll(dir: dataDir).records, previousStatusAt: previousStatusAt)
        RollupStore.prune(dir: dataDir, now: now)
        lastRollupEnd = RollupStore.read(dir: dataDir, from: now.addingTimeInterval(-3600), to: now).windows.last?.end
        coarseSampler = SystemSampler()
        _ = coarseSampler.read(at: now, slow: false)  // baseline for the first CPU and network values
        refreshPower(now: now, force: true)
        notifier.currentAuthorization { [weak self] value in
            guard let self else { return }
            self.queue.async { self.setAuthorization(value) }
            // Ask at launch. The system shows its prompt only while the state is not_determined, so the user sees it once.
            if value == "not_determined" { self.requestNotificationAuthorization() }
        }
        scanProcesses(now: now)
        takeSample(src: .launch)
        scheduleTimer()
        scheduleWarmUp()
    }

    /// Returns the final status for `stop()`.
    private func stopOnQueue() -> StatusFile? {
        timer?.cancel()
        timer = nil
        fineTimer?.cancel()
        fineTimer = nil
        fineSampler = nil
        wakeSample?.cancel()
        wakeSample = nil
        warmUp?.cancel()
        warmUp = nil
        guard started else { return nil }
        started = false
        persistTrend()
        guard lastResult != nil else { return nil }
        return writeStatus(now: Date(), publish: false)
    }

    // MARK: Sleep and wake

    private func handleSleep() {
        guard started else { return }
        sleeping = true
        let now = Date()
        persistTrend()
        sleepStart = (now, PowerReader.read())
        // Cancel instead of suspend: a suspended dispatch source must not be released.
        timer?.cancel()
        timer = nil
        fineTimer?.cancel()
        fineTimer = nil
        fineSampler = nil
        wakeSample?.cancel()
        wakeSample = nil
        warmUp?.cancel()
        warmUp = nil
        _ = nextSession()
        let since: Date = trendBuffer.latest?.t ?? now
        DispatchQueue.main.async { [weak self] in self?.dataState = .stale(since) }
    }

    private func handleWake() {
        guard started else { return }
        sleeping = false
        let now = Date()
        lastWakeAt = now
        if let start = sleepStart {
            let after = PowerReader.read()
            if start.power.hasBattery, let before = start.power.percent, let end = after.percent, now > start.at {
                let record = SleepRecord(sleptAt: start.at, wokeAt: now, batteryBefore: before, batteryAfter: end,
                                         onBatteryBeforeSleep: start.power.source == .battery)
                sleepRecords = SleepStore.adding(record, to: sleepRecords, now: now)
                try? SleepStore.write(sleepRecords, dir: dataDir)
            }
            cachedPower = after
            powerReadAt = now
        }
        sleepStart = nil
        // New baselines: the counters and the CPU times of the sleep must not become a rate.
        coarseSampler = SystemSampler()
        _ = coarseSampler.read(at: now, slow: false)
        baseline = []
        baselineAt = nil
        lastScanAt = nil
        tracker.reset()
        diskTracker.reset()
        scheduleTimer()
        scheduleWarmUp()
        wakeSample?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.sleeping else { return }
            self.takeSample(src: .wake)
        }
        wakeSample = work
        queue.asyncAfter(deadline: .now() + MonitorEngine.wakeSampleDelay, execute: work)
        if panelOpen { startFineOnQueue() }
    }

    // MARK: Timer

    private func scheduleTimer() {
        timer?.cancel()
        tickCount = 0
        let period = MonitorEngine.tickPeriod
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Leeway is 20% of the period so the system can coalesce wakeups.
        source.schedule(deadline: .now() + period, repeating: .seconds(Int(period)), leeway: .seconds(Int(period * 0.2)))
        source.setEventHandler { [weak self] in self?.tick(regular: true) }
        source.resume()
        timer = source
    }

    /// One extra tick shortly after the start or a wake, so the first CPU value and the first process scan do not wait 30 s.
    /// It is a work item on the engine queue, not a timer, and runs once.
    private func scheduleWarmUp() {
        warmUp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.sleeping else { return }
            self.tick(regular: false)
        }
        warmUp = work
        queue.asyncAfter(deadline: .now() + MonitorEngine.warmUpDelay, execute: work)
    }

    private func tick(regular: Bool) {
        guard started, !sleeping else { return }
        let now = Date()
        if regular { tickCount += 1 }
        let cpu = collectPoint(now: now)
        DispatchQueue.main.async { [weak self] in self?.cpuTickHandler?(cpu) }
        // The warm-up tick always scans once more: the first scan only sets the baseline, so it gives no CPU values.
        if !regular || scanDue(now: now) { scanProcesses(now: now) }
        if regular && tickCount % MonitorEngine.ticksPerDiskSample == 0 {
            takeSample(src: .timer)
        } else {
            runPipeline(now: now)
        }
        if regular { flushRollup(now: now) }
        if regular && tickCount % MonitorEngine.ticksPerSave == 0 { persistTrend() }
    }

    // MARK: Readings

    /// One 30 s point: CPU, network, memory pressure, swap, thermal state and, when due, the battery. Returns the CPU
    /// percent of this point (nil when the sampler gave none).
    @discardableResult
    private func collectPoint(now: Date) -> Double? {
        let reading = coarseSampler.read(at: now, slow: true)
        let readNow = refreshPower(now: now, force: false)
        var point = TrendPoint(t: now)
        point.cpu = reading.cpuPercent
        point.rx = reading.rate?.rxPerSecond
        point.tx = reading.rate?.txPerSecond
        point.swapUsed = reading.swapUsed
        point.pressure = reading.pressure
        point.thermal = reading.thermal
        point.pressurePercent = reading.pressurePercent
        latestPressurePercent = reading.pressurePercent
        latestMemory = reading.memory
        if let power = cachedPower, power.hasBattery {
            point.power = power.source
            if readNow { point.battery = power.percent }
        }
        trendBuffer.appendCoarse(point)
        if reading.cpuPercent != nil { latestCPU = reading.cpuPercent }
        latestRate = reading.rate
        if let list = reading.interfaces { latestInterfaces = list }
        return reading.cpuPercent
    }

    /// Reads the battery every 60 s on battery power and every 5 minutes on AC. Returns true when it read now.
    @discardableResult
    private func refreshPower(now: Date, force: Bool) -> Bool {
        if !force, let last = powerReadAt {
            let onAC = cachedPower?.source == .ac
            let period = onAC ? MonitorEngine.acPeriod : MonitorEngine.batteryPeriod
            // The 30 s tick is coarser than the period: read when at least the period minus half a tick has passed.
            if now.timeIntervalSince(last) < period - MonitorEngine.tickPeriod / 2 { return false }
        }
        cachedPower = PowerReader.read()
        powerReadAt = now
        return true
    }

    private func currentReadings(now: Date) -> CurrentReadings {
        var c = CurrentReadings()
        let latest = trendBuffer.latest
        c.cpuPercent = latestCPU ?? latest?.cpu
        c.pressure = latest?.pressure
        c.swapUsed = latest?.swapUsed
        c.thermal = latest?.thermal
        c.physicalMemory = machine.memoryBytes
        c.batteryPercent = cachedPower?.percent
        c.powerSource = cachedPower?.source
        c.rx = latestRate?.rxPerSecond
        c.tx = latestRate?.txPerSecond
        c.smcCPUTemperature = smc?.cpuTemperature
        c.fanRPMs = smc?.fanRPMs
        c.diskAvailable = lastResult?.items.disk.availableImportant.value
        if let disk = lastResult?.items.disk { StatusExtras.applyDisk(disk, to: &c) }
        c.memoryPressurePercent = latestPressurePercent
        c.memory = latestMemory
        c.sampledAt = now
        return c
    }

    // MARK: Processes

    private func scanPeriod() -> TimeInterval {
        if panelOpen { return MonitorEngine.scanPeriodOpen }
        let anyProblem = lastOutput?.verdicts.contains { $0.isProblem } ?? false
        return anyProblem ? MonitorEngine.scanPeriodProblem : MonitorEngine.scanPeriodCalm
    }

    private func scanDue(now: Date) -> Bool {
        guard let last = lastScanAt else { return true }
        return now.timeIntervalSince(last) >= scanPeriod() - MonitorEngine.scanTolerance
    }

    private func scanProcesses(now: Date) {
        let scan = processSampler.scan()
        let seconds: TimeInterval = baselineAt.map { now.timeIntervalSince($0) } ?? 0
        let usage = AppRanking.usage(previous: baseline, current: scan.samples, seconds: seconds,
                                     ignore: AppRanking.defaultIgnore)
        if !baseline.isEmpty && seconds > 0 {
            tracker.add(at: now, seconds: seconds, usage: usage)
            diskTracker.add(at: now, seconds: seconds, usage: usage)
        }
        baseline = scan.samples
        baselineAt = now
        lastScanAt = now
        latestApps = usage
        appsSampledAt = now
        appsInterval = seconds
        latestCoverage = scan.coverage
    }

    private func basisText(now: Date) -> String {
        guard let at = appsSampledAt else { return "\u{2014}" }
        if appsInterval <= 0 { return "\u{2014}" }
        if appsInterval < 30 {
            if now.timeIntervalSince(at) < 60 { return "实时" }
            return "采样于 " + TextFormat.clock(at, timeZone: TimeZone.current)
        }
        let minutes = min(5, max(1, Int((appsInterval / 60).rounded())))
        return "近 \(minutes) 分钟"
    }

    // MARK: Disk sampling and evaluation

    private func takeSample(src: DiskSource) {
        let now = Date()
        let sampled = Sampler.sample(src: src, now: now, previousBoot: lastBoot)
#if UITEST
        let s = MonitorEngine.sampleTransform.map { $0(sampled) } ?? sampled
#else
        let s = sampled
#endif
        if let b = s.boot { lastBoot = b }
        // A failed history write must not stop monitoring; the sample stays in memory.
        try? DiskHistory.append(s, dir: dataDir)
        samples.append(s)
        let cutoff = now.addingTimeInterval(-Double(MonitorEngine.historyDays) * 86400)
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        lastSampleAt = now
        cachedSeries = DiskSeries.downsample(samples: samples, now: now)
        evaluateDisk(now: now)
        runPipeline(now: now)
    }

    private func evaluateDisk(now: Date) {
        let todayStart = Calendar.current.startOfDay(for: now)
        let (result, next) = DiskEngineLogic.step(samples: samples, now: now, todayStart: todayStart, state: logicState)
        var committed = next
        if !result.notifications.isEmpty && authorizationValue != "authorized" {
            // Nothing can be delivered. Do not mark the alert as notified, so it fires after the user enables notifications.
            var kept = logicState.alertState
            DiskAlertPolicy.settle(verdict: result.verdict, into: &kept)
            committed.alertState = kept
        } else {
            pendingDisk.append(contentsOf: result.notifications)
        }
        logicState = committed
        lastResult = result
        cachedTrigger = DiskSeries.trigger(verdict: result.verdict, samples: samples)
        if result.levelChanged || result.newAlert { forceWrite = true }
        saveAlertStateIfChanged()
    }

    private func saveAlertStateIfChanged() {
        guard let data = try? AlertStateStore.encode(logicState.alertState), data != lastSavedAlertData else { return }
        do {
            try AlertStateStore.save(logicState.alertState, dir: dataDir)
            lastSavedAlertData = data
        } catch {
            // Keep running. The next change retries the save.
        }
    }

    // MARK: Rules, notifications and publishing

    /// Evaluates the five items from the trend, plans the notifications, writes the files when due and publishes.
    private func runPipeline(now: Date) {
        var diskVerdict: ItemVerdict?
        if let r = lastResult { diskVerdict = HealthPipeline.diskVerdict(item: r.items.disk, alerts: r.activeAlerts) }
        var input = PipelineInput(points: trendBuffer.coarse, now: now)
        input.apps = tracker.stats(now: now)
        input.appDataAvailable = tracker.hasCoverage(now: now)
        input.sleeps = sleepRecords
        input.hasBattery = cachedPower?.hasBattery ?? false
        input.disk = diskVerdict
        input.current = currentReadings(now: now)
        let output = HealthPipeline.evaluate(input, state: &pipeline)
        lastOutput = output

        // Notifications: candidates in problem order, the budget in that order, delivery in reverse order.
        var plannerState = planner
        let candidates = NotificationPlanner.candidates(verdicts: output.verdicts, points: trendBuffer.coarse,
                                                        cpuAppKey: pipeline.rules.cpuAppKey, disk: pendingDisk,
                                                        wokeAt: lastWakeAt, now: now, state: &plannerState)
        pendingDisk = []
        if authorizationValue == "authorized" {
            planner = plannerState
            for n in NotificationPlanner.schedule(candidates, budget: &budget, now: now) { notifier.post(n) }
        }

        recordEvents(output: output, now: now)

        var key = ""
        for v in output.verdicts { key += v.item.rawValue + ":" + v.level.rawValue + ":" + (v.alert?.type ?? "-") + "," }
        let changed = key != lastLevelKey
        lastLevelKey = key
        let due = lastWriteAt.map { now.timeIntervalSince($0) >= MonitorEngine.statusPeriod - MonitorEngine.scanTolerance } ?? true
        if changed || forceWrite || due {
            forceWrite = false
            writeStatus(now: now, publish: true)
        } else {
            publishAll(status: buildStatus(now: now), now: now)
        }
    }

    /// Level changes become anomaly records. Only a change rewrites events.json. A failed write is retried at the next change.
    private func recordEvents(output: PipelineOutput, now: Date) {
        var growth = [String: Int64]()
        if let g = lastResult?.items.disk.growth { for (key, value) in g { if let bytes = value.bytes { growth[key] = bytes } } }
        var names = [HealthItem: String]()
        if includeAppNamesInPrompt, let key = pipeline.rules.cpuAppKey, let app = latestApps.first(where: { $0.key == key }) {
            names[.cpu] = app.name
        }
        if eventTracker.observe(verdicts: output.verdicts, current: output.current, diskGrowth: growth, appNames: names, now: now) {
            try? EventLog.write(eventTracker.records, dir: dataDir, now: now)
        }
        let recent = EventLog.limited(eventTracker.records, now: now).filter { EventLog.overlaps($0, days: 7, now: now) }
        DispatchQueue.main.async { [weak self] in if self?.recentEvents != recent { self?.recentEvents = recent } }
    }

    /// Appends the newest finished 5 minute window once (DESIGN_V2.md 12.2 D1). A window without points writes nothing.
    private func flushRollup(now: Date) {
        let end = RollupAggregator.lastFinishedEnd(now: now)
        if let last = lastRollupEnd, end <= last { return }
        lastRollupEnd = end
        guard let window = RollupAggregator.window(points: trendBuffer.coarse, end: end) else { return }
        _ = try? RollupStore.append(window, dir: dataDir)
    }

    /// Apps that keep the Mac awake (DESIGN_V2.md 6.5, D4). Read on demand, not on a timer: the battery sidebar calls it
    /// when it opens and then every 10 s with a one-shot delay. The completion runs on the main thread.
    func readSleepBlockers(completion: @escaping ([SleepBlocker]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let list = self.processSampler.sleepBlockers()
            DispatchQueue.main.async {
                self.latestSleepBlockers = list
                completion(list)
            }
        }
    }

    private func persistTrend() {
        // A failed write must not stop monitoring. The next save retries.
        try? TrendStore.write(trendBuffer.coarse, dir: dataDir)
    }

    // MARK: Status

    private func buildStatus(now: Date) -> StatusFile? {
        guard let r = lastResult else { return nil }
        var file = StatusFile(appVersion: AppInfo.version, writtenAt: now, writerPid: ProcessInfo.processInfo.processIdentifier,
                              overall: r.overall, items: r.items, activeAlerts: r.activeAlerts,
                              notifications: .init(authorization: authorizationValue))
        let environment = PromptEnvironment(model: machine.model, chip: machine.chip, memoryBytes: machine.memoryBytes,
                                            os: machine.os, appVersion: AppInfo.version, cliPath: "", dataDir: "")
        file.env = StatusExtras.env(environment)
        file.promptPrefs = PromptPrefs(includeAppNames: includeAppNamesInPrompt)
        guard let out = lastOutput else { return file }
        let summary = trendBuffer.cpuSummary(now: now)
        for v in out.verdicts {
            let item = StatusExtras.itemStatus(for: v, current: out.current, cpuSummary: summary)
            switch v.item {
            case .memory: file.items.memory = item
            case .cpu: file.items.cpu = item
            case .thermal: file.items.thermal = item
            case .power: file.items.power = item
            case .disk: break
            }
        }
        var active = [AlertItem]()
        for v in out.problems {
            if v.item == .disk {
                active.append(contentsOf: r.activeAlerts)
            } else if let alert = v.alert {
                active.append(alert)
            }
        }
        file.activeAlerts = active
        file.overall = StatusExtras.overall(verdicts: out.verdicts, diskSummary: r.overall.summary)
        if let at = appsSampledAt {
            let code: String = appsInterval < 30 ? "live" : "5m"
            file.topApps = StatusExtras.topApps(latestApps, coverage: latestCoverage, sampledAt: at, basis: code)
        }
        return file
    }

    /// Writes status.json and, when `publish` is true, updates the published properties. Returns the file.
    @discardableResult
    private func writeStatus(now: Date, publish shouldPublish: Bool) -> StatusFile? {
        guard let file = buildStatus(now: now) else { return nil }
        do {
            try StatusStore.write(file, to: MoleMonitorPaths.statusURL(dir: dataDir))
            lastWriteAt = now
        } catch {
            // Keep running. The next tick retries; the CLI shows the file as stale meanwhile.
        }
        if shouldPublish { publishAll(status: file, now: now) }
        return file
    }

    private func publishAll(status file: StatusFile?, now: Date) {
        guard let file, let result = lastResult, let output = lastOutput else { return }
        let level = result.items.disk.level
        let active = file.activeAlerts
        let series = cachedSeries
        let trigger = cachedTrigger
        let verdictList = output.verdicts
        let problemList = output.problems
        var readings = output.current
        if let fresh = latestCPU { readings.cpuPercent = fresh }
        let trendSeries = trendBuffer.series(now: now)
        let apps: [AppUsage] = StatusExtras.unionApps(latestApps)
        let basis = basisText(now: now)
        let cover = latestCoverage
        let records = sleepRecords
        let writers = diskTracker.top(now: now)
        let nics = latestInterfaces
        let summary = trendBuffer.cpuSummary(now: now)
        let state: DataState = trendBuffer.latest == nil ? .collecting : .fresh
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.diskWriters != writers { self.diskWriters = writers }
            if self.interfaces != nics { self.interfaces = nics }
            self.status = file
            self.publishedCPUSummary = summary
            if self.diskLevel != level { self.diskLevel = level }
            if self.alerts != active { self.alerts = active }
            if self.diskSeries != series { self.diskSeries = series }
            if self.diskTrigger != trigger { self.diskTrigger = trigger }
            if self.verdicts != verdictList { self.verdicts = verdictList }
            if self.problems != problemList { self.problems = problemList }
            if self.current != readings { self.current = readings }
            if self.trend != trendSeries { self.trend = trendSeries }
            if self.topApps != apps { self.topApps = apps }
            if self.appsBasis != basis { self.appsBasis = basis }
            if self.coverage != cover { self.coverage = cover }
            if self.sleeps != records { self.sleeps = records }
            if self.dataState != state { self.dataState = state }
        }
    }

    private func setAuthorization(_ value: String) {
        guard value != authorizationValue else { return }
        authorizationValue = value
        DispatchQueue.main.async { [weak self] in self?.authorization = value }
        // Keep the CLI field in step with the real state.
        if started, lastResult != nil { writeStatus(now: Date(), publish: true) }
    }
}
