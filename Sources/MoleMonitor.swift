// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Command line arguments and MonitorEngine state (status.json data in the data directory).
// Pos: Entry point and app lifecycle; no cleanup or privileged commands, no Go collector.
//      The menu bar icon is `StatusIconController` (I2) driven by `MenuIconModel`; the status item has no title text.
//      The status card is hosted here: PanelModel + PanelRoot in a PanelWindow (custom NSPanel, docs/DESIGN_V2.md 10). The window
//      sets its own height from the layout plan. No NSPopover in the release build.
import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let firstPanelShownKey = "MoleMonitor.firstPanelShown"

    // Internal (not private) so the UI regression harness can drive the real objects; no behavior change.
    let engine = MonitorEngine()
    /// The open status card. Nil when the card is closed. It stays set while the close motion runs.
    private(set) var panelWindow: PanelWindow?
    private(set) var statusItem: NSStatusItem?
#if UITEST
    /// Test only: anchor for the panel when the environment gives the status item no button.
    var testAnchor: NSView?
    /// Test only: answers the questions that the old UI regression asks an NSPopover (isShown, contentViewController, appearance,
    /// performClose) from the PanelWindow. Not a window path: the build has no NSPopover window, see UITestWindowChecks.swift.
    lazy var popover: NSPopover = UITestPopoverAdapter(delegate: self)
    /// Test only: the entrance of the next open. Nil follows PanelEntranceGate.
    var testEntrance: PanelEntrance?
#endif
    private var cancellables = Set<AnyCancellable>()
    /// The last icon state given to the controller (posture and badge). The UI regression reads it.
    private(set) var menuIconState: MenuIconState?
    private lazy var iconController = StatusIconController(statusItem: statusItem)
    /// Model of the open status card. Created on open, released on close.
    private(set) var panelModel: PanelModel?
    private var planObserver: AnyCancellable?
    private var keyMonitor: Any?
#if UITEST
    /// Test only: while true, the engine does not change the menu bar icon (the icon check drives it by hand).
    var suspendIconUpdates = false
#endif
#if UITEST
    /// Test only: a model with fixture data. When set, the next open shows it and does not attach the engine.
    var testModel: PanelModel?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before start(): the engine may create the data directory.
        let showFirstPanel = engine.isFirstLaunch
            && !UserDefaults.standard.bool(forKey: Self.firstPanelShownKey)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageOnly
        }

        // Hollow icon until the first evaluation.
        applyMenuIcon(verdicts: [], dataState: .collecting)
        // The menu bar icon follows the verdicts and the data state of the engine. The sink receives the new values.
        Publishers.CombineLatest(engine.$verdicts, engine.$dataState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] verdicts, dataState in
                self?.applyMenuIcon(verdicts: verdicts, dataState: dataState)
            }
            .store(in: &cancellables)
        // A tapped notification opens the card and pins the sidebar of the item of the notification (R-14).
        engine.openCardHandler = { [weak self] item in self?.openPanel(pinning: item) }

        engine.start()

        if showFirstPanel {
            // Wait a moment so the status item has a window to anchor the panel.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self else { return }
                self.showPanel()
                UserDefaults.standard.set(true, forKey: Self.firstPanelShownKey)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: Icon

    /// Posture and badge come from `MenuIconModel` (Core). The tooltip and the VoiceOver text are the same text. The icon has no title text
    /// (docs/DESIGN.md 3.1: the icon is the Bichon head with a category badge only).
    func applyMenuIcon(verdicts: [ItemVerdict], dataState: DataState) {
#if UITEST
        if suspendIconUpdates { return }
#endif
        let state = MenuIconModel.state(verdicts, dataState: dataState)
        let text = MenuIconModel.text(verdicts, dataState: dataState, now: Date())
        menuIconState = state
        iconController.apply(state, text: text)
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if let window = panelWindow {
            // A click during the close motion is ignored: the panel is already going away.
            if !window.isClosing { window.closePanel() }
        } else {
            showPanel()
        }
    }

    /// Opens the card, or keeps it open, and pins the sidebar of one item. Called when the user taps a notification (R-14).
    /// The model of the content gets `PanelPinning.pinSidebar` through the window.
    func openPanel(pinning item: HealthItem?) {
        if panelWindow == nil { showPanel() }
        if let side = NotificationPlanner.sidebarItem(for: item) { panelWindow?.openAndPin(side) }
    }

    func showPanel() {
#if UITEST
        let anchor = statusItem?.button ?? testAnchor
#else
        let anchor = statusItem?.button
#endif
        guard panelWindow == nil, let button = anchor else { return }
        let model = makePanelModel(for: button)
        panelModel = model
#if UITEST
        let entrance = testEntrance ?? PanelEntranceGate.next()
#else
        let entrance = PanelEntranceGate.next()
#endif
        let root = AnyView(PanelRoot(model: model, entrance: entrance))
        let spot = PanelWindow.makePlacement(anchor: button, height: model.layoutPlan.height)
        let window = PanelWindow(placement: spot.placement, visibleMinY: spot.visibleMinY, main: root,
                                 sidebar: AnyView(PanelSidebar(model: model)))
        window.statusItemWindow = button.window
        // The model serves the window as PanelPinning, and it controls the sidebar through the window as PanelChrome.
        window.pinning = model
        model.chrome = window
        installKeyMonitor(model: model, window: window)
        window.onClosed = { [weak self] in self?.panelDidClose() }
        panelWindow = window
        planObserver = model.$layoutPlan
            .map { $0.height }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak window] height in window?.setContentHeight(height, animated: true) }
        engine.panelOpened()
