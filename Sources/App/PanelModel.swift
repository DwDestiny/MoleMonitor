// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A PreviewFixture (previews, UI regression) or a MonitorEngine (the running app); user actions and key events from the views.
// Output: PanelData, the layout plan, the row texts and the UI state (sidebar item, pin, key focus, copy state) of the v2 panel.
// Pos: The only file that knows where the data comes from. Views read PanelModel and never the engine (docs/DESIGN_V2.md 14.3).
//      It implements PanelPinning for the window (WP-B) and it feeds hover events to HoverIntent. Commands are applied idempotently.
//      Engine mode reads the published properties of MonitorEngine (PanelEngineAdapter) and copies with `engine.prompt(scope:)`.
//      Fixture mode (previews, UI regression) reads PreviewScenario.fixture and adds the PreviewOverlay.
//      No timer here: the delayed work is one cancellable DispatchWorkItem at a time.

import AppKit
import Combine
import Foundation

// MARK: - Data

/// Everything the panel shows at one moment. A plain value, so a static render needs no engine.
struct PanelData {
    var verdicts: [ItemVerdict]
    var current: CurrentReadings
    var trend: TrendSeries
    var sleeps: [SleepRecord]
    var apps: [AppUsage]
    var coverage: ProcessCoverage?
    var status: StatusFile?
    var diskSeries: [DiskPoint]
    var diskTrigger: DiskTrigger?
    var dogInput: DogInput
    var dataState: DataState
    var now: Date
    /// "实时", "近 N 分钟" or "采样于 HH:mm".
    var appsBasis: String = "实时"
    /// 5 minute windows of the last 7 days for the 24 h and 7 d sidebar ranges. Loaded when the sidebar opens.
    var rollups: [RollupWindow] = []
    /// Anomaly records of the last 7 days, newest first.
    var events: [EventRecord] = []

    func verdict(_ item: HealthItem) -> ItemVerdict? {
        verdicts.first { $0.item == item }
    }

    /// Problem items in `ProblemOrder` order.
    var problems: [ItemVerdict] { ProblemOrder.problems(verdicts) }

    /// Lamp items for PanelHero (v1, WP-D): every problem item, then thermal, memory and CPU.
    var lamps: [ItemVerdict] {
        let always: Set<HealthItem> = [.thermal, .memory, .cpu]
        return ProblemOrder.all(verdicts).filter { v in
            if v.level == .notApplicable { return false }
            return v.level == .yellow || v.level == .red || always.contains(v.item)
        }
    }

    var isFresh: Bool {
        if case .fresh = dataState { return true }
        return false
    }

    var isCollecting: Bool {
        if case .collecting = dataState { return true }
        return false
    }

    var staleSince: Date? {
        if case .stale(let d) = dataState { return d }
        return nil
    }

    var hasBattery: Bool { PanelRows.hasBattery(verdicts) }
}

extension PanelData {
    init(fixture f: PreviewFixture, state: DataState, now: Date) {
        self.init(verdicts: f.verdicts, current: f.current, trend: f.trend, sleeps: f.sleeps, apps: f.apps,
                  coverage: nil, status: f.status, diskSeries: f.diskSeries, diskTrigger: f.diskTrigger,
                  dogInput: f.dogInput, dataState: state, now: now)
    }
}

/// What a copy action copies. Only the primary button copies in v2.
enum CopyTarget: Hashable {
    case primary
}

/// The element that has the keyboard focus ring (DESIGN_V2.md 10.10). Nil focus shows no ring.
enum PanelFocus: Hashable {
    case row(SidebarItem)
    case anomaly(Int)
    case records
    case primary
    case more
}

