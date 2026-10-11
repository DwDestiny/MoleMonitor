// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A PreviewFixture (previews, UI regression) or a MonitorEngine (the running app); user actions from the views.
// Output: PanelData, the layout plan and the UI state (open row, disclosures, copy state) that the status card views read.
// Pos: The only file that knows where the data comes from. Views read PanelModel and never the engine (docs/DESIGN.md 8.3).
//      Engine mode reads the published properties of MonitorEngine (PanelEngineAdapter) and copies with `engine.prompt(scope:)`.
//      Fixture mode (previews, UI regression) reads PreviewScenario.fixture and builds the prompt from the fixture data.

import AppKit
import Combine
import Foundation

// MARK: - Data

/// Everything the card shows at one moment. A plain value, so a static render needs no engine.
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
    /// "实时", "近 N 分钟" or "采样于 HH:mm". The header of the app lists shows it.
    var appsBasis: String = "实时"

    func verdict(_ item: HealthItem) -> ItemVerdict? {
        verdicts.first { $0.item == item }
    }

    /// Problem items in `ProblemOrder` order.
    var problems: [ItemVerdict] { ProblemOrder.problems(verdicts) }

    /// Lamp items in `ProblemOrder.all` order: every problem item, then thermal, memory and CPU.
    /// Disk and power are lamps only while they are problems (docs/DESIGN.md 2.2).
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
}

extension PanelData {
    init(fixture f: PreviewFixture, state: DataState, now: Date) {
        self.init(verdicts: f.verdicts, current: f.current, trend: f.trend, sleeps: f.sleeps, apps: f.apps,
                  coverage: nil, status: f.status, diskSeries: f.diskSeries, diskTrigger: f.diskTrigger,
                  dogInput: f.dogInput, dataState: state, now: now)
    }
}

/// What a copy action copies, and which button shows the "copied" state.
enum CopyTarget: Hashable {
    case primary
    case row(HealthItem)
}

// MARK: - Geometry (shared by the plan fit and the views)

enum PanelGeometry {
    static func height(of s: PanelSection, _ compressions: [PanelCompression]) -> Double {
        let narrow = compressions.contains(.disclosure26)
        switch s {
        case .hero(let quiet): return quiet ? PanelMetrics.heroQuiet : PanelMetrics.heroProblem
        case .trendStrip: return PanelMetrics.trendStrip
        case .problemCard(_, let compact, let evidence):
            return (compact ? PanelMetrics.cardChromeCompact : PanelMetrics.cardChrome) + evidence
        case .problemRow(_, let compact): return compact ? PanelMetrics.problemRowCompact : PanelMetrics.problemRow
        case .copyCTA: return PanelMetrics.cta
        case .normalSummary: return PanelMetrics.normalSummary
        case .appsDisclosure, .moreDisclosure: return narrow ? PanelMetrics.disclosureCompact : PanelMetrics.disclosure
        case .authorization: return PanelMetrics.authorization
        case .footer: return PanelMetrics.footer
        }
    }

    /// Space between two neighbor sections (docs/DESIGN.md 2.5).
    static func gap(_ a: PanelSection, _ b: PanelSection) -> Double {
        switch (a, b) {
        case (.problemCard, .problemRow), (.problemCard, .copyCTA): return PanelMetrics.cardRowGap
        case (.problemRow, .problemRow): return PanelMetrics.rowGap
        case (.problemRow, .copyCTA): return PanelMetrics.cardRowGap
        case (.appsDisclosure, .footer), (.moreDisclosure, .footer), (.authorization, .footer): return PanelMetrics.sectionGap
        case (.appsDisclosure, _), (.moreDisclosure, _): return PanelMetrics.rowGap
        default: return PanelMetrics.sectionGap
        }
    }

    /// Total content height of a section list, including the padding of the card.
    static func total(_ sections: [PanelSection], _ compressions: [PanelCompression]) -> Double {
        var sum = 2 * PanelMetrics.padding
        var previous: PanelSection?
        for s in sections {
            if let p = previous { sum += gap(p, s) }
            sum += height(of: s, compressions)
            previous = s
        }
        return sum
    }

    /// Stable identity of a section, for fade transitions.
    static func key(_ s: PanelSection) -> String {
        switch s {
        case .hero: return "hero"
        case .trendStrip: return "trend"
        case .problemCard(let item, _, _): return "card." + item.rawValue
        case .problemRow(let item, _): return "row." + item.rawValue
        case .copyCTA: return "cta"
        case .normalSummary: return "summary"
        case .appsDisclosure: return "apps"
        case .moreDisclosure: return "more"
        case .authorization: return "auth"
        case .footer: return "footer"
        }
    }

