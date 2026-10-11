// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk and NIC samples from Sampler; sleep and wake events; panel open and close; the data directory.
// Output: Published status for the UI, status.json (every 5 minutes and on change), disk-YYYY-MM.ndjson, alert-state.json, notifications.
// Pos: Phase 1 engine (docs/PROJECT.md 6, 9, 10); one timer, no 1 Hz loop; all work on one background queue.

import Foundation
import Combine
import AppKit

final class MonitorEngine: ObservableObject {
    /// Latest complete status (phase 1: disk and network).
    @Published private(set) var status: StatusFile?
    @Published private(set) var diskLevel: HealthLevel
    /// Alerts whose condition still holds. Never contains a "recovered" entry.
    @Published private(set) var alerts: [AlertItem]
    /// "authorized" | "denied" | "not_determined" | "unavailable"
    @Published private(set) var authorization: String

    /// True when the data directory had no history and no alert-state.json at init time.
    let isFirstLaunch: Bool

    // Timing (docs/PROJECT.md 6.1). One timer ticks every 5 minutes; every third tick also samples (15 minutes).
    static let tickPeriod: TimeInterval = 300
    static let ticksPerSample = 3
    static let wakeSampleDelay: TimeInterval = 30
    static let historyDays = 35
    /// A panel open within this time after the previous sample does not sample again (avoids a flood of rows).
    static let panelSampleMinGap: TimeInterval = 30

    private let dataDir: URL
    private let queue = DispatchQueue(label: "molemonitor.engine", qos: .utility)
    private let notifier: Notifier
    /// Touched only by start() and stop(), which the app calls on the main thread.
    private var observers = [NSObjectProtocol]()