/// Keys that the window forwards to the model.
enum PanelKey: Equatable {
    case up, down, left, right, tab, backTab, returnKey, space, escape, copy
}

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject, PanelPinning {
    static let copiedSeconds = 1.5

    @Published private(set) var data: PanelData
    @Published private(set) var layoutPlan: PanelLayoutPlan
    @Published private(set) var copied = Set<CopyTarget>()
    @Published private(set) var copyFailed = false
    @Published private(set) var authorization: String = "authorized"
    @Published private(set) var includeAppNames: Bool
    /// The item whose sidebar is open (hover or pin). Nil when the sidebar is closed.
    @Published private(set) var sidebarItem: SidebarItem?
    @Published private(set) var pinnedItem: SidebarItem?
    @Published private(set) var keyFocus: PanelFocus?
    /// Row under the pointer. Gives the hover fill.
    @Published private(set) var hoverRow: SidebarItem?

    /// Copies the text of a scope. Returns true when the text is on the pasteboard. The harness replaces it.
    var onCopyText: (String) -> Bool = { Clipboard.copy($0) }
    var onEnableNotifications: () -> Void = {}
    var onOpenNotificationSettings: () -> Void = {}
    var onOpenDataFolder: () -> Void = {}
    var onAbout: () -> Void = {}
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    /// Kept for the app delegate. The v2 height does not depend on it.
    var screenVisibleHeight: Double = 1200
    /// The window of WP-B. Nil in previews and tests.
    weak var chrome: PanelChrome?
    /// Opens the "…" menu at its anchor. Set by the footer view.
    var onShowMoreMenu: (() -> Void)?

    private var intent = HoverIntent()
    private var pointer = PointerTracker()
    private var deadlineWork: DispatchWorkItem?
    private var revertWork: DispatchWorkItem?
    private var engineCancellable: AnyCancellable?
    private weak var engine: MonitorEngine?
    private var syncPending = false
    private var loadToken = 0

    init(data: PanelData) {
        self.data = data
        includeAppNames = true
        layoutPlan = PanelModel.makePlan(data: data)
    }

    // MARK: Fixtures

    static func fixtureData(_ c: PreviewCase, full: Bool, now: Date) -> PanelData {
        let f = PreviewScenario.fixture(c, full: full, now: now)
        let state: DataState
        switch c {
        case .collecting: state = .collecting
        case .stale: state = .stale(now.addingTimeInterval(-25 * 60))
        default: state = .fresh
        }
        return PreviewOverlay.apply(PanelData(fixture: f, state: state, now: now), full: full)
    }

    static func fixture(_ c: PreviewCase, full: Bool = true, now: Date = Date()) -> PanelModel {
        PanelModel(data: fixtureData(c, full: full, now: now))
    }

    func load(_ c: PreviewCase, full: Bool = true, now: Date = Date()) {
        replace(PanelModel.fixtureData(c, full: full, now: now))
    }

    // MARK: State changes

    func replace(_ newData: PanelData) {
        var next = newData
        // Rollups and events belong to the model, not to the engine snapshot. Keep them when the new data has none.
        if next.rollups.isEmpty { next.rollups = data.rollups }
        if next.events.isEmpty { next.events = data.events }
        data = next
        recompute()
    }

    func setAuthorization(_ value: String) {
        guard value != authorization else { return }
        authorization = value
    }

    /// Engine mode writes the setting through to the engine (it keeps it in UserDefaults and in status.json).
    func setIncludeAppNames(_ on: Bool) {
        includeAppNames = on
        engine?.includeAppNamesInPrompt = on
    }

    private func recompute() {
        let next = PanelModel.makePlan(data: data)
        if next != layoutPlan { layoutPlan = next }
    }

    private static func makePlan(data: PanelData) -> PanelLayoutPlan {
        PanelLayout.plan(PanelLayoutInput(verdicts: data.verdicts, hasBattery: data.hasBattery))
    }

    // MARK: Reading helpers for the views

    var rowsInput: PanelRowsInput {
        PanelRowsInput(verdicts: data.verdicts, current: data.current, dataState: data.dataState,
                       diskGrowth: data.status?.items.disk.growth ?? [:], topApps: data.apps, now: data.now)
    }

    /// The breakdown rows in plan order.
    var rows: [PanelRowState] { PanelRows.make(order: layoutPlan.rows, input: rowsInput) }

    var anomalyBars: [AnomalyBar] {
        PanelAnomalies.bars(shown: layoutPlan.shownAnomalies, verdicts: data.verdicts, now: data.now)
    }

    var areaState: PanelAreaState {
        PanelAreaState.make(dataState: data.dataState, anomalyCount: layoutPlan.anomalies.count,
                            records: data.events.count,
                            now: data.now)
    }

    var footerState: PanelFooterState {
        PanelFooterState.make(dataState: data.dataState, anomalyCount: layoutPlan.anomalies.count)
    }

    func spark(for item: SidebarItem) -> SparkSeries {
        // While collecting, the row shows only the dashed baseline. No measured curve exists yet.
        if case .collecting = data.dataState { return .empty(now: data.now) }
        return SparkSeries.make(item, trend: data.trend, disk: data.diskSeries, now: data.now)
    }

    /// Apps sorted for one list. The minimum-use filter and the order come from `AppRanking.top`.
    func topApps(by key: AppSortKey, count: Int = 5) -> [AppUsage] {
        AppRanking.top(data.apps, by: key, count: count)
    }

    // MARK: Sidebar and hover

    private func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The pointer moved over a region. `point` is in any fixed coordinate space of the panel.
    func pointerMoved(_ region: HoverRegion, at point: CGPoint) {
        let speed = pointer.speed(to: point, at: clock())
        if case .row(let item) = region { if hoverRow != item { hoverRow = item } } else if hoverRow != nil { hoverRow = nil }
        apply(intent.handle(.moved(region, speed: speed), at: clock()))
        scheduleDeadline()
    }

    func pointerLeft() {
        pointer.reset()
        if hoverRow != nil { hoverRow = nil }
        apply(intent.handle(.moved(.outside, speed: 0), at: clock()))
        scheduleDeadline()
    }

    /// A click on a row or on an anomaly bar: open and pin, or close when this row is pinned already.
    func rowClicked(_ item: SidebarItem) {
        let wasPinned = (pinnedItem == item)
        if wasPinned { unpinSidebar() } else { pinSidebar(item) }
        // The intent keeps its own state. Its commands are idempotent: they cannot undo the choice above.
        let commands = intent.handle(.clicked(item), at: clock())
        apply(commands.filter { cmd in
            if wasPinned { if case .pin = cmd { return false } } else { if case .unpin = cmd { return false } }
            return true
        })
        scheduleDeadline()
    }

    private func apply(_ commands: [HoverCommand]) {
        for command in commands {
            switch command {
            case .open(let item), .switchTo(let item):
                guard pinnedItem == nil else { break }
                setSidebar(item)
            case .close:
                guard pinnedItem == nil else { break }
                setSidebar(nil)
            case .pin(let item):
                pinSidebar(item)
            case .unpin:
                unpinSidebar()
            }
        }
    }

    private func scheduleDeadline() {
        deadlineWork?.cancel()
        deadlineWork = nil
        guard let deadline = intent.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deadlineWork = nil
            self.apply(self.intent.fire(at: self.clock()))
            self.scheduleDeadline()
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - clock()), execute: work)
    }

    /// Sets the open sidebar item. Idempotent. Calls the window only when open or closed changes.
    private func setSidebar(_ item: SidebarItem?) {
        let wasOpen = sidebarItem != nil
        if sidebarItem != item { sidebarItem = item }
        if item != nil { loadSidebarData() }
        if wasOpen != (item != nil) {
            chrome?.setSidebar(open: item != nil, animated: !(chrome?.isReduceMotion ?? true))
        }
    }

    func pinSidebar(_ item: SidebarItem) {
        pinnedItem = item
        setSidebar(item)
    }

    func unpinSidebar() {
        pinnedItem = nil
        setSidebar(nil)
    }

    /// The window calls this when it closes the panel. All state of one opening ends here.
    func panelDidClose() {
        deadlineWork?.cancel()
        deadlineWork = nil
        intent = HoverIntent()
        pointer.reset()
        hoverRow = nil
        keyFocus = nil
        pinnedItem = nil
        if sidebarItem != nil { sidebarItem = nil }
        loadToken += 1
        cancelPending()
    }

    func panelDidOpen() {
        keyFocus = nil
        reloadEvents()
    }

    // MARK: Keyboard

    private var focusOrder: [PanelFocus] {
        var out: [PanelFocus] = layoutPlan.rows.map { .row($0) }
        let count = layoutPlan.anomalyRowCount
        for i in 0..<count { out.append(.anomaly(i)) }
        if layoutPlan.anomalies.isEmpty { out.append(.records) }
        out.append(.primary)
        out.append(.more)
        return out
    }

    func setKeyFocus(_ focus: PanelFocus?) {
        if keyFocus != focus { keyFocus = focus }
    }

    /// Handles one key. Returns true when the key was used.
    @discardableResult
    func handleKey(_ key: PanelKey) -> Bool {
        switch key {
        case .down, .up:
            let rows = layoutPlan.rows
            guard !rows.isEmpty else { return false }
            var index = -1
            if case .row(let item)? = keyFocus, let i = rows.firstIndex(of: item) { index = i }
            let next: Int
            if index < 0 { next = (key == .down) ? 0 : rows.count - 1 } else { next = max(0, min(rows.count - 1, index + (key == .down ? 1 : -1))) }
            setKeyFocus(.row(rows[next]))
            if sidebarItem != nil, pinnedItem != nil { pinSidebar(rows[next]) }
            return true
        case .tab, .backTab:
            let order = focusOrder
            guard !order.isEmpty else { return false }
            let step = (key == .tab) ? 1 : -1
            if let focus = keyFocus, let i = order.firstIndex(of: focus) {
                setKeyFocus(order[(i + step + order.count) % order.count])
            } else {
                setKeyFocus(step > 0 ? order.first : order.last)
            }
            return true
        case .right:
            if case .row(let item)? = keyFocus { pinSidebar(item); return true }
            return false
        case .returnKey, .space:
            return activateFocus()
        case .left:
            if sidebarItem != nil { unpinSidebar(); return true }
            return false
        case .escape:
            if sidebarItem != nil { unpinSidebar(); return true }
            chrome?.closePanel()
            return true
        case .copy:
            copy(.primary)
            return true
        }
    }

    private func activateFocus() -> Bool {
        guard let focus = keyFocus else { return false }
        switch focus {
        case .row(let item): pinSidebar(item)
        case .anomaly(let i):
            let shown = layoutPlan.shownAnomalies
            if i < shown.count { pinSidebar(SidebarItem(shown[i])) } else { pinSidebar(.anomalyLog) }
        case .records: pinSidebar(.anomalyLog)
        case .primary: copy(.primary)
        case .more: onShowMoreMenu?()
        }
        return true
    }

    // MARK: Sidebar data

    /// Reads the 5 minute windows and the records off the main thread. Engine mode only.
    private func loadSidebarData() {
        guard engine != nil else { return }
        loadToken += 1
        let token = loadToken
        let dir = PanelPaths.dataDirURL
        let now = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let windows = RollupStore.read(dir: dir, from: now.addingTimeInterval(-7 * 86400), to: now).windows
            let events = EventLog.read(dir: dir, days: 7, now: now)
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                self.data.rollups = windows
                self.data.events = events
            }
        }
    }

    private func reloadEvents() {
        guard engine != nil else { return }
        let dir = PanelPaths.dataDirURL
        let now = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = EventLog.read(dir: dir, days: 7, now: now)
            DispatchQueue.main.async { self?.data.events = events }
        }
    }

    // MARK: Copy

    func scope(for target: CopyTarget) -> PromptScope {
        let problems = data.problems
        guard problems.count == 1, let item = problems.first?.item, let topic = ProblemOrder.topic(for: item) else { return .overview }
        return .topic(topic)
    }

    /// The prompt text. Engine mode asks the engine (real environment, freshness, CPU summary). Fixture mode builds it from the fixture.
    func promptText(_ scope: PromptScope) -> String {
        if let engine { return engine.prompt(scope: scope) }
        let env = PromptEnvironment(model: nil, chip: nil, memoryBytes: data.current.physicalMemory,
                                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                                    appVersion: AppInfo.version, cliPath: PanelPaths.cliDisplayPath,
                                    dataDir: PanelPaths.dataDirDisplayPath)
        let input = PromptInput(env: env, sampledAt: data.current.sampledAt ?? data.now, freshness: .fresh,
                                verdicts: data.verdicts, current: data.current, apps: data.apps, appsBasis: data.appsBasis,
                                cpuSummary: nil, diskGrowth: data.status?.items.disk.growth ?? [:])
        let options = PromptOptions.forCurrentUser(includeAppNames: includeAppNames)
        return PromptBuilder.build(input, scope: scope, options: options)
    }

    /// Text of the bubble after the last copy. Nil outside the copied or failed state.
    var copyBubble: String? {
        if copyFailed { return footerState.failedBubble }
        return copied.isEmpty ? nil : footerState.copiedBubble
    }

    /// Copies the prompt and shows "✓ 已复制" for 1.5 seconds. A failed copy shows the failure bubble instead.
    /// The collecting state has no usable button, so it does nothing.
    func copy(_ target: CopyTarget) {
        guard footerState.enabled else { return }
        let text = promptText(scope(for: target))
        revertWork?.cancel()
        let ok = onCopyText(text)
        if ok {
            copyFailed = false
            copied.insert(target)
        } else {
            copied.remove(target)
            copyFailed = true
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copied.removeAll()
            self.copyFailed = false
            self.revertWork = nil
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelModel.copiedSeconds, execute: work)
    }

    /// Copies a fixed text (the CLI menu commands).
    func copyCommand(_ text: String) {
        _ = onCopyText(text)
    }

    func cancelPending() {
        revertWork?.cancel()
        revertWork = nil
        copied.removeAll()
        copyFailed = false
    }

    // MARK: Engine

    /// Engine mode: the model follows the engine's published properties until `detach()`.
    func attach(engine: MonitorEngine) {
        detach()
        self.engine = engine
        includeAppNames = engine.includeAppNamesInPrompt
        setAuthorization(engine.authorization)
        engineCancellable = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSync() }
        syncFromEngine()
        reloadEvents()
    }

    func detach() {
        engineCancellable?.cancel()
        engineCancellable = nil
        engine = nil
        panelDidClose()
    }

    /// Opens the sidebar of one problem item (a tapped notification). An item that is no problem is ignored.
    func expand(_ item: HealthItem?) {
        guard let item, data.problems.contains(where: { $0.item == item }) else { return }
        pinSidebar(SidebarItem(item))
    }

    /// `objectWillChange` fires before the value is stored, so the read waits one main-queue turn.
    private func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncPending = false
            self.syncFromEngine()
        }
    }

    private func syncFromEngine() {
        guard let engine else { return }
        setAuthorization(engine.authorization)
        replace(PanelEngineAdapter.data(engine: engine, now: Date()))
    }
}

