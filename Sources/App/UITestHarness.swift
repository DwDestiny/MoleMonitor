// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: `--ui-test --ui-test-out <dir>` and MOLEMONITOR_DATA_DIR; the real AppDelegate, NSStatusItem, NSPopover and MonitorEngine.
// Output: A JSON report (stdout and <dir>/ui-report.json) and frame PNG files; the process quits through the Quit button.
// Pos: UI regression gate for interaction and motion. The whole file exists only in the -D UITEST build (scripts/build.py --ui-test); the release binary has none of it.
//      It proves the main thread has no long block and that the panel reacts. It does not measure GPU frame rate on real hardware.

#if UITEST
import AppKit
import SwiftUI
import QuartzCore
import Darwin

// MARK: - Report types

struct UITestItem: Encodable {
    var id: String
    var name: String
    /// "pass" | "fail" | "skipped" | "pending" (pending: the acceptance script decides after the process exit)
    var status: String
    var ms: Double
    var note: String
    var values: [String: Double]
}

struct UITestStats: Encodable {
    var count: Int
    var p50: Double
    var p95: Double
    var max: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        func at(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[index]
        }
        p50 = at(0.5)
        p95 = at(0.95)
        max = sorted.last ?? 0
    }
}

struct UITestReport: Encodable {
    var schema = 1
    var items: [UITestItem]
    var mainThreadIntervalsMs: UITestStats?
    var renderMs: UITestStats?
    var frames: [String]
    var info: [String: String]
    var statusMtimeBeforeQuit: Double?
}

// MARK: - Frame registry (filled by `uiTestFrame` in Panel.swift)

final class UITestFrameStore: @unchecked Sendable {
    static let shared = UITestFrameStore()
    private let lock = NSLock()
    private var frames = [String: CGRect]()

    func set(_ id: String, _ rect: CGRect) {
        lock.lock()
        frames[id] = rect
        lock.unlock()
    }

    func get(_ id: String) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return frames[id]
    }

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return frames.keys.sorted()
    }
}

final class UITestTimeBox: @unchecked Sendable {
    var value: Double?
}

// MARK: - Main thread probe

/// A 120 Hz timer on the main queue. A long block of the main thread shows up as a long gap between two calls.
final class UITestMainThreadProbe {
    private var timer: DispatchSourceTimer?
    private var last = 0.0
    private(set) var intervalsMs = [Double]()

    func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.intervalsMs.append((now - self.last) * 1000)
            self.last = now
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Pixels

struct UITestShot {
    var cg: CGImage
    var rgba: [UInt8]
    var w: Int
    var h: Int
    /// Pixels per point.
    var scale: Double
}

enum UITestPixels {
    static func shot(from cg: CGImage, pointWidth: CGFloat) -> UITestShot? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return UITestShot(cg: cg, rgba: data, w: w, h: h, scale: pointWidth > 0 ? Double(w) / Double(pointWidth) : 1)
    }

    /// Region in points, top-left origin, to pixels (clamped).
    static func pixelRegion(_ r: CGRect, of s: UITestShot) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let x0 = Swift.max(0, Int((Double(r.minX) * s.scale).rounded(.down)))
        let y0 = Swift.max(0, Int((Double(r.minY) * s.scale).rounded(.down)))
        let x1 = Swift.min(s.w, Int((Double(r.maxX) * s.scale).rounded(.up)))
        let y1 = Swift.min(s.h, Int((Double(r.maxY) * s.scale).rounded(.up)))
        return (x0, y0, Swift.max(x0, x1), Swift.max(y0, y1))
    }

    /// Mean of the per-pixel largest channel difference (0...255) and the share of pixels above `threshold`.
    static func compare(_ a: UITestShot, _ b: UITestShot, region: CGRect? = nil, threshold: Int = 16) -> (mean: Double, fraction: Double) {
        guard a.w == b.w, a.h == b.h else { return (255, 1) }
        var box = (x0: 0, y0: 0, x1: a.w, y1: a.h)
        if let region { box = pixelRegion(region, of: a) }
        var sum = 0.0
        var above = 0
        var count = 0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * a.w + x) * 4
                var m = 0
                for c in 0..<4 {
                    let d = abs(Int(a.rgba[i + c]) - Int(b.rgba[i + c]))
                    if d > m { m = d }
                }
                sum += Double(m)
                if m > threshold { above += 1 }
                count += 1
            }
        }
        guard count > 0 else { return (0, 0) }
        return (sum / Double(count), Double(above) / Double(count))
    }

    /// Share of pixels with any alpha, and the number of distinct coarse colors among them.
    static func content(_ s: UITestShot) -> (coverage: Double, colors: Int) {
        var covered = 0
        var seen = Set<UInt32>()
        var i = 0
        while i < s.rgba.count {
            if s.rgba[i + 3] > 0 {
                covered += 1
                if seen.count < 4096 {
                    let key = (UInt32(s.rgba[i] >> 3) << 16) | (UInt32(s.rgba[i + 1] >> 3) << 8) | UInt32(s.rgba[i + 2] >> 3)
                    seen.insert(key)
                }
            }
            i += 4
        }
        return (Double(covered) / Double(Swift.max(1, s.w * s.h)), seen.count)
    }

    /// The same pixels over an opaque background, so a PNG is readable in any viewer.
    static func png(_ s: UITestShot, dark: Bool) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: s.w, height: s.h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: dark ? 0.17 : 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s.w, height: s.h))
        ctx.draw(s.cg, in: CGRect(x: 0, y: 0, width: s.w, height: s.h))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: - Accessibility tree