#if UITEST
        NotificationCenter.default.post(name: NSPopover.willShowNotification, object: popover)
#endif
        window.present()
    }

    /// Forwards the keys of the open panel to `PanelModel.handleKey` (DESIGN_V2.md 10.10). Esc stays with the window.
    /// The monitor is local and exists only while the panel is open.
    private func installKeyMonitor(model: PanelModel, window: PanelWindow) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model, weak window] event in
            MainActor.assumeIsolated {
                guard let model, let window, window.isKeyWindow else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var key: PanelKey?
                switch event.keyCode {
                case 126 where flags.isEmpty: key = .up
                case 125 where flags.isEmpty: key = .down
                case 123 where flags.isEmpty: key = .left
                case 124 where flags.isEmpty: key = .right
                case 48 where flags.isEmpty: key = .tab
                case 48 where flags == .shift: key = .backTab
                case 36 where flags.isEmpty, 76 where flags.isEmpty: key = .returnKey
                case 49 where flags.isEmpty: key = .space
                default:
                    if flags == .command, event.charactersIgnoringModifiers == "c" { key = .copy }
                }
                guard let key else { return event }
                return model.handleKey(key) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }

    private func makePanelModel(for button: NSView) -> PanelModel {
        var model: PanelModel?
#if UITEST
        model = testModel
#endif
        let fromEngine = (model == nil)
        let created = model ?? PanelModel(data: PanelEngineAdapter.data(engine: engine, now: Date()))
        let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200
        created.screenVisibleHeight = Double(visible)
        created.onEnableNotifications = { [weak self] in self?.engine.requestNotificationAuthorization() }
        created.onOpenNotificationSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        created.onOpenDataFolder = { NSWorkspace.shared.open(PanelPaths.dataDirURL) }
        created.onAbout = { NSApp.orderFrontStandardAboutPanel(nil) }
        created.onQuit = { NSApplication.shared.terminate(nil) }
        if fromEngine {
            created.setAuthorization(engine.authorization)
            created.attach(engine: engine)
        }
        return created
    }

    /// The window has closed and released its content. Release the model and tell the engine: nothing renders while the card is closed.
    private func panelDidClose() {
        removeKeyMonitor()
        planObserver = nil
        panelModel?.detach()
        panelModel = nil
        panelWindow = nil
        engine.panelClosed()
    }
}

// MARK: - Entry

