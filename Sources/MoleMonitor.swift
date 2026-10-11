// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Command line arguments and MonitorEngine state (status.json data in the data directory).
// Output: Menu bar app, or --self-test, --diagnose (headless) and --preview (static PNG) modes.
// Pos: Entry point and app lifecycle; no cleanup or privileged commands, no Go collector.
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
    private let iconCache = StatusIconCache()
    let popover = NSPopover()
    private(set) var statusItem: NSStatusItem?
#if UITEST
    /// Test only: anchor for the popover when the environment gives the status item no button.
    var testAnchor: NSView?
#endif
    private var cancellables = Set<AnyCancellable>()
    private var lastIconState: IconState?

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

        applyIcon(status: engine.status, level: engine.diskLevel)
        // The sink receives the new values. Do not re-read the engine here: @Published fires before it stores.
        Publishers.CombineLatest(engine.$status, engine.$diskLevel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, level in
                self?.applyIcon(status: status, level: level)
            }
            .store(in: &cancellables)

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

    private func applyIcon(status: StatusFile?, level: HealthLevel) {
        let state = IconState(badge: StatusIcon.badge(for: level),
                              description: IconText.description(status: status, level: level))
        guard state != lastIconState, let button = statusItem?.button else { return }
        // Assign the image only when the badge changes; the text may change more often.
        if lastIconState?.badge != state.badge || button.image == nil {
            button.image = iconCache.image(for: state.badge)
        }
        button.toolTip = state.description
        button.setAccessibilityLabel(state.description)
        lastIconState = state
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    func showPanel() {
#if UITEST
        let anchor = statusItem?.button ?? testAnchor
#else
        let anchor = statusItem?.button
#endif
        guard !popover.isShown, let button = anchor else { return }
        let host = NSHostingController(rootView: PanelContainer(engine: engine, onQuit: {
            NSApplication.shared.terminate(nil)
        }))
        // UNVERIFIED-ON-MAC: sizingOptions (macOS 13+) lets the popover follow the SwiftUI height.
        // Alternative: delete this line and rely on the fittingSize assignment below.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        engine.panelOpened()
        // UNVERIFIED-ON-MAC: a .transient popover of an .accessory app should close on outside clicks without app activation.
        // Alternative: call NSApplication.shared.activate(ignoringOtherApps: true) before show.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the hosting controller and the SwiftUI tree; nothing renders while the card is closed.
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
        if args.contains("--preview") {
            guard let path = argumentValue("--preview", in: args) else {
                FileHandle.standardError.write(Data("--preview needs an absolute output path.\n".utf8))
                exit(2)
            }
            if let error = PreviewRenderer.render(to: URL(fileURLWithPath: path)) {
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

// MARK: - --preview

@MainActor
enum PreviewRenderer {
    /// Renders the status card with invented sample data for green, yellow and red, each in light and dark.
    /// `output` is the base path: `preview.png` gives `preview-red-light.png`, `preview-red-dark.png`, and so on.
    /// Returns an error text, or nil on success.
    static func render(to output: URL) -> String? {
        let base = output.deletingPathExtension()
        let ext = output.pathExtension.isEmpty ? "png" : output.pathExtension
        let now = Date()
        for level in PreviewLevel.allCases {
            for dark in [false, true] {
                // Explicit colors: windowBackgroundColor would follow the process appearance, not the rendered scheme.
                let background = dark ? Color(white: 0.17) : Color(white: 0.95)
                let scheme: ColorScheme = dark ? .dark : .light
                let content = PanelSample.panel(level: level, now: now)
                    .background(background)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    return "Preview rendering is not available."
                }
                let name = base.lastPathComponent + "-\(level.rawValue)-\(dark ? "dark" : "light")"
                let target = base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext)
                do {
                    try png.write(to: target, options: .atomic)
                } catch {
                    return "Cannot write the preview file."
                }
            }
        }
        return nil
    }
}

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
        engine.panelClosed()
        wait(2)
        let probe = LiveProbe(samplingWhileOpen: openSampling, netPointsWhileOpen: during.net.count,
                              cpuPointsWhileOpen: during.cpu.count, lastCpuPercent: during.cpuPercent,
                              lastRxBytesPerSecond: during.rx, samplingAfterClose: engine.isLiveSampling,
                              netPointsAfterClose: engine.live.net.count, cpuPointsAfterClose: engine.live.cpu.count)
        wait(max(0, seconds - 12))
        keepAlive.invalidate()
        engine.stop()

        var report = Report(seconds: seconds, dataDir: dataDir.path, dataDirIsTemporary: temporary,
                            authorization: engine.authorization, diskLevel: engine.diskLevel,
                            alerts: engine.alerts, status: engine.status)
        report.liveProbe = probe
        if args.contains("--preview") {
            if let path = MoleMonitorMain.argumentValue("--preview", in: args) {
                if let error = PreviewRenderer.render(to: URL(fileURLWithPath: path)) {
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