    // State below is confined to `queue`.
    private var started = false
    private var sleeping = false
    private var timer: DispatchSourceTimer?
    private var wakeSample: DispatchWorkItem?
    private var tickCount = 0
    private var samples = [DiskSample]()
    private var logicState = DiskEngineState()
    private var lastResult: DiskEngineResult?
    private var lastSampleAt: Date?
    private var lastBoot: Date?
    private var lastWriteAt: Date?
    private var lastSavedAlertData: Data?
    private var authorizationValue: String
    private var panelOpen = false
    /// Reserved for the status card (phase 2): bytes per second between the last two samples. Not shown.
    private var latestNetworkRate: NetworkRate?
    private var lastNet: (rx: Int64, tx: Int64, at: Date)?

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
    }

    // MARK: Public interface

    func start() {
        // UNVERIFIED-ON-MAC: NSWorkspace.willSleepNotification/didWakeNotification names and addObserver(forName:object:queue:using:)
        // on NSWorkspace.shared.notificationCenter (same spelling as the old code for didWake).
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

    /// Stops timers and observers and writes status.json once. Blocks until the queue has finished.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
        queue.sync { stopOnQueue() }
    }

    /// Takes one extra sample (src=panel). The 15 minute rhythm does not change.
    func panelOpened() {
        queue.async { [weak self] in
            guard let self, self.started, !self.sleeping else { return }
            self.panelOpen = true
            let now = Date()
            if let last = self.lastSampleAt, now.timeIntervalSince(last) < MonitorEngine.panelSampleMinGap { return }
            self.takeSample(src: .panel)
        }
    }

    func panelClosed() {
        queue.async { [weak self] in self?.panelOpen = false }
    }

    func requestNotificationAuthorization() {
        notifier.requestAuthorization { [weak self] value in
            guard let self else { return }
            self.queue.async { self.setAuthorization(value) }
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
        notifier.currentAuthorization { [weak self] value in
            guard let self else { return }
            self.queue.async { self.setAuthorization(value) }
        }
        takeSample(src: .launch)
        scheduleTimer()
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        wakeSample?.cancel()
        wakeSample = nil
        guard started else { return }
        started = false
        if lastResult != nil { writeStatus(now: Date(), publish: false) }
    }

    // MARK: Sleep and wake

    private func handleSleep() {
        guard started else { return }
        sleeping = true
        // Cancel instead of suspend: a suspended dispatch source must not be released.
        timer?.cancel()
        timer = nil
        wakeSample?.cancel()
        wakeSample = nil
    }

    private func handleWake() {
        guard started else { return }
        sleeping = false
        scheduleTimer()
        wakeSample?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.sleeping else { return }
            self.takeSample(src: .wake)
        }
        wakeSample = work
        queue.asyncAfter(deadline: .now() + MonitorEngine.wakeSampleDelay, execute: work)
    }

    // MARK: Timer

    private func scheduleTimer() {
        timer?.cancel()
        tickCount = 0
        let period = MonitorEngine.tickPeriod
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Leeway is 20% of the period so the system can coalesce wakeups.
        source.schedule(deadline: .now() + period, repeating: .seconds(Int(period)), leeway: .seconds(Int(period * 0.2)))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        guard started, !sleeping else { return }
        tickCount += 1
        if tickCount % MonitorEngine.ticksPerSample == 0 {
            takeSample(src: .timer)
        } else if lastResult != nil {
            // No new sample: refresh written_at only. A new evaluation would lower the level a step without new data.
            writeStatus(now: Date(), publish: true)
        }
    }

    // MARK: Sampling and evaluation

    private func takeSample(src: DiskSource) {
        let now = Date()
        let s = Sampler.sample(src: src, now: now, previousBoot: lastBoot)
        if let b = s.boot { lastBoot = b }
        // A failed history write must not stop monitoring; the sample stays in memory.
        try? DiskHistory.append(s, dir: dataDir)
        samples.append(s)
        let cutoff = now.addingTimeInterval(-Double(MonitorEngine.historyDays) * 86400)
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        lastSampleAt = now

        if let rx = s.netRx, let tx = s.netTx {
            if let prev = lastNet {
                latestNetworkRate = NetworkFilter.rate(prevRx: prev.rx, prevTx: prev.tx, rx: rx, tx: tx,
                                                       seconds: now.timeIntervalSince(prev.at))
            }
            lastNet = (rx, tx, now)
        } else {
            latestNetworkRate = nil
            lastNet = nil
        }
        evaluate(now: now)
    }

    private func evaluate(now: Date) {
        let todayStart = Calendar.current.startOfDay(for: now)
        let (result, next) = DiskEngineLogic.step(samples: samples, now: now, todayStart: todayStart, state: logicState)
        var committed = next
        if !result.notifications.isEmpty && authorizationValue != "authorized" {
            // Nothing can be delivered. Do not mark the alert as notified, so it fires after the user enables notifications.
            var kept = logicState.alertState
            DiskAlertPolicy.settle(verdict: result.verdict, into: &kept)
            committed.alertState = kept
        }
        logicState = committed
        lastResult = result
        saveAlertStateIfChanged()
        for p in result.notifications {
            notifier.post(type: p.alert.type, subject: p.alert.subject, title: p.title, body: p.alert.message, now: now)
        }
        let due = lastWriteAt.map { now.timeIntervalSince($0) >= MonitorEngine.tickPeriod } ?? true
        if result.levelChanged || result.newAlert || due {
            writeStatus(now: now, publish: true)
        } else {
            publish(buildStatus(now: now), result: result)
        }
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

    // MARK: Status

    private func buildStatus(now: Date) -> StatusFile? {
        guard let r = lastResult else { return nil }
        return StatusFile(appVersion: AppInfo.version, writtenAt: now, writerPid: ProcessInfo.processInfo.processIdentifier,
                          overall: r.overall, items: r.items, activeAlerts: r.activeAlerts,
                          notifications: .init(authorization: authorizationValue))
    }

    /// Writes status.json and, when `publish` is true, updates the published properties.
    private func writeStatus(now: Date, publish shouldPublish: Bool) {
        guard let file = buildStatus(now: now), let r = lastResult else { return }
        do {
            try StatusStore.write(file, to: MoleMonitorPaths.statusURL(dir: dataDir))
            lastWriteAt = now
        } catch {
            // Keep running. The next tick retries; the CLI shows the file as stale meanwhile.
        }
        if shouldPublish { publish(file, result: r) }
    }

    private func publish(_ file: StatusFile?, result: DiskEngineResult) {
        guard let file else { return }
        let level = result.items.disk.level
        let active = result.activeAlerts
        DispatchQueue.main.async { [weak self] in
            self?.status = file
            self?.diskLevel = level
            self?.alerts = active
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