/// Pointer speed in pt/ms between two moves. Not published: it must not redraw anything.
struct PointerTracker {
    private var last: CGPoint?
    private var lastTime: TimeInterval = 0

    mutating func speed(to point: CGPoint, at time: TimeInterval) -> Double {
        let previous = last
        let previousTime = lastTime
        last = point
        lastTime = time
        guard let previous, time > previousTime else { return 0 }
        let dx = Double(point.x - previous.x), dy = Double(point.y - previous.y)
        return (dx * dx + dy * dy).squareRoot() / ((time - previousTime) * 1000)
    }

    mutating func reset() { last = nil }
}

// MARK: - Engine adapter

enum PanelEngineAdapter {
    /// A reading older than this makes the data stale even when the engine did not report it.
    static let staleAge: TimeInterval = 420

    /// The card data from the published state of the engine. Main thread.
    @MainActor
    static func data(engine: MonitorEngine, now: Date) -> PanelData {
        var verdicts = engine.verdicts
        if verdicts.isEmpty {
            // Before the first evaluation every item reads "collecting".
            for item in HealthItem.allCases {
                verdicts.append(ItemVerdict(item: item, level: .unknown, reasonCode: "collecting", headline: "统计中",
                                            since: nil, levelChangedAt: nil, alert: nil))
            }
            verdicts = ProblemOrder.all(verdicts)
        }
        var state = engine.dataState
        if case .fresh = state, let at = engine.current.sampledAt, now.timeIntervalSince(at) > staleAge {
            state = .stale(at)
        }
        let readable = engine.coverage.readable + engine.coverage.unreadable
        return make(verdicts: verdicts, current: engine.current, trend: engine.trend, sleeps: engine.sleeps, apps: engine.topApps,
                    appsBasis: engine.appsBasis, coverage: readable > 0 ? engine.coverage : nil, status: engine.status,
                    diskSeries: engine.diskSeries, diskTrigger: engine.diskTrigger, state: state, now: now)
    }

