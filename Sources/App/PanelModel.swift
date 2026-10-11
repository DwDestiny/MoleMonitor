// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A PreviewFixture (previews, UI regression) or a MonitorEngine (the running app); user actions from the views.
// Output: PanelData, the layout plan and the UI state (open row, disclosures, copy state) that the status card views read.
// Pos: The only file that knows where the data comes from. Views read PanelModel and never the engine (docs/DESIGN.md 8.3).
//      Keeps one stopgap: `PanelPlanFit` completes the skeleton plan (evidence height, compression). Delete it when I1's real PanelLayout lands.

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

// MARK: - Plan fit (stopgap)

/// WIRE-LATER: delete when I1's real `PanelLayout.plan` lands. The skeleton plan has a fixed evidence height of 102 and
/// no compression. This completes it by docs/DESIGN.md 2.11. On a real plan (compressions set, or evidence height
/// not 102) it returns the plan unchanged, and the same arithmetic gives the same numbers.
enum PanelPlanFit {
    static func fit(_ plan: PanelLayoutPlan) -> PanelLayoutPlan {
        if !plan.compressions.isEmpty { return plan }
        var cardItem: HealthItem?
        for s in plan.sections {
            if case .problemCard(let item, _, let evidence) = s {
                if evidence != 102 { return plan }
                cardItem = item
            }
        }
        guard let item = cardItem else { return fitQuiet(plan) }

        var sections = plan.sections
        // A CPU, memory or thermal card carries the app list, so the separate apps row goes away.
        if item == .cpu || item == .memory || item == .thermal {
            sections.removeAll(where: isApps)
        }
        var applied = [PanelCompression]()
        for step in PanelCompression.allCases {
            if evidence(sections, applied, tier: plan.tier) >= PanelMetrics.evidenceMin { break }
            if apply(step, to: &sections) { applied.append(step) }
        }
        let e = evidence(sections, applied, tier: plan.tier)
        let clamped = min(PanelMetrics.evidenceMax, max(PanelMetrics.evidenceMin, e))
        sections = sections.map { (s: PanelSection) -> PanelSection in
            if case .problemCard(let it, let compact, _) = s { return .problemCard(it, compact: compact, evidenceHeight: clamped) }
            return s
        }
        var result = plan
        result.sections = sections
        result.compressions = applied
        return result
    }

    /// The quiet plan has no card. It only needs to fit the tier, so it merges the apps row when an authorization row is shown.
    private static func fitQuiet(_ plan: PanelLayoutPlan) -> PanelLayoutPlan {
        var sections = plan.sections
        var applied = [PanelCompression]()
        for step in PanelCompression.allCases {
            if PanelGeometry.total(sections, applied) <= plan.tier { break }
            if apply(step, to: &sections) { applied.append(step) }
        }
        var result = plan
        result.sections = sections
        result.compressions = applied
        return result
    }

    private static func isApps(_ s: PanelSection) -> Bool {
        if case .appsDisclosure = s { return true }
        return false
    }

    private static func isSummary(_ s: PanelSection) -> Bool {
        if case .normalSummary = s { return true }
        return false
    }

    private static func isAuthorization(_ s: PanelSection) -> Bool {
        if case .authorization = s { return true }
        return false
    }

    private static func evidence(_ sections: [PanelSection], _ applied: [PanelCompression], tier: Double) -> Double {
        let shell = sections.map { s -> PanelSection in
            if case .problemCard(let it, let compact, _) = s { return .problemCard(it, compact: compact, evidenceHeight: 0) }
            return s
        }
        return tier - PanelGeometry.total(shell, applied)
    }

    /// Applies one step. Returns false when the step changes nothing.
    private static func apply(_ step: PanelCompression, to sections: inout [PanelSection]) -> Bool {
        var changed = false
        switch step {
        case .mergeApps:
            let hadApps = sections.contains(where: isApps)
            if hadApps {
                sections.removeAll(where: isApps)
                sections = sections.map { (s: PanelSection) -> PanelSection in
                    if case .moreDisclosure(let expanded, _, let auth) = s {
                        return .moreDisclosure(expanded: expanded, includesApps: true, includesAuthorization: auth)
                    }
                    return s
                }
                changed = true
            }
        case .disclosure26:
            changed = sections.contains { (s: PanelSection) -> Bool in
                switch s {
                case .appsDisclosure, .moreDisclosure: return true
                default: return false
                }
            }
        case .compactCard:
            sections = sections.map { (s: PanelSection) -> PanelSection in
                if case .problemCard(let it, let compact, let e) = s {
                    if !compact { changed = true }
                    return .problemCard(it, compact: true, evidenceHeight: e)
                }
                return s
            }
        case .compactRows:
            sections = sections.map { (s: PanelSection) -> PanelSection in
                if case .problemRow(let it, let compact) = s {
                    if !compact { changed = true }
                    return .problemRow(it, compact: true)
                }
                return s
            }
        case .hideSummary:
            let had = sections.contains(where: isSummary)
            if had {
                sections.removeAll(where: isSummary)
                changed = true
            }
        case .foldAuthorization:
            let had = sections.contains(where: isAuthorization)
            if had {
                sections.removeAll(where: isAuthorization)
                sections = sections.map { (s: PanelSection) -> PanelSection in
                    if case .moreDisclosure(let expanded, let apps, _) = s {
                        return .moreDisclosure(expanded: expanded, includesApps: apps, includesAuthorization: true)
                    }
                    return s
                }
                changed = true
            }
        }
        return changed
    }
}