@main
@MainActor
enum MoleMonitorMain {
    static func main() {
        let args = CommandLine.arguments
#if UITEST
        if args.contains("--ui-test") { UITestHarness.run(args) }
#endif
        if args.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if args.contains("--diagnose") {
            Diagnose.run(args)
            return
        }
        if args.contains("--preview") {
            guard let path = argumentValue("--preview", in: args) else {
                FileHandle.standardError.write(Data("--preview needs an absolute output path.\n".utf8))
                exit(2)
            }
            if let error = PanelPreview.render(to: URL(fileURLWithPath: path)) {
                FileHandle.standardError.write(Data((error + "\n").utf8))
                exit(1)
            }
            print(path)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static func argumentValue(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        return value.hasPrefix("--") ? nil : value
    }
}

// MARK: - --self-test

// SELFTEST-BEGIN (Foundation and Core only; scripts may extract this block for a Linux type check)
enum SelfTest {
    /// Synthetic 5-day disk history 200 -> 150 -> 450 GB, plus the null encoding of a missing value.
    static func run() -> Bool {
        var failures = [String]()
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }

        let gb: Int64 = 1_000_000_000
        let now = Date()
        func sample(_ hoursAgo: Double, usedGB: Int64) -> DiskSample {
            DiskSample(t: now.addingTimeInterval(-hoursAgo * 3600), total: 1000 * gb,
                       availImportant: (1000 - usedGB) * gb, avail: (1000 - usedGB) * gb)
        }
        let samples = [sample(119.5, usedGB: 200), sample(72, usedGB: 150), sample(0, usedGB: 450)]
        let growth = DiskGrowth.compute(samples: samples, now: now, window: .day5)
        check(growth.bytes == 300 * gb, "5-day growth is 300 GB")
        check(growth.netBytes == 250 * gb, "5-day net change is 250 GB")
        check(growth.status == .ok, "5-day window is covered")
        let verdict = DiskHealth.evaluate(samples: samples, now: now, previous: .green)
        check(verdict.level == .red, "verdict is red")

        let missing = Measured<Int64>.absent(unit: "bytes", status: .collecting)
        let encoded = (try? CoreJSON.encoder().encode(missing)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(encoded.contains("\"value\":null"), "missing value encodes as null")

        if failures.isEmpty {
            print("PASS: 5-day growth 300 GB, net change 250 GB, red verdict, null encoding of missing value")
            return true
        }
        for name in failures {
            FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
        }
        return false
    }
}
// SELFTEST-END

// MARK: - --diagnose

@MainActor
enum Diagnose {
    struct Report: Encodable {
        var mode = "headless"
        var cleaningInvoked = false
        var seconds: Double
        var dataDir: String
        var dataDirIsTemporary: Bool
        var authorization: String
        var diskLevel: HealthLevel
        var alerts: [AlertItem]
        var status: StatusFile?
        var staticPreview: String?
        var staticPreviewError: String?
        var liveProbe: LiveProbe?
        /// Real readings while the panel logic is open, after it closed, and at the end (docs/DESIGN.md 8.2).
        var diagnosticOpen: DiagnosticSnapshot?
        var diagnosticClosed: DiagnosticSnapshot?
        var diagnosticFinal: DiagnosticSnapshot?
    }

    /// Opens and closes the panel logic once to check that live sampling runs while open and stops completely after close.
    struct LiveProbe: Encodable {
        var samplingWhileOpen: Bool
        var netPointsWhileOpen: Int
        var cpuPointsWhileOpen: Int
        var lastCpuPercent: Double?
        var lastRxBytesPerSecond: Double?
        var samplingAfterClose: Bool
        var netPointsAfterClose: Int
        var cpuPointsAfterClose: Int
    }

    static func run(_ args: [String]) {
        var seconds = 22.0
        if args.contains("--seconds") {
            guard let text = MoleMonitorMain.argumentValue("--seconds", in: args),
                  let n = Double(text), n >= 5, n <= 1800 else {
                FileHandle.standardError.write(Data("--seconds needs a number from 5 to 1800.\n".utf8))
                exit(2)
            }
            seconds = n
        }

        // Without MOLEMONITOR_DATA_DIR, use a fresh temp directory so the real history stays untouched.
        let environment = ProcessInfo.processInfo.environment
        var dataDir = MoleMonitorPaths.dataDir(environment: environment)
        var temporary = false
        if (environment["MOLEMONITOR_DATA_DIR"] ?? "").isEmpty {
            dataDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoleMonitor-diagnose-\(UUID().uuidString)", isDirectory: true)
            temporary = true
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }

        let engine = MonitorEngine(dataDir: dataDir)
        engine.start()
        // A far-future timer keeps the main run loop alive when the engine adds no run loop source.
        let keepAlive = Timer(timeInterval: 86400, repeats: false) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        // Live probe: 3 s idle, 7 s with the panel logic open, 2 s after close; the rest of the time is idle.
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        wait(3)
        engine.panelOpened()
        wait(7)
        let openSampling = engine.isLiveSampling
        let during = engine.live
        let snapshotOpen = engine.diagnosticSnapshot()
        engine.panelClosed()
        wait(2)
        let snapshotClosed = engine.diagnosticSnapshot()
        let probe = LiveProbe(samplingWhileOpen: openSampling, netPointsWhileOpen: during.net.count,
                              cpuPointsWhileOpen: during.cpu.count, lastCpuPercent: during.cpuPercent,
                              lastRxBytesPerSecond: during.rx, samplingAfterClose: engine.isLiveSampling,
                              netPointsAfterClose: engine.live.net.count, cpuPointsAfterClose: engine.live.cpu.count)
        wait(max(0, seconds - 12))
        let snapshotFinal = engine.diagnosticSnapshot()
        keepAlive.invalidate()
        engine.stop()

        var report = Report(seconds: seconds, dataDir: dataDir.path, dataDirIsTemporary: temporary,
                            authorization: engine.authorization, diskLevel: engine.diskLevel,
                            alerts: engine.alerts, status: engine.status)
        report.liveProbe = probe
        report.diagnosticOpen = snapshotOpen
        report.diagnosticClosed = snapshotClosed
        report.diagnosticFinal = snapshotFinal
        if args.contains("--preview") {
            if let path = MoleMonitorMain.argumentValue("--preview", in: args) {
                if let error = PanelPreview.render(to: URL(fileURLWithPath: path)) {
                    report.staticPreviewError = error
                } else {
                    report.staticPreview = path
                }
            } else {
                report.staticPreviewError = "--preview needs an absolute output path."
            }
        }

        let encoder = CoreJSON.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        if let data = try? encoder.encode(report) {
            print(String(decoding: data, as: UTF8.self))
        }
        if report.status == nil { exit(2) }
    }
}