    /// Entrance group: hero, problem area, button, the rest (docs/DESIGN.md 5.3).
    static func group(_ s: PanelSection) -> Int {
        switch s {
        case .hero: return 0
        case .trendStrip, .problemCard, .problemRow: return 1
        case .copyCTA: return 2
        default: return 3
        }
    }
}

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject {
    static let copiedSeconds = 1.5

    @Published private(set) var data: PanelData
    @Published private(set) var layoutPlan: PanelLayoutPlan
    @Published private(set) var expandedProblem: HealthItem?
    @Published private(set) var appsExpanded = false
    @Published private(set) var moreExpanded = false
    @Published private(set) var appsSort: AppSortKey = .cpu
    @Published private(set) var copied = Set<CopyTarget>()
    @Published private(set) var authorization: String = "authorized"
    @Published private(set) var includeAppNames: Bool
    /// Raised each time a disclosure opens, so the middle area scrolls to it.
    @Published private(set) var scrollTarget: String?

    /// Copies the text of a scope. Returns true when the text is on the pasteboard. The harness replaces it.
    var onCopyText: (String) -> Bool = { Clipboard.copy($0) }
    var onEnableNotifications: () -> Void = {}
    var onOpenNotificationSettings: () -> Void = {}
    var onOpenDataFolder: () -> Void = {}
    var onAbout: () -> Void = {}
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    /// Height of the visible screen area, passed to the plan.
    var screenVisibleHeight: Double = 1200

    private var screenHeightForPlan: Double { screenVisibleHeight }
    private var revertItems = [CopyTarget: DispatchWorkItem]()
    private var engineCancellable: AnyCancellable?
    private weak var engine: MonitorEngine?
    private var syncPending = false

    init(data: PanelData) {
        self.data = data
        includeAppNames = true
        layoutPlan = PanelModel.makePlan(data: data, expanded: nil, apps: false, more: false, auth: false, screen: 1200)
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
        return PanelData(fixture: f, state: state, now: now)
    }

    static func fixture(_ c: PreviewCase, full: Bool = true, now: Date = Date()) -> PanelModel {
        PanelModel(data: fixtureData(c, full: full, now: now))
    }

    func load(_ c: PreviewCase, full: Bool = true, now: Date = Date()) {
        replace(PanelModel.fixtureData(c, full: full, now: now))
    }

    // MARK: State changes

    func replace(_ newData: PanelData) {
        data = newData
        recompute()
    }

    func setAuthorization(_ value: String) {
        guard value != authorization else { return }
        authorization = value
        recompute()
    }

    /// Accordion: the tapped row opens as the card and the old card becomes a row. Height does not change.
    func toggleProblem(_ item: HealthItem) {
        expandedProblem = item
        recompute()
    }

    func setApps(expanded: Bool) {
        appsExpanded = expanded
        scrollTarget = expanded ? "apps" : nil
        recompute()
    }

    func setMore(expanded: Bool) {
        moreExpanded = expanded
        scrollTarget = expanded ? "more" : nil
        recompute()
    }

    func setAppsSort(_ key: AppSortKey) {
        appsSort = key
    }

    /// Engine mode writes the setting through to the engine (it keeps it in UserDefaults and in status.json).
    func setIncludeAppNames(_ on: Bool) {
        includeAppNames = on
        engine?.includeAppNamesInPrompt = on
    }

    private func recompute() {
        let next = PanelModel.makePlan(data: data, expanded: expandedProblem, apps: appsExpanded, more: moreExpanded,
                                       auth: authorization != "authorized", screen: screenHeightForPlan)
        if next != layoutPlan { layoutPlan = next }
    }

    private static func makePlan(data: PanelData, expanded: HealthItem?, apps: Bool, more: Bool, auth: Bool,
                                 screen: Double) -> PanelLayoutPlan {
        let input = PanelLayoutInput(verdicts: data.verdicts, showAuthorization: auth, expandedProblem: expanded,
                                     appsExpanded: apps, moreExpanded: more, screenVisibleHeight: screen)
        return PanelLayout.plan(input)
    }

    // MARK: Reading helpers for the views

    /// The item shown as the open card, or nil in the quiet mode.
    var openItem: HealthItem? {
        for s in layoutPlan.sections {
            if case .problemCard(let item, _, _) = s { return item }
        }
        return nil
    }

    /// Apps sorted for one list. The minimum-use filter and the order come from `AppRanking.top`.
    func topApps(by key: AppSortKey, count: Int = 5) -> [AppUsage] {
        AppRanking.top(data.apps, by: key, count: count)
    }

    // MARK: Copy

    func scope(for target: CopyTarget) -> PromptScope {
        switch target {
        case .primary:
            guard let item = openItem, let topic = ProblemOrder.topic(for: item) else { return .overview }
            return .topic(topic)
        case .row(let item):
            guard let topic = ProblemOrder.topic(for: item) else { return .overview }
            return .topic(topic)
        }
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

    /// Copies the prompt of a target and shows "copied" for 1.5 seconds. A failed copy shows nothing.
    func copy(_ target: CopyTarget) {
        let text = promptText(scope(for: target))
        guard onCopyText(text) else { return }
        copied.insert(target)
        revertItems[target]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copied.remove(target)
            self.revertItems[target] = nil
        }
        revertItems[target] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelModel.copiedSeconds, execute: work)
    }

    /// Copies a fixed text (the CLI menu commands).
    func copyCommand(_ text: String) {
        _ = onCopyText(text)
    }

    func cancelPending() {
        for (_, work) in revertItems { work.cancel() }
        revertItems.removeAll()
        copied.removeAll()
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
    }

    func detach() {
        engineCancellable?.cancel()
        engineCancellable = nil
        engine = nil
        cancelPending()
    }

    /// Opens the card of one problem item (a tapped notification). An item that is no problem is ignored.
    func expand(_ item: HealthItem?) {
        guard let item, data.problems.contains(where: { $0.item == item }) else { return }
        toggleProblem(item)
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
        return PanelData(verdicts: verdicts, current: current, trend: trend, sleeps: sleeps, apps: apps, coverage: coverage,
                         status: status, diskSeries: diskSeries, diskTrigger: diskTrigger, dogInput: dog, dataState: state,
                         now: now, appsBasis: appsBasis)
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