struct UITestAXNode {
    var id: String
    var role: String
    var label: String
    var value: String
    /// Screen coordinates, bottom-left origin.
    var frame: NSRect
}

enum UITestAX {
    static func nodes(root: NSView) -> [UITestAXNode] {
        var out = [UITestAXNode]()
        var budget = 800
        // Key-value coding on the accessibility getters: the Swift spelling of these members differs between the protocol and NSView.
        func read(_ object: NSObject, _ key: String) -> Any? {
            guard object.responds(to: Selector(key)) else { return nil }
            return object.value(forKey: key)
        }
        func walk(_ object: Any, depth: Int) {
            guard depth < 16, budget > 0, let e = object as? NSObject else { return }
            budget -= 1
            let role = (read(e, "accessibilityRole") as? String) ?? ""
            let frame = (read(e, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            out.append(UITestAXNode(id: (read(e, "accessibilityIdentifier") as? String) ?? "", role: role,
                                    label: (read(e, "accessibilityLabel") as? String) ?? "",
                                    value: read(e, "accessibilityValue").map { "\($0)" } ?? "",
                                    frame: frame))
            for child in (read(e, "accessibilityChildren") as? [Any]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }

    static func hasChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

// MARK: - Entry

@MainActor
enum UITestHarness {
    static func run(_ args: [String]) -> Never {
        func fatal(_ message: String) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
        guard let out = MoleMonitorMain.argumentValue("--ui-test-out", in: args) else { fatal("--ui-test needs --ui-test-out <directory>.") }
        guard let dir = ProcessInfo.processInfo.environment["MOLEMONITOR_DATA_DIR"], !dir.isEmpty else {
            fatal("--ui-test needs MOLEMONITOR_DATA_DIR (a temporary directory).")
        }
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        let dataDir = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            fatal("Cannot create the output directory.")
        }

        // Invented red scenario (30 days) written as the real NDJSON history. The engine reads it like any history.
        let seeded = PreviewScenario.samples(.red, now: Date())
        do {
            for sample in seeded { try DiskHistory.append(sample, dir: dataDir) }
        } catch {
            fatal("Cannot write the seeded history.")
        }
        guard let last = seeded.last else { fatal("No seeded history.") }
        // The runner disk is arbitrary. Each real sample keeps its network counters but takes the scenario's disk numbers.
        let total = last.total, availImportant = last.availImportant, avail = last.avail
        let rx = last.netRx ?? 0, tx = last.netTx ?? 0
        MonitorEngine.sampleTransform = { sample in
            var s = sample
            s.ok = true
            s.err = nil
            s.total = total
            s.availImportant = availImportant
            s.avail = avail
            if let total, let availImportant { s.used = total - availImportant }
            s.netRx = rx + 1_020_000_000
            s.netTx = tx + 140_000_000
            s.boot = nil
            return s
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        let runner = UITestRunner(delegate: delegate, outDir: outDir, dataDir: dataDir, seededCount: seeded.count)
        Task { @MainActor in await runner.run() }
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
}

// MARK: - Runner

@MainActor
final class UITestRunner {
    let delegate: AppDelegate
    let outDir: URL
    let dataDir: URL
    let seededCount: Int

    var items = [UITestItem]()
    var frameFiles = [String]()
    var info = [String: String]()
    var renderMs = [Double]()
    let probe = UITestMainThreadProbe()
    var statusMtimeBeforeQuit: Double?
    var anchorWindow: NSWindow?
    var axCache: [UITestAXNode]?
    var eventNumber = 1

    var engine: MonitorEngine { delegate.engine }
    var popover: NSPopover { delegate.popover }
    var hostView: NSView? { popover.contentViewController?.view }

    init(delegate: AppDelegate, outDir: URL, dataDir: URL, seededCount: Int) {
        self.delegate = delegate
        self.outDir = outDir
        self.dataDir = dataDir
        self.seededCount = seededCount
    }

    // MARK: Helpers

    func log(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func now() -> Double { CACurrentMediaTime() }

    func record(_ id: String, _ name: String, _ ok: Bool?, since t0: Double, _ note: String,
                _ values: [String: Double] = [:], pending: Bool = false) {
        let status = pending ? "pending" : (ok == nil ? "skipped" : (ok == true ? "pass" : "fail"))
        let ms = (now() - t0) * 1000
        items.append(UITestItem(id: id, name: name, status: status, ms: (ms * 10).rounded() / 10, note: note, values: values))
        log("[\(status.uppercased())] \(id) \(name) (\(Int(ms)) ms) \(note)")
    }

    func sleepMs(_ ms: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(Swift.max(0, ms) * 1_000_000))
    }

    func sleepUntil(_ t: Double) async {
        let delta = t - now()
        if delta > 0.001 { try? await Task.sleep(nanoseconds: UInt64(delta * 1_000_000_000)) }
    }

    /// Polls every 10 ms. Returns the elapsed time in ms when the condition became true, or nil on timeout.
    func waitFor(timeoutMs: Double, _ condition: () -> Bool) async -> Double? {
        let t0 = now()
        while true {
            if condition() { return (now() - t0) * 1000 }
            if (now() - t0) * 1000 >= timeoutMs { return nil }
            await sleepMs(10)
        }
    }

    func capture(_ view: NSView) -> UITestShot? {
        let t = now()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = rep.cgImage.flatMap { UITestPixels.shot(from: $0, pointWidth: view.bounds.width) }
        renderMs.append((now() - t) * 1000)
        return image
    }

    /// Second capture path: render the presentation layer, which includes running Core Animation values.
    func capturePresentation(_ view: NSView) -> UITestShot? {
        guard let layer = view.layer, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = view.window?.backingScaleFactor ?? 1
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        (layer.presentation() ?? layer).render(in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return UITestPixels.shot(from: image, pointWidth: view.bounds.width)
    }

    func save(_ shot: UITestShot, _ name: String, dark: Bool = false) {
        guard let data = UITestPixels.png(shot, dark: dark) else { return }
        do {
            try data.write(to: outDir.appendingPathComponent(name))
            frameFiles.append(name)
        } catch {
            log("Cannot write \(name).")
        }
    }

    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    func footprintMB() -> Double? {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(vm.phys_footprint) / 1_048_576 : nil
    }

    // MARK: Geometry

    struct Located {
        var rect: CGRect  // hosting view points, top-left origin
        var source: String
    }

    func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        if i.isNull || i.isEmpty { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    func viewRect(fromScreen r: NSRect, in hv: NSView, window: NSWindow) -> CGRect {
        let inWindow = window.convertFromScreen(r)
        let inView = hv.convert(inWindow, from: nil)
        let y = hv.isFlipped ? inView.minY : hv.bounds.height - inView.maxY
        return CGRect(x: inView.minX, y: y, width: inView.width, height: inView.height)
    }

    func windowPoint(_ p: CGPoint, in hv: NSView) -> NSPoint {
        let y = hv.isFlipped ? p.y : hv.bounds.height - p.y
        return hv.convert(NSPoint(x: p.x, y: y), to: nil)
    }

    func axNodes() -> [UITestAXNode] {
        if let axCache { return axCache }
        guard let hv = hostView else { return [] }
        let nodes = UITestAX.nodes(root: hv)
        axCache = nodes
        return nodes
    }

    /// Accessibility tree first; the layout registry when the tree has no such element or disagrees.
    func locate(_ id: String) -> Located? {
        guard let hv = hostView, let window = hv.window else { return nil }
        let registry = UITestFrameStore.shared.get(id)
        var ax: CGRect?
        if let node = axNodes().first(where: { $0.id == id }), node.frame.width > 0 {
            ax = viewRect(fromScreen: node.frame, in: hv, window: window)
        }
        switch (ax, registry) {
        case let (a?, r?):
            if iou(a, r) >= 0.5 { return Located(rect: a, source: "accessibility tree") }
            return Located(rect: r, source: "layout registry (accessibility frame disagrees)")
        case let (a?, nil):
            return Located(rect: a, source: "accessibility tree")
        case let (nil, r?):
            return Located(rect: r, source: "layout registry")
        default:
            return nil
        }
    }

    // MARK: Events

    func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(),
                           clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allSubviews($0) }
    }

    enum HoverMethod: String, CaseIterable {
        case windowSendEvent = "window.sendEvent(mouseMoved)"
        case trackingOwners = "tracking area owners"
        case cgEvent = "CGEvent mouseMoved"
    }

    /// Moves the pointer to a hosting-view point by the given method.
    func hover(to point: CGPoint, method: HoverMethod) {
        guard let hv = hostView, let window = hv.window else { return }
        let p = windowPoint(point, in: hv)
        switch method {
        case .windowSendEvent:
            window.acceptsMouseMovedEvents = true
            if let e = mouse(.mouseMoved, at: p, window: window) { window.sendEvent(e) }
        case .trackingOwners:
            let moved = mouse(.mouseMoved, at: p, window: window)
            let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: nextEventNumber(), trackingNumber: 0, userData: nil)
            for view in allSubviews(hv) {
                let local = view.convert(p, from: nil)
                for area in view.trackingAreas {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    guard rect.contains(local), let owner = area.owner as? NSObject else { continue }
                    if let entered, owner.responds(to: Selector(("mouseEntered:"))) {
                        _ = owner.perform(Selector(("mouseEntered:")), with: entered)
                    }
                    if let moved, owner.responds(to: Selector(("mouseMoved:"))) {
                        _ = owner.perform(Selector(("mouseMoved:")), with: moved)
                    }
                }
                if let entered { _ = view.perform(Selector(("mouseEntered:")), with: entered) }
                if let moved { _ = view.perform(Selector(("mouseMoved:")), with: moved) }
            }
        case .cgEvent:
            let screenPoint = window.convertPoint(toScreen: p)
            guard let height = NSScreen.screens.first?.frame.height else { return }
            let cg = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
            CGWarpMouseCursorPosition(cg)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Mouse down, a short hold, mouse up at a hosting-view point.
    func click(at point: CGPoint) async -> Bool {
        guard let hv = hostView, let window = hv.window else { return false }
        let p = windowPoint(point, in: hv)
        guard let down = mouse(.leftMouseDown, at: p, window: window), let up = mouse(.leftMouseUp, at: p, window: window) else { return false }
        window.sendEvent(down)
        await sleepMs(80)
        window.sendEvent(up)
        return true
    }

    // MARK: Open and close

    struct OpenResult {
        var clickMs: Double
        var showAtMs: Double
        var liveSeenMs: Double?
        var shots: [(offset: Double, shot: UITestShot)]
        var presentation: [(offset: Double, shot: UITestShot)]
        var timersWhileOpen: Int
        var refTime: Double
    }

    /// Opens the panel by a click on the status item button (or the fallback anchor) and captures frames at the given offsets.
    func openPanel(offsets: [Double], useStatusButton: Bool, prefix: String) async -> OpenResult? {
        axCache = nil
        UITestFrameStore.shared.reset()
        let box = UITestTimeBox()
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: popover, queue: nil) { _ in
            box.value = CACurrentMediaTime()
        }
        let before = now()
        if useStatusButton, let button = delegate.statusItem?.button {
            button.performClick(nil)
        } else {
            delegate.showPanel()
        }
        let after = now()
        NotificationCenter.default.removeObserver(observer)
        _ = await waitFor(timeoutMs: 500) { self.popover.isShown }
        guard popover.isShown, let hv = hostView else { return nil }
        let ref = box.value ?? before
        var live: Double?
        var shots = [(offset: Double, shot: UITestShot)]()
        var presentation = [(offset: Double, shot: UITestShot)]()
        for offset in offsets {
            await sleepUntil(ref + offset / 1000)
            if live == nil, engine.isLiveSampling { live = (now() - ref) * 1000 }
            let at = (now() - ref) * 1000
            if let s = capture(hv) { shots.append((at, s)) }
            if let p = capturePresentation(hv) { presentation.append((at, p)) }
        }
        if live == nil {
            let spent = (now() - ref) * 1000
            if let waited = await waitFor(timeoutMs: Swift.max(0, 1500 - spent), { engine.isLiveSampling }) { live = spent + waited }
        }
        for (i, entry) in shots.enumerated() {
            save(entry.shot, "ui-\(prefix)-\(i)-t\(Int(entry.offset.rounded())).png")
        }
        return OpenResult(clickMs: (after - before) * 1000, showAtMs: (ref - before) * 1000, liveSeenMs: live,
                          shots: shots, presentation: presentation, timersWhileOpen: engine.activeTimerCount, refTime: ref)
    }

    func sendEscape() {
        guard let window = hostView?.window else { return }
        func key(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                             charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)
        }
        if let down = key(.keyDown) { window.sendEvent(down) }
        if let up = key(.keyUp) { window.sendEvent(up) }
    }

    // MARK: Sequence

    func run() async {
        let tStart = now()
        info["footprintStartMB"] = footprintMB().map { String(format: "%.1f", $0) } ?? "n/a"
        info["seededSamples"] = String(seededCount)
        info["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        info["screens"] = String(NSScreen.screens.count)

        let hasButton = await stepA()
        probe.start()
        guard let first = await stepB(useStatusButton: hasButton) else {
            finish(abort: "The panel did not open; the remaining steps cannot run.")
            return
        }
        stepC(first)
        await stepD(ref: first)
        await stepF()
        await stepG()
        await stepH()
        probe.stop()
        await stepL()
        probe.start()
        await stepIJ(first: first, useStatusButton: hasButton)
        probe.stop()
        stepE()
        info["totalSeconds"] = String(format: "%.1f", now() - tStart)
        await stepK()
    }

    // A: status item and icon
    func stepA() async -> Bool {
        let t0 = now()
        _ = await waitFor(timeoutMs: 5000) { self.delegate.statusItem?.button != nil }
        guard let button = delegate.statusItem?.button, button.window != nil else {
            record("A", "状态栏与图标", nil, since: t0, "NSStatusItem has no button with a window in this environment; the popover is anchored to a test window instead.")
            let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 120, height: 24), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            window.contentView = anchor
            window.orderFrontRegardless()
            anchorWindow = window
            delegate.testAnchor = anchor
            return false
        }
        _ = await waitFor(timeoutMs: 8000) { self.engine.diskLevel == .red && button.image != nil }
        let label = button.accessibilityLabel() ?? ""
        let hasImage = button.image != nil
        let templateFlag = button.image?.isTemplate
        let ok = hasImage && label.contains("磁盘") && engine.diskLevel == .red && templateFlag == false
        record("A", "状态栏与图标", ok, since: t0,
               "image=\(hasImage) isTemplate=\(templateFlag.map { "\($0)" } ?? "nil") level=\(engine.diskLevel) label=\(label)",
               ["buttonHasWindow": button.window != nil ? 1 : 0])
        return true
    }

    // B: open
    func stepB(useStatusButton: Bool) async -> OpenResult? {
        let t0 = now()
        guard let result = await openPanel(offsets: [0, 60, 120, 200, 300, 450], useStatusButton: useStatusButton, prefix: "open1") else {
            record("B", "打开", false, since: t0, "popover.isShown is false after the click.")
            return nil
        }
        let visible = hostView?.window?.isVisible == true
        let liveOk = (result.liveSeenMs ?? .infinity) <= 1500
        let ok = popover.isShown && visible && liveOk && result.timersWhileOpen == 2
        record("B", "打开", ok, since: t0,
               "isShown=\(popover.isShown) windowVisible=\(visible) liveSampling=\(result.liveSeenMs.map { String(format: "%.0f ms", $0) } ?? "never") timers=\(result.timersWhileOpen) via \(useStatusButton ? "performClick" : "test anchor")",
               ["performClickMs": result.clickMs, "willShowAfterMs": result.showAtMs, "liveSeenMs": result.liveSeenMs ?? -1,
                "timersWhileOpen": Double(result.timersWhileOpen)])
        return result
    }

    // C: entrance animation advances
    func stepC(_ open: OpenResult) {
        let t0 = now()
        func analyse(_ shots: [(offset: Double, shot: UITestShot)]) -> (moving: Int, settled: Bool, total: Double, fractions: [Double]) {
            guard shots.count >= 6 else { return (0, false, 0, []) }
            var fractions = [Double]()
            for i in 0..<(shots.count - 1) {
                fractions.append(UITestPixels.compare(shots[i].shot, shots[i + 1].shot).fraction)
            }
            let moving = fractions.prefix(4).filter { $0 > 0.005 }.count
            let settled = fractions[4] < 0.001
            let total = UITestPixels.compare(shots[0].shot, shots[5].shot).fraction
            return (moving, settled, total, fractions)
        }
        let primary = analyse(open.shots)
        let alt = analyse(open.presentation)
        let primaryOk = primary.moving >= 2 && primary.settled && primary.total > 0.01
        let altOk = alt.moving >= 2 && alt.settled && alt.total > 0.01
        let offsets = open.shots.map { Int($0.offset.rounded()) }
        var values: [String: Double] = ["movingTransitions": Double(primary.moving), "firstToLast": primary.total,
                                        "altMovingTransitions": Double(alt.moving), "altFirstToLast": alt.total]
        for (i, f) in primary.fractions.enumerated() { values["changedFraction_\(i)_\(i + 1)"] = f }
        let how = primaryOk ? "cacheDisplay" : (altOk ? "presentation layer" : "none")
        record("C", "入场动画在推进", primaryOk || altOk, since: t0,
               "frames at \(offsets) ms; changed-pixel share per step \(primary.fractions.map { String(format: "%.3f", $0) }); motion seen by \(how)",
               values)
        // Keep the frame times for the report.
        info["entranceFrameOffsetsMs"] = offsets.map(String.init).joined(separator: ",")
    }

    // D: live charts scroll
    func stepD(ref: OpenResult) async {
        let t0 = now()
        guard let hv = hostView else { record("D", "实时折线在滚动", false, since: t0, "no hosting view"); return }
        // The open frames ended near 450 ms; wait until 2.5 s after the open, then one frame every 2 s.
        let startRef = ref.refTime
        var shots = [UITestShot]()
        var cpuCounts = [Int](), netCounts = [Int]()
        for i in 0..<4 {
            await sleepUntil(startRef + 2.5 + 2.0 * Double(i))
            cpuCounts.append(engine.live.cpu.count)
            netCounts.append(engine.live.net.count)
            if let s = capture(hv) {
                shots.append(s)
                save(s, "ui-live-\(i + 1).png")
            }
        }
        // A timer jitter can put two captures between the same pair of ticks, so equal neighbours are allowed.
        let cpuMono = zip(cpuCounts, cpuCounts.dropFirst()).allSatisfy { $0 <= $1 } && (cpuCounts.first ?? 0) < (cpuCounts.last ?? 0)
        let netMono = zip(netCounts, netCounts.dropFirst()).allSatisfy { $0 <= $1 }

        let netUsable = (netCounts.last ?? 0) >= 3
        var regionNotes = [String]()
        var allMove = shots.count == 4
        var values: [String: Double] = ["cpuPointsLast": Double(cpuCounts.last ?? 0), "netPointsLast": Double(netCounts.last ?? 0)]
        func movement(_ id: String, required: Bool) {
            guard shots.count == 4 else { return }
            guard let loc = locate(id) else {
                regionNotes.append("\(id): no frame")
                if required { allMove = false }
                return
            }
            let fractions = (0..<3).map { UITestPixels.compare(shots[$0], shots[$0 + 1], region: loc.rect, threshold: 12).fraction }
            let moved = fractions.allSatisfy { $0 > 0.001 }
            regionNotes.append("\(id) changed share \(fractions.map { String(format: "%.3f", $0) }) via \(loc.source)")
            for (i, f) in fractions.enumerated() { values["\(id)_changed_\(i)"] = f }
            if required && !moved { allMove = false }
            if !required && netUsable && !moved { allMove = false }
        }
        movement("chart.cpu", required: true)
        movement("chart.net", required: false)
        let ok = cpuMono && (netMono) && (cpuCounts.last ?? 0) >= 3 && allMove
        record("D", "实时折线在滚动", ok, since: t0,
               "cpu points \(cpuCounts) net points \(netCounts); \(regionNotes.joined(separator: "; ")); net chart judged only when it has at least 3 points (\(netUsable))",
               values)
    }

    // F: hover
    func stepF() async {
        let t0 = now()
        guard let hv = hostView, let loc = locate("chart.disk") else {
            record("F", "悬停交互", nil, since: t0, "The frame of chart.disk is not available from the accessibility tree or the layout registry.")
            return
        }
        let r = loc.rect
        let target = CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.5)
        let away = CGPoint(x: 6, y: 3)
        hover(to: away, method: .windowSendEvent)
        await sleepMs(200)
        guard let before = capture(hv) else { record("F", "悬停交互", false, since: t0, "cannot capture"); return }
        save(before, "ui-hover-before.png")
        var worked: HoverMethod?
        var best: (mean: Double, fraction: Double) = (0, 0)
        var tried = [String]()
        for method in HoverMethod.allCases {
            hover(to: target, method: method)
            await sleepMs(150)
            guard let after = capture(hv) else { continue }
            let d = UITestPixels.compare(before, after, region: r, threshold: 24)
            tried.append("\(method.rawValue): \(String(format: "%.4f", d.fraction))")
            if d.fraction >= best.fraction { best = d }
            if d.fraction > 0.005 {
                worked = method
                save(after, "ui-hover-after.png")
                break
            }
            hover(to: away, method: method)
            await sleepMs(120)
        }
        let located = "chart.disk located by \(loc.source) at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        if let worked {
            record("F", "悬停交互", true, since: t0, "\(located); pointer reached the chart by \(worked.rawValue); tried \(tried)",
                   ["changedShare": best.fraction, "meanAbsDiff": best.mean])
        } else {
            // A failed synthetic hover cannot tell a product defect from an event that SwiftUI ignores. Report it as skipped.
            record("F", "悬停交互", nil, since: t0, "\(located); no synthetic pointer method changed the chart; tried \(tried). Not proof of a product defect.",
                   ["changedShare": best.fraction])
        }
        hover(to: away, method: .windowSendEvent)
        await sleepMs(150)
    }

    // G: authorization row and accessibility audit
    func stepG() async {
        let t0 = now()
        let auth = engine.authorization
        let enable = locate("btn.enableNotifications")
        let note = locate("label.authorization")
        let nodes = axNodes()
        let expectedText = "此环境无法发送通知，提醒只显示在这里"
        switch auth {
        case "unavailable":
            let textNode = nodes.first { $0.id == "label.authorization" }
            let textOk = textNode.map { $0.label.contains(expectedText) || $0.value.contains(expectedText) } ?? (note != nil)
            let how = textNode == nil ? "layout registry only, the text itself is not read" : "text read from the accessibility tree"
            record("G", "按钮交互与降级文案", enable == nil && note != nil && textOk, since: t0,
                   "authorization=unavailable; enable button shown=\(enable != nil); fallback text shown=\(note != nil) (\(how))")
        case "not_determined":
            if let enable {
                let r = enable.rect
                let clicked = await click(at: CGPoint(x: r.midX, y: r.midY))
                await sleepMs(300)
                record("G", "按钮交互与降级文案", clicked && popover.isShown, since: t0,
                       "authorization=not_determined; clicked 开启通知 via \(enable.source); popover still shown=\(popover.isShown); authorization now \(engine.authorization)")
            } else {
                record("G", "按钮交互与降级文案", false, since: t0, "authorization=not_determined but the enable button has no frame.")
            }
        default:
            record("G", "按钮交互与降级文案", nil, since: t0, "authorization=\(auth): neither the enable button nor the fallback text applies.")
        }

        // Accessibility audit
        let t1 = now()
        let ids = nodes.map { $0.id }.filter { !$0.isEmpty }
        info["axNodes"] = String(nodes.count)
        info["axIdentifiers"] = ids.joined(separator: ",")
        info["registryIds"] = UITestFrameStore.shared.ids.joined(separator: ",")
        guard nodes.count > 1 else {
            record("G2", "无障碍标识与中文标签", nil, since: t1, "The accessibility tree has \(nodes.count) node(s); nothing to audit.")
            return
        }
        var problems = [String]()
        for id in ["btn.quit", "chart.disk", "chart.net", "chart.cpu", "card.disk", "card.live"] {
            guard let node = nodes.first(where: { $0.id == id }) else { problems.append("\(id): missing"); continue }
            if !UITestAX.hasChinese(node.label) { problems.append("\(id): label '\(node.label)' has no Chinese text") }
        }
        for node in nodes where node.role == NSAccessibility.Role.button.rawValue {
            if node.id.isEmpty { problems.append("button without identifier (label '\(node.label)')") }
            if !UITestAX.hasChinese(node.label) { problems.append("button \(node.id) label '\(node.label)' has no Chinese text") }
        }
        record("G2", "无障碍标识与中文标签", problems.isEmpty, since: t1,
               problems.isEmpty ? "all interactive elements have an identifier and a Chinese label (\(nodes.count) nodes)" : problems.joined(separator: "; "),
               ["nodes": Double(nodes.count), "problems": Double(problems.count)])
    }

    // H: close with Esc
    func stepH() async {
        let t0 = now()
        weak var weakController: NSViewController? = popover.contentViewController
        weak var weakView: NSView? = hostView
        let tSend = now()
        sendEscape()
        var closedMs = await waitFor(timeoutMs: 400) { !self.popover.isShown }
        let viaEscape = closedMs != nil
        var fallbackNote = ""
        if !viaEscape {
            fallbackNote = " Esc did not close the popover (window isKey=\(hostView?.window?.isKeyWindow == true)); closed by performClose instead."
            popover.performClose(nil)
            closedMs = await waitFor(timeoutMs: 1000) { !self.popover.isShown }.map { $0 + 400 }
        }
        // The other conditions have the rest of 400 ms from the key event.
        let remaining = Swift.max(0, 400 - (now() - tSend) * 1000)
        let liveOffAfter = await waitFor(timeoutMs: remaining) { !self.engine.isLiveSampling }
        let emptyAfter = await waitFor(timeoutMs: remaining) { self.engine.live == .empty }
        let controllerNil = await waitFor(timeoutMs: remaining) { self.popover.contentViewController == nil }
        let releasedAfter = await waitFor(timeoutMs: 1500) { weakController == nil && weakView == nil }
        let closedOk = viaEscape && (closedMs ?? .infinity) <= 400
        let ok = closedOk && liveOffAfter != nil && emptyAfter != nil && controllerNil != nil && releasedAfter != nil
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "no" }
        record("H", "关闭", ok, since: t0,
               "Esc closed=\(viaEscape) at \(fmt(closedMs)); live timer off=\(fmt(liveOffAfter)); live buffer empty=\(fmt(emptyAfter)); contentViewController nil=\(fmt(controllerNil)); hosting controller and view released=\(fmt(releasedAfter)).\(fallbackNote)",
               ["closedMs": closedMs ?? -1, "releasedMs": releasedAfter ?? -1])
    }

    // L: a closed panel costs nothing
    func stepL() async {
        let t0 = now()
        let cpu0 = cpuSeconds()
        let wall0 = now()
        await sleepMs(3000)
        let cpuUsed = cpuSeconds() - cpu0
        let wall = now() - wall0
        let live = engine.isLiveSampling
        let timers = engine.activeTimerCount
        let empty = engine.live == .empty
        let footprint = footprintMB()
        info["footprintClosedMB"] = footprint.map { String(format: "%.1f", $0) } ?? "n/a"
        let share = cpuUsed / Swift.max(0.001, wall)
        let ok = !live && timers == 1 && empty && share < 0.05
        record("L", "关闭面板零成本", ok, since: t0,
               "after 3 s closed: liveSampling=\(live) timers=\(timers) (only the 5 minute tick is allowed) liveEmpty=\(empty) cpu=\(String(format: "%.2f", share * 100)) % of one core footprint=\(footprint.map { String(format: "%.1f MB", $0) } ?? "n/a")",
               ["timers": Double(timers), "cpuPercentOfOneCore": share * 100, "footprintMB": footprint ?? -1])
    }

    // I: reopen, J: appearance
    func stepIJ(first: OpenResult, useStatusButton: Bool) async {
        let t0 = now()
        guard let again = await openPanel(offsets: [0, 60, 120, 200, 300, 450], useStatusButton: useStatusButton, prefix: "open2") else {
            record("I", "再次打开", false, since: t0, "popover.isShown is false after the second click.")
            record("J", "深浅色", nil, since: now(), "The panel did not reopen.")
            return
        }
        func settleOffset(_ shots: [(offset: Double, shot: UITestShot)]) -> Double? {
            guard let final = shots.last?.shot else { return nil }
            return shots.first { UITestPixels.compare($0.shot, final).fraction < 0.001 }?.offset
        }
        let firstSettle = settleOffset(first.shots)
        let secondSettle = settleOffset(again.shots)
        var settledBy120: Double = -1
        if let at120 = again.shots.first(where: { $0.offset >= 100 }), let final = again.shots.last?.shot {
            settledBy120 = UITestPixels.compare(at120.shot, final).fraction < 0.001 ? 1 : 0
        }
        let openOk = again.clickMs <= first.clickMs * 1.5 + 20
        let shorter = (secondSettle ?? .infinity) <= (firstSettle ?? .infinity)
        let liveOk = (again.liveSeenMs ?? .infinity) <= 1500
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "never" }
        record("I", "再次打开", openOk && shorter && liveOk && again.timersWhileOpen == 2, since: t0,
               "open call \(String(format: "%.1f", again.clickMs)) ms (first \(String(format: "%.1f", first.clickMs)) ms); settled at \(fmt(secondSettle)) ms (first open \(fmt(firstSettle)) ms); settled within 120 ms=\(settledBy120 == 1); liveSampling at \(fmt(again.liveSeenMs)) ms",
               ["openCallMs": again.clickMs, "firstOpenCallMs": first.clickMs, "settledMs": secondSettle ?? -1,
                "firstSettledMs": firstSettle ?? -1, "settledWithin120ms": settledBy120])

        // J: light and dark
        let t1 = now()
        guard let hv = hostView else { record("J", "深浅色", false, since: t1, "no hosting view"); return }
        NSApp.appearance = NSAppearance(named: .aqua)
        await sleepMs(500)
        let light = capture(hv)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await sleepMs(500)
        let dark = capture(hv)
        NSApp.appearance = nil
        guard let light, let dark else { record("J", "深浅色", false, since: t1, "cannot capture"); return }
        save(light, "ui-open-light.png", dark: false)
        save(dark, "ui-open-dark.png", dark: true)
        let a = UITestPixels.content(light), b = UITestPixels.content(dark)
        let d = UITestPixels.compare(light, dark, threshold: 8)
        let nonBlank = a.coverage > 0.05 && b.coverage > 0.05 && a.colors > 8 && b.colors > 8
        record("J", "深浅色", nonBlank && d.fraction > 0.01, since: t1,
               "light: coverage \(String(format: "%.2f", a.coverage)) colors \(a.colors); dark: coverage \(String(format: "%.2f", b.coverage)) colors \(b.colors); changed share \(String(format: "%.3f", d.fraction))",
               ["changedShare": d.fraction, "lightCoverage": a.coverage, "darkCoverage": b.coverage])
    }

    // E: main thread
    func stepE() {
        let t0 = now()
        // Drop the first interval of each start: it spans a harness pause, not an app block.
        let intervals = probe.intervalsMs
        let stats = UITestStats(intervals)
        let render = UITestStats(renderMs)
        let ok = stats.count > 500 && stats.max < 250 && stats.p95 < 40
        record("E", "主线程流畅度（回归门禁）", ok, since: t0,
               "timer 120 Hz, \(stats.count) intervals: p50 \(String(format: "%.1f", stats.p50)) ms p95 \(String(format: "%.1f", stats.p95)) ms max \(String(format: "%.1f", stats.max)) ms; cacheDisplay render \(render.count) frames: p50 \(String(format: "%.1f", render.p50)) ms max \(String(format: "%.1f", render.max)) ms. This shows no long main-thread block in a VM. It is not a GPU frame rate.",
               ["p50": stats.p50, "p95": stats.p95, "max": stats.max, "intervals": Double(stats.count),
                "renderP50": render.p50, "renderP95": render.p95, "renderMax": render.max])
    }

    // K: quit through the button
    func stepK() async {
        let t0 = now()
        guard hostView != nil, let loc = locate("btn.quit") else {
            record("K", "退出", false, since: t0, "btn.quit has no frame; cannot click it.")
            finish(abort: nil, exitCode: 1)
            return
        }
        let statusURL = MoleMonitorPaths.statusURL(dir: dataDir)
        if let date = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date {
            statusMtimeBeforeQuit = date.timeIntervalSince1970
        }
        record("K", "退出", nil, since: t0, "Clicking 退出 (\(loc.source)). The acceptance script checks the exit code 0 and that status.json was written at exit.", pending: true)
        info["footprintOpenMB"] = footprintMB().map { String(format: "%.1f", $0) } ?? "n/a"
        writeReport()
        let r = loc.rect
        let clicked = await click(at: CGPoint(x: r.midX, y: r.midY))
        // terminate(_:) exits the process. If we are still here after 3 s, the click did not reach the button.
        await sleepMs(3000)
        if let index = items.firstIndex(where: { $0.id == "K" }) {
            items[index].status = "fail"
            items[index].note = "The click on 退出 (sent=\(clicked)) did not end the process within 3 s."
        }
        log("[FAIL] K the process is still running after the click.")
        finish(abort: nil, exitCode: 1)
    }

    // MARK: Output

    func writeReport() {
        let report = UITestReport(items: items,
                                  mainThreadIntervalsMs: probe.intervalsMs.isEmpty ? nil : UITestStats(probe.intervalsMs),
                                  renderMs: renderMs.isEmpty ? nil : UITestStats(renderMs),
                                  frames: frameFiles, info: info, statusMtimeBeforeQuit: statusMtimeBeforeQuit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: outDir.appendingPathComponent("ui-report.json"))
        log("UITEST-REPORT-BEGIN")
        log(String(decoding: data, as: UTF8.self))
        log("UITEST-REPORT-END")
    }

    func finish(abort: String?, exitCode: Int32 = 1) {
        if let abort { log(abort) }
        probe.stop()
        writeReport()
        exit(exitCode)
    }
}
#endif