// MARK: - Pasteboard

enum PanelPasteboard {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject {
    static let copiedSeconds = 1.5
    private static let includeAppsKey = "MoleMonitor.promptIncludeApps"

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
    var onCopyText: (String) -> Bool = { PanelPasteboard.copy($0) }
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
        let stored = UserDefaults.standard.object(forKey: Self.includeAppsKey) as? Bool
        includeAppNames = stored ?? true
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

    func setIncludeAppNames(_ on: Bool) {
        includeAppNames = on
        UserDefaults.standard.set(on, forKey: Self.includeAppsKey)
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
        return PanelPlanFit.fit(PanelLayout.plan(input))
    }

    // MARK: Reading helpers for the views

    /// The item shown as the open card, or nil in the quiet mode.
    var openItem: HealthItem? {
        for s in layoutPlan.sections {
            if case .problemCard(let item, _, _) = s { return item }
        }
        return nil
    }

    /// Apps sorted for one list. WIRE-LATER: use `AppRanking.top` when I1's version lands (the skeleton returns an empty list).
    func topApps(by key: AppSortKey, count: Int = 5) -> [AppUsage] {
        let sorted: [AppUsage]
        switch key {
        case .cpu:
            sorted = data.apps.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
        case .memory:
            sorted = data.apps.sorted { ($0.memoryBytes ?? -1) > ($1.memoryBytes ?? -1) }
        }
        return Array(sorted.prefix(count))
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

    /// WIRE-LATER: replace the body with `engine.prompt(scope:)` when I1's engine lands.
    func promptText(_ scope: PromptScope) -> String {
        let env = PromptEnvironment(model: nil, chip: nil, memoryBytes: data.current.physicalMemory,
                                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                                    appVersion: AppInfo.version, cliPath: PanelPaths.cliDisplayPath,
                                    dataDir: PanelPaths.dataDirDisplayPath)
        let input = PromptInput(env: env, sampledAt: data.current.sampledAt ?? data.now, freshness: .fresh,
                                verdicts: data.verdicts, current: data.current, apps: data.apps, appsBasis: "实时",
                                cpuSummary: nil, diskGrowth: data.status?.items.disk.growth ?? [:])
        let options = PromptOptions(includeAppNames: includeAppNames, maxLength: 3000,
                                    homeDirectory: NSHomeDirectory(), userNames: [NSUserName()])
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

    // MARK: Engine (WIRE-LATER)

    /// WIRE-LATER: I1's engine publishes verdicts, current, trend, topApps, coverage, dataState, sleeps.
    /// Until then this builds a degraded PanelData from the phase 1 engine: the disk verdict is real, the others are "统计中".
    func attach(engine: MonitorEngine) {
        detach()
        self.engine = engine
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
        let next = PanelEngineAdapter.data(status: engine.status, alerts: engine.alerts, series: engine.diskSeries,
                                           trigger: engine.diskTrigger, live: engine.live, now: Date())
        setAuthorization(engine.authorization)
        replace(next)
    }
}

// MARK: - Engine adapter (WIRE-LATER)

enum PanelEngineAdapter {
    static let staleAge: TimeInterval = 420

    static func data(status: StatusFile?, alerts: [AlertItem], series: [DiskPoint], trigger: DiskTrigger?,
                     live: LiveSnapshot, now: Date) -> PanelData {
        var current = CurrentReadings()
        current.cpuPercent = live.cpuPercent
        current.rx = live.rx
        current.tx = live.tx
        current.sampledAt = status?.writtenAt

        var verdicts = [ItemVerdict]()
        for item in HealthItem.allCases {
            if item == .disk, let disk = status?.items.disk {
                let alert = alerts.first
                verdicts.append(ItemVerdict(item: .disk, level: disk.level, reasonCode: disk.reasonCode, headline: disk.reason,
                                            since: disk.since, levelChangedAt: disk.levelChangedAt, alert: alert))
            } else {
                verdicts.append(ItemVerdict(item: item, level: .unknown, reasonCode: "collecting", headline: "统计中",
                                            since: nil, levelChangedAt: nil, alert: nil))
            }
        }
        verdicts = ProblemOrder.all(verdicts)

        var points = [TrendPoint]()
        for p in live.cpu { points.append(TrendPoint(t: p.t, cpu: p.percent)) }
        for p in live.net { points.append(TrendPoint(t: p.t, rx: p.rx, tx: p.tx)) }
        points.sort { $0.t < $1.t }
        let trend = points.isEmpty ? TrendSeries.empty : TrendSeries(segments: [points])

        var state: DataState = .fresh
        if let written = status?.writtenAt {
            if now.timeIntervalSince(written) > staleAge { state = .stale(written) }
        } else {
            state = .collecting
        }
        let worst = ProblemOrder.problems(verdicts).first
        let dog = DogInput(cpuPercent: live.cpuPercent, thermal: nil, memoryLevel: .green, worstProblem: worst?.item,
                           worstLevel: worst?.level ?? .green, isStatic: state != .fresh)

        return PanelData(verdicts: verdicts, current: current, trend: trend, sleeps: [], apps: [], coverage: nil,
                         status: status, diskSeries: series, diskTrigger: trigger, dogInput: dog, dataState: state, now: now)
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