    /// Fills the disk capacity triple from the status file when the sampler did not (A2a fills it later).
    static func withDiskTriple(_ current: CurrentReadings, status: StatusFile?) -> CurrentReadings {
        var c = current
        guard let disk = status?.items.disk else { return c }
        if c.diskTotal == nil { c.diskTotal = disk.total.status == .ok ? disk.total.value : nil }
        if c.diskUsed == nil { c.diskUsed = disk.used.status == .ok ? disk.used.value : nil }
        if c.diskPurgeable == nil { c.diskPurgeable = disk.purgeableEstimate.status == .ok ? disk.purgeableEstimate.value : nil }
        return c
    }

    /// Builds the data and the dog input. Used for the engine and for the icon.
    static func make(verdicts: [ItemVerdict], current: CurrentReadings, trend: TrendSeries, sleeps: [SleepRecord],
                     apps: [AppUsage], appsBasis: String, coverage: ProcessCoverage?, status: StatusFile?,
                     diskSeries: [DiskPoint], diskTrigger: DiskTrigger?, state: DataState, now: Date) -> PanelData {
        let worst = ProblemOrder.problems(verdicts).first
        let memoryLevel: HealthLevel = verdicts.first(where: { $0.item == .memory })?.level ?? .green
        var isStatic = true
        if case .fresh = state { isStatic = false }
        let dog = DogInput(cpuPercent: current.cpuPercent, thermal: current.thermal, memoryLevel: memoryLevel,
                           worstProblem: worst?.item, worstLevel: worst?.level ?? .green, isStatic: isStatic)
        return PanelData(verdicts: verdicts, current: PanelEngineAdapter.withDiskTriple(current, status: status), trend: trend,
                         sleeps: sleeps, apps: apps, coverage: coverage, status: status, diskSeries: diskSeries,
                         diskTrigger: diskTrigger, dogInput: dog, dataState: state, now: now, appsBasis: appsBasis)
    }
}

// MARK: - Paths shown to the user

enum PanelPaths {
    /// A path with the home folder written as `~`.
    static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static var cliDisplayPath: String {
        display(Bundle.main.bundlePath + "/Contents/Helpers/molemonitor-cli")
    }

    static var dataDirDisplayPath: String {
        display(MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment).path)
    }

    static var dataDirURL: URL {
        MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)
    }
}
