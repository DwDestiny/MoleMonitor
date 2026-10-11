// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Command line arguments and MonitorEngine state (status.json data in the data directory).
// Output: Menu bar app, or --self-test, --diagnose (headless), --preview (28 static PNG files) and --dog-gallery (PNG gallery) modes.
// Pos: Entry point and app lifecycle; no cleanup or privileged commands, no Go collector.
//      The menu bar icon is `StatusIconController` (I2) driven by `MenuIconModel`; the status item has no title text.
//      The status card is hosted here: PanelModel + PanelRoot in an NSPopover. AppKit sets the popover height (three tiers).
import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let firstPanelShownKey = "MoleMonitor.firstPanelShown"

    // Internal (not private) so the UI regression harness can drive the real objects; no behavior change.
    let engine = MonitorEngine()
    let popover = NSPopover()
    private(set) var statusItem: NSStatusItem?
#if UITEST
    /// Test only: anchor for the popover when the environment gives the status item no button.
    var testAnchor: NSView?
#endif
    private var cancellables = Set<AnyCancellable>()
    /// The last icon state given to the controller (posture and badge). The UI regression reads it.
    private(set) var menuIconState: MenuIconState?
    private lazy var iconController = StatusIconController(statusItem: statusItem)
    /// Model of the open status card. Created on open, released on close.
    private(set) var panelModel: PanelModel?
    private var planObserver: AnyCancellable?
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
        popover.behavior = .transient
        popover.delegate = self

        // Hollow icon until the first evaluation.
        applyMenuIcon(verdicts: [], dataState: .collecting)
        // The menu bar icon follows the verdicts and the data state of the engine. The sink receives the new values.
        Publishers.CombineLatest(engine.$verdicts, engine.$dataState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] verdicts, dataState in
                self?.applyMenuIcon(verdicts: verdicts, dataState: dataState)
            }
            .store(in: &cancellables)
        // A tapped notification opens the card and expands the item of the notification.
        engine.openCardHandler = { [weak self] item in self?.openPanel(expanding: item) }

        engine.start()

        if showFirstPanel {
            // Wait a moment so the status item has a window to anchor the popover.
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
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    /// Opens the card, or keeps it open, and expands one problem item. Called when the user taps a notification.
    func openPanel(expanding item: HealthItem?) {
        if !popover.isShown { showPanel() }
        panelModel?.expand(item)
    }

    func showPanel() {
#if UITEST
        let anchor = statusItem?.button ?? testAnchor
#else
        let anchor = statusItem?.button
#endif
        guard !popover.isShown, let button = anchor else { return }
        let model = makePanelModel(for: button)
        panelModel = model
        let host = NSHostingController(rootView: PanelRoot(model: model, entrance: PanelEntranceGate.next()))
        // SwiftUI never sizes the popover. AppKit sets the height from the layout plan (three tiers).
        host.sizingOptions = []
        popover.animates = true
        popover.contentViewController = host
        popover.contentSize = NSSize(width: PanelMetrics.width, height: model.layoutPlan.height)
        planObserver = model.$layoutPlan
            .map { $0.height }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] height in
                self?.popover.contentSize = NSSize(width: PanelMetrics.width, height: height)
            }
        engine.panelOpened()
        // UNVERIFIED-ON-MAC: a .transient popover of an .accessory app should close on outside clicks without app activation.
        // Alternative: call NSApplication.shared.activate(ignoringOtherApps: true) before show.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // No button takes the first-responder role, so no focus ring shows around the quit button (docs/DESIGN.md 2.10).
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
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

    func popoverDidClose(_ notification: Notification) {
        // Release the hosting controller and the SwiftUI tree; nothing renders while the card is closed.
        planObserver = nil
        panelModel?.detach()
        panelModel = nil
        popover.contentViewController = nil
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
        if args.contains("--dog-gallery") { DogGallery.run(args) }
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
