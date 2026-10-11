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
import ApplicationServices

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
/// Time the harness itself keeps the main thread busy (rendering captures, writing PNG files) is recorded as a busy window,
/// so the statistics can leave it out.
final class UITestMainThreadProbe {
    private var timer: DispatchSourceTimer?
    /// Fire times, one list per start/stop pair, so a pause never counts as a gap.
    private(set) var segments = [[Double]]()
    var busyWindows = [(start: Double, end: Double)]()

    func start() {
        guard timer == nil else { return }
        segments.append([CACurrentMediaTime()])
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in
            guard let self, !self.segments.isEmpty else { return }
            self.segments[self.segments.count - 1].append(CACurrentMediaTime())
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// All gaps in ms, and the gaps that do not overlap a harness busy window.
    func gaps() -> (all: [Double], app: [Double], harness: Int) {
        var all = [Double](), app = [Double]()
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                let ms = (b - a) * 1000
                all.append(ms)
                if busyWindows.contains(where: { $0.start < b && $0.end > a }) { continue }
                app.append(ms)
            }
        }
        return (all, app, all.count - app.count)
    }

    /// Largest gap in ms inside a time range that does not overlap a busy window.
    func maxAppGap(from t0: Double, to t1: Double) -> Double {
        var best = 0.0
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) where b > t0 && a < t1 {
                if busyWindows.contains(where: { $0.start < b && $0.end > a }) { continue }
                best = Swift.max(best, (b - a) * 1000)
            }
        }
        return best
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
    static func nodes(root: NSObject) -> [UITestAXNode] {
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
    var windowCaptureMethod: String?
    var windowCaptureUnavailable = false
    var quitPressWorked = false
    var quitNeedsActivation = false

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

    /// Marks a stretch of main-thread work done by the harness itself.
    func busy<T>(_ body: () -> T) -> T {
        let start = now()
        defer { probe.busyWindows.append((start, now())) }
        return body()
    }

    func capture(_ view: NSView) -> UITestShot? {
        busy { captureUnmarked(view) }
    }

    func captureUnmarked(_ view: NSView) -> UITestShot? {
        let t = now()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = rep.cgImage.flatMap { UITestPixels.shot(from: $0, pointWidth: view.bounds.width) }
        renderMs.append((now() - t) * 1000)
        return image
    }

    typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    typealias DisplayImageFunction = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?

    /// The window as the window server composites it, so animations in flight are included. cacheDisplay draws the final
    /// state of the view tree and misses Core Animation motion. The calls are looked up at run time because the SDK marks them as replaced.
    /// The first method that returns an image is remembered; the diagnostics list what each method returned.
    func windowImage(_ window: NSWindow) -> CGImage? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        let rect = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
        let number = UInt32(window.windowNumber)
        var methods = [(name: String, run: () -> CGImage?)]()
        if let symbol = dlsym(rtldDefault, "CGWindowListCreateImage") {
            let list = unsafeBitCast(symbol, to: WindowImageFunction.self)
            methods.append(("window list, window only", { list(CGRect.null, 8, number, 1 | 16)?.takeRetainedValue() }))
            methods.append(("window list, window by frame", { list(rect, 8, number, 16)?.takeRetainedValue() }))
            methods.append(("window list, screen region", { list(rect, 1, 0, 16)?.takeRetainedValue() }))
        }
        if let symbol = dlsym(rtldDefault, "CGDisplayCreateImageForRect") {
            let display = unsafeBitCast(symbol, to: DisplayImageFunction.self)
            methods.append(("display rect", { display(CGMainDisplayID(), rect)?.takeRetainedValue() }))
        }
        if let known = windowCaptureMethod, let m = methods.first(where: { $0.name == known }) { return m.run() }
        var results = [String]()
        for m in methods {
            if let image = m.run(), image.width > 8, image.height > 8 {
                windowCaptureMethod = m.name
                info["windowCaptureMethod"] = m.name
                return image
            }
            results.append("\(m.name): none")
        }
        windowCaptureUnavailable = true
        let listed = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
            .map { "\($0[kCGWindowNumber as String] ?? "?")@\($0[kCGWindowLayer as String] ?? "?") onscreen=\($0[kCGWindowIsOnscreen as String] ?? "?")" }
        info["windowCaptureDiagnostics"] = "\(methods.count) methods \(results.joined(separator: ", ")); window number \(number); frame \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)); windows of this process \(listed.joined(separator: " | "))"
        return nil
    }

    /// A frame for the motion checks from the window server. nil when no method works; cacheDisplay shows only the end state of an animation.
    func windowFrame(_ view: NSView) -> UITestShot? {
        guard !windowCaptureUnavailable else { return nil }
        return busy { () -> UITestShot? in
            let t = now()
            guard let window = view.window, let cg = windowImage(window),
                  let shot = UITestPixels.shot(from: cg, pointWidth: window.frame.width) else { return nil }
            renderMs.append((now() - t) * 1000)
            return shot
        }
    }

    /// Sums over the presentation layers: opacity, position and the layer count. They change while an animation runs.
    func layerSignature(_ view: NSView) -> (value: Double, animated: Int, count: Int) {
        guard let root = view.window?.contentView?.superview?.layer ?? view.layer else { return (0, 0, 0) }
        var value = 0.0
        var animated = 0
        var count = 0
        func walk(_ layer: CALayer, _ depth: Int) {
            guard count < 4000, depth < 40 else { return }
            count += 1
            let p = layer.presentation() ?? layer
            value += Double(p.opacity) * 3 + Double(p.position.y) * 0.01 + Double(p.position.x) * 0.007 + Double(p.bounds.width) * 0.001
            animated += layer.animationKeys()?.count ?? 0
            for sub in layer.sublayers ?? [] { walk(sub, depth + 1) }
        }
        walk(root, 0)
        return (value, animated, count)
    }

    /// Asks the system to build the accessibility tree of this process. SwiftUI builds it only when a client is present.
    func requestAccessibilityTree() {
        let pid = getpid()
        DispatchQueue.global().async {
            let app = AXUIElementCreateApplication(pid)
            let a = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let b = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let trusted = AXIsProcessTrusted()
            FileHandle.standardOutput.write(Data("AX enable: manual=\(a.rawValue) enhanced=\(b.rawValue) trusted=\(trusted)\n".utf8))
        }
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        hostView?.window?.makeKey()
    }

    func save(_ shot: UITestShot, _ name: String, dark: Bool = false) {
        busy {
            guard let data = UITestPixels.png(shot, dark: dark) else { return }
            do {
                try data.write(to: outDir.appendingPathComponent(name))
                frameFiles.append(name)
            } catch {
                log("Cannot write \(name).")
            }
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
        return busy { () -> [UITestAXNode] in
            var best = UITestAX.nodes(root: hv)
            var source = "hosting view"
            if best.count <= 1, let window = hv.window {
                let more = UITestAX.nodes(root: window)
                if more.count > best.count { best = more; source = "popover window" }
            }
            if best.count <= 1 {
                let more = UITestAX.nodes(root: NSApp)
                if more.count > best.count { best = more; source = "application" }
            }
            info["axSource"] = source
            axCache = best
            return best
        }
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
            // The accessibility frame matched the rendered image in the review; the registry frame is offset. Trust the tree.
            return Located(rect: a, source: "accessibility tree (layout registry disagrees)")
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

    func screenPoint(forViewPoint p: CGPoint) -> CGPoint? {
        guard let hv = hostView, let window = hv.window, let height = NSScreen.screens.first?.frame.height else { return nil }
        let s = window.convertPoint(toScreen: windowPoint(p, in: hv))
        return CGPoint(x: s.x, y: height - s.y)
    }

    func cgMouse(_ type: CGEventType, at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        if type == .leftMouseDown || type == .leftMouseUp { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    enum ClickMethod: String {
        case appKitEvent = "NSEvent through window.sendEvent"
        case systemEvent = "CGEvent through the system"
    }

    func press(at point: CGPoint, method: ClickMethod) {
        switch method {
        case .appKitEvent:
            guard let hv = hostView, let window = hv.window,
                  let down = mouse(.leftMouseDown, at: windowPoint(point, in: hv), window: window) else { return }
            window.sendEvent(down)
        case .systemEvent:
            guard let cg = screenPoint(forViewPoint: point) else { return }
            CGWarpMouseCursorPosition(cg)
            cgMouse(.mouseMoved, at: cg)
            cgMouse(.leftMouseDown, at: cg)
        }
    }

    func release(at point: CGPoint, method: ClickMethod) {
        switch method {
        case .appKitEvent:
            guard let hv = hostView, let window = hv.window,
                  let up = mouse(.leftMouseUp, at: windowPoint(point, in: hv), window: window) else { return }
            window.sendEvent(up)
        case .systemEvent:
            guard let cg = screenPoint(forViewPoint: point) else { return }
            cgMouse(.leftMouseUp, at: cg)
        }
    }

    struct PressLook {
        var worked: ClickMethod?
        var activationNeeded: Bool
        var shares: [String]
        var state: String
    }

    /// Presses the element, looks for its pressed look, and releases outside it so the action does not run.
    /// Without activation first; with activation if the first round shows nothing.
    func pressLook(_ loc: Located, saveAs name: String) async -> PressLook {
        guard let hv = hostView else { return PressLook(worked: nil, activationNeeded: false, shares: [], state: "no hosting view") }
        let r = loc.rect
        let center = CGPoint(x: r.midX, y: r.midY)
        let away = CGPoint(x: 6, y: 3)
        var shares = [String]()
        var state = ""
        for activate in [false, true] {
            if activate {
                activateApp()
                await sleepMs(300)
            }
            state = "app active=\(NSApp.isActive) window key=\(hv.window?.isKeyWindow == true)"
            for method in [ClickMethod.appKitEvent, ClickMethod.systemEvent] {
                hover(to: away, method: .cgEvent)
                await sleepMs(220)
                guard let before = capture(hv) else { continue }
                press(at: center, method: method)
                await sleepMs(200)
                var worked = false
                if let during = capture(hv) {
                    let d = UITestPixels.compare(before, during, region: r, threshold: 10).fraction
                    shares.append("\(activate ? "activated" : "not activated") \(method.rawValue): \(String(format: "%.3f", d))")
                    if d > 0.02 { worked = true; save(during, name) }
                }
                if method == .systemEvent, let cg = screenPoint(forViewPoint: away) {
                    cgMouse(.leftMouseDragged, at: cg)
                }
                release(at: away, method: method)
                await sleepMs(250)
                if worked { return PressLook(worked: method, activationNeeded: activate, shares: shares, state: state) }
            }
        }
        return PressLook(worked: nil, activationNeeded: false, shares: shares, state: state)
    }

    // MARK: Open and close

    struct OpenResult {
        var clickMs: Double
        var showAtMs: Double
        var liveSeenMs: Double?
        var shots: [(offset: Double, shot: UITestShot)]
        var timersWhileOpen: Int
        var refTime: Double
        var beforeTime: Double
        var afterTime: Double
        var windowCapture: Bool
        var signatures: [(offset: Double, value: Double, animated: Int, count: Int)]
    }

    enum OpenVia: String {
        /// The real click, with the simulated highlight delay of NSButton.
        case performClick
        /// The same action message the click sends, without the highlight delay: frames can start at 0 ms.
        case sendAction
    }

    /// Opens the panel through the status item button (or the fallback anchor), captures frames at the offsets,
    /// then waits until `holdMs` after the open.
    func openPanel(offsets: [Double], via: OpenVia, holdMs: Double, prefix: String) async -> OpenResult? {
        axCache = nil
        UITestFrameStore.shared.reset()
        let box = UITestTimeBox()
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: popover, queue: nil) { _ in
            box.value = CACurrentMediaTime()
        }
        let before = now()
        if let button = delegate.statusItem?.button, button.window != nil {
            switch via {
            case .performClick:
                button.performClick(nil)
                // The highlight delay before the action is simulated by AppKit. It is not app work.
                probe.busyWindows.append((before, box.value ?? now()))
            case .sendAction:
                if let action = button.action { _ = NSApp.sendAction(action, to: button.target, from: button) }
            }
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
        var signatures = [(offset: Double, value: Double, animated: Int, count: Int)]()
        var nextShot = 0
        let sampleUntil = offsets.isEmpty ? 0 : Swift.max(offsets.last ?? 0, 600)
        // Sample the layers every few ms and take the pixel frames at the offsets. Only the layer sampling runs between frames.
        while !offsets.isEmpty {
            let at = (now() - ref) * 1000
            if live == nil, engine.isLiveSampling { live = at }
            let sig = busy { layerSignature(hv) }
            signatures.append((at, sig.value, sig.animated, sig.count))
            if nextShot < offsets.count, at >= offsets[nextShot] {
                if let frame = windowFrame(hv) { shots.append((at, frame)) }
                nextShot += 1
            }
            if at >= sampleUntil { break }
            await sleepMs(6)
        }
        let windowCapture = !windowCaptureUnavailable && shots.count == offsets.count
        if live == nil {
            let spent = (now() - ref) * 1000
            if let waited = await waitFor(timeoutMs: Swift.max(0, 1500 - spent), { engine.isLiveSampling }) { live = spent + waited }
        }
        await sleepUntil(ref + holdMs / 1000)
        for (i, entry) in shots.enumerated() {
            save(entry.shot, "ui-\(prefix)-\(i)-t\(Int(entry.offset.rounded())).png")
        }
        return OpenResult(clickMs: (after - before) * 1000, showAtMs: (ref - before) * 1000, liveSeenMs: live,
                          shots: shots, timersWhileOpen: engine.activeTimerCount, refTime: ref, beforeTime: before,
                          afterTime: after, windowCapture: windowCapture, signatures: signatures)
    }

    /// Closes through the API and waits until the popover and its content are gone. Used between steps, not as a test.
    func closePanelQuietly() async {
        popover.performClose(nil)
        _ = await waitFor(timeoutMs: 2000) { !self.popover.isShown && self.popover.contentViewController == nil }
        await sleepMs(150)
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

        requestAccessibilityTree()
        _ = await stepA()
        probe.start()
        // Open 1: the real click, no captures. It measures the natural cost of the first open.
        guard let cold = await stepB() else {
            finish(abort: "The panel did not open; the remaining steps cannot run.")
            return
        }
        // The cold first open is judged in B with its own limit. E judges the warm opens.
        probe.busyWindows.append((cold.refTime - 0.05, cold.refTime + 1.6))
        await closePanelQuietly()
        // Open 2: the full entrance again, with frame captures.
        PanelEntranceGate.resetForTest()
        guard let second = await openPanel(offsets: [0, 60, 120, 200, 300, 450, 650], via: .sendAction, holdMs: 750, prefix: "open1") else {
            record("C", "入场动画在推进", false, since: now(), "The panel did not open the second time.")
            finish(abort: "The panel did not reopen for the frame captures.")
            return
        }
        stepC(second)
        await stepD(ref: second)
        await stepF()
        await stepG()
        await stepH()
        probe.stop()
        await stepL()
        probe.start()
        await stepIJ(first: second)
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
        // The icon follows the engine one main-queue hop later, so wait for the icon itself.
        _ = await waitFor(timeoutMs: 8000) {
            self.engine.diskLevel == .red && button.image?.isTemplate == false && (button.accessibilityLabel() ?? "").contains("磁盘")
        }
        let label = button.accessibilityLabel() ?? ""
        let hasImage = button.image != nil
        let templateFlag = button.image?.isTemplate
        let ok = hasImage && label.contains("磁盘") && engine.diskLevel == .red && templateFlag == false
        record("A", "状态栏与图标", ok, since: t0,
               "image=\(hasImage) isTemplate=\(templateFlag.map { "\($0)" } ?? "nil") level=\(engine.diskLevel) label=\(label)",
               ["buttonHasWindow": button.window != nil ? 1 : 0])
        return true
    }

    // B: open with the real click
    func stepB() async -> OpenResult? {
        let t0 = now()
        guard let result = await openPanel(offsets: [], via: .performClick, holdMs: 1500, prefix: "open0") else {
            record("B", "打开", false, since: t0, "popover.isShown is false after the click.")
            return nil
        }
        if let hv = hostView, let shot = capture(hv) { save(shot, "ui-open-first.png") }
        // The first window-server capture of the process is slow. Do it now so the frames of the later opens are not delayed by it.
        if let hv = hostView { _ = windowFrame(hv) }
        let visible = hostView?.window?.isVisible == true
        let liveOk = (result.liveSeenMs ?? .infinity) <= 1500
        let gap = probe.maxAppGap(from: result.refTime - 0.05, to: result.refTime + 1.5)
        let gapOk = gap < 600
        let ok = popover.isShown && visible && liveOk && result.timersWhileOpen == 2 && gapOk
        record("B", "打开", ok, since: t0,
               "isShown=\(popover.isShown) windowVisible=\(visible) liveSampling=\(result.liveSeenMs.map { String(format: "%.0f ms", $0) } ?? "never") timers=\(result.timersWhileOpen); performClick call \(String(format: "%.0f", result.clickMs)) ms (includes the simulated highlight); longest main-thread gap during the first 1.5 s after the cold first open, no harness work in it: \(String(format: "%.1f", gap)) ms (limit 600 ms for the cold open on a VM; later opens are judged in C, I and E)",
               ["performClickMs": result.clickMs, "liveSeenMs": result.liveSeenMs ?? -1,
                "timersWhileOpen": Double(result.timersWhileOpen), "firstOpenMaxGapMs": gap])
        return result
    }

    /// Motion in layer samples: steps where the value changed while the layer count stayed the same, and the time of the last change.
    func layerMotion(_ r: OpenResult) -> (steps: Int, settledMs: Double, settled: Bool, minValue: Double, maxValue: Double) {
        let s = r.signatures
        var steps = 0
        var lastChange = 0.0
        for (a, b) in zip(s, s.dropFirst()) where abs(a.value - b.value) > 1e-6 {
            if a.count == b.count { steps += 1 }
            lastChange = b.offset
        }
        let tail = s.suffix(5)
        let settled = tail.count == 5 && (tail.map { $0.value }.max() ?? 0) - (tail.map { $0.value }.min() ?? 0) < 1e-6
        return (steps, lastChange, settled, s.map { $0.value }.min() ?? 0, s.map { $0.value }.max() ?? 0)
    }

    // C: entrance animation advances
    func stepC(_ open: OpenResult) {
        let t0 = now()
        let shots = open.shots
        var fractions = [Double]()
        for i in 0..<Swift.max(0, shots.count - 1) {
            fractions.append(UITestPixels.compare(shots[i].shot, shots[i + 1].shot).fraction)
        }
        // The last frame is 200 ms after the one before it, so a finished animation gives no change between them.
        let enough = open.windowCapture && shots.count >= 7
        let moving = enough ? fractions.prefix(5).filter { $0 > 0.005 }.count : 0
        let settledPixels = enough && fractions[5] < 0.001
        let total = enough ? UITestPixels.compare(shots[0].shot, shots[6].shot).fraction : 0
        let pixelOk = enough && moving >= 2 && settledPixels && total > 0.01

        let layer = layerMotion(open)
        let layerOk = layer.steps >= 3 && layer.settled
        let animatedMax = open.signatures.map { $0.animated }.max() ?? 0
        let offsets = shots.map { Int($0.offset.rounded()) }
        let gap = probe.maxAppGap(from: open.afterTime, to: open.refTime + 1.5)
        var values: [String: Double] = ["movingTransitions": Double(moving), "firstToLast": total,
                                        "layerMotionSteps": Double(layer.steps), "layerLastChangeMs": layer.settledMs,
                                        "layerSamples": Double(open.signatures.count), "layerAnimationsMax": Double(animatedMax),
                                        "windowCapture": open.windowCapture ? 1 : 0, "gapAfterOpenMs": gap]
        for (i, f) in fractions.enumerated() { values["changedFraction_\(i)_\(i + 1)"] = f }
        let how = pixelOk ? "window pixels" : (layerOk ? "layer values" : "no method")
        info["entranceFrameOffsetsMs"] = offsets.map(String.init).joined(separator: ",")
        info["layerSignatures"] = open.signatures.enumerated().filter { $0.offset % 3 == 0 }
            .map { String(format: "%.0f:%.2f/%d", $0.element.offset, $0.element.value, $0.element.count) }.joined(separator: " ")
        let detail = "layer samples \(open.signatures.count), steps with a changing value at a constant layer count \(layer.steps), last change at \(Int(layer.settledMs)) ms, settled at the end=\(layer.settled), values \(String(format: "%.2f", layer.minValue))...\(String(format: "%.2f", layer.maxValue)), layers with a Core Animation animation (max) \(animatedMax); window-server frames \(shots.count) (capture works=\(open.windowCapture)) at \(offsets) ms, changed-pixel share per step \(fractions.map { String(format: "%.3f", $0) }), steps that moved \(moving) of 5, settled at the end=\(settledPixels); open call \(String(format: "%.0f", open.clickMs)) ms; longest main-thread gap after the show call \(String(format: "%.1f", gap)) ms; motion shown by \(how)"
        if pixelOk || layerOk {
            record("C", "入场动画在推进", true, since: t0, detail, values)
        } else if !open.windowCapture && layer.steps < 3 {
            // Neither view could see the animation. That is a limit of this VM, not a measured absence of motion.
            record("C", "入场动画在推进", nil, since: t0, "Cannot observe the animation here: no window-server capture and the SwiftUI drawing exposes no changing layer values. " + detail, values)
        } else {
            record("C", "入场动画在推进", false, since: t0, detail, values)
        }
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
        hover(to: away, method: worked ?? .windowSendEvent)
        await sleepMs(200)
    }

    // G: authorization row and accessibility audit
    func stepG() async {
        let t0 = now()
        let auth = engine.authorization
        let enable = locate("btn.enableNotifications")
        let note = locate("label.authorization")
        let nodes = axNodes()
        let texts = ["unavailable": "此环境无法发送通知，提醒只显示在这里", "denied": "通知已关闭，可在系统设置 > 通知中打开"]
        info["authorization"] = auth
        switch auth {
        case "unavailable", "denied":
            let expected = texts[auth] ?? ""
            let textNode = nodes.first { $0.id == "label.authorization" }
            let textOk = textNode.map { $0.label.contains(expected) || $0.value.contains(expected) } ?? (note != nil)
            let how = textNode == nil ? "layout registry only, the text itself is not read" : "text read from the accessibility tree"
            record("G", "按钮交互与降级文案", enable == nil && note != nil && textOk, since: t0,
                   "authorization=\(auth); enable button shown=\(enable != nil); fallback text shown=\(note != nil) (\(how)); expected text: \(expected)")
        case "not_determined":
            if let enable {
                let look = await pressLook(enable, saveAs: "ui-button-pressed.png")
                record("G", "按钮交互与降级文案", look.worked != nil && popover.isShown, since: t0,
                       "authorization=not_determined; 开启通知 located by \(enable.source); pressed look seen by \(look.worked?.rawValue ?? "no method"); \(look.state); changed share in the button \(look.shares); popover still shown=\(popover.isShown)")
            } else {
                record("G", "按钮交互与降级文案", false, since: t0, "authorization=not_determined but the enable button has no frame.")
            }
        case "authorized":
            record("G", "按钮交互与降级文案", enable == nil && note == nil, since: t0, "authorization=authorized; no enable button and no fallback text expected; enable shown=\(enable != nil) text shown=\(note != nil)")
        default:
            record("G", "按钮交互与降级文案", nil, since: t0, "authorization=\(auth): no check defined for this state.")
        }

        // G3: the quit button reacts to a press. The pointer is released outside the button, so the app keeps running.
        let t3 = now()
        if let quit = locate("btn.quit") {
            let look = await pressLook(quit, saveAs: "ui-quit-pressed.png")
            quitPressWorked = look.worked != nil
            quitNeedsActivation = look.activationNeeded
            info["quitPressState"] = look.state
            let note = "btn.quit located by \(quit.source); pressed look seen by \(look.worked?.rawValue ?? "no method"); activation needed=\(look.activationNeeded); \(look.state); changed share in the button \(look.shares); popover still shown=\(popover.isShown)"
            // A press that no method makes visible cannot tell a product defect from an event SwiftUI ignores in this VM.
            record("G3", "退出按钮按下反馈", look.worked != nil ? true : nil, since: t3,
                   look.worked != nil ? note : note + ". Synthetic presses did not change the button here; not proof of a product defect.")
        } else {
            record("G3", "退出按钮按下反馈", nil, since: t3, "btn.quit has no frame.")
        }

        // Accessibility audit
        let t1 = now()
        let ids = nodes.map { $0.id }.filter { !$0.isEmpty }
        info["axNodes"] = String(nodes.count)
        info["axIdentifiers"] = ids.joined(separator: ",")
        info["registryIds"] = UITestFrameStore.shared.ids.joined(separator: ",")
        let ours = ids.filter { id in ["btn.", "chart.", "card.", "label."].contains { id.hasPrefix($0) } }
        guard !ours.isEmpty else {
            record("G2", "无障碍标识与中文标签", nil, since: t1,
                   "The accessibility tree has \(nodes.count) node(s) and none with our identifiers; SwiftUI does not expose its tree to this process here. The source audit in scripts/ci_acceptance.py covers identifiers and Chinese labels of every Button.")
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
    func stepIJ(first: OpenResult) async {
        let t0 = now()
        guard let again = await openPanel(offsets: [0, 60, 120, 200, 300, 450, 650], via: .sendAction, holdMs: 750, prefix: "open2") else {
            record("I", "再次打开", false, since: t0, "popover.isShown is false after the second click.")
            record("J", "深浅色", nil, since: now(), "The panel did not reopen.")
            return
        }
        func settleOffset(_ shots: [(offset: Double, shot: UITestShot)]) -> Double? {
            guard let final = shots.last?.shot else { return nil }
            return shots.first { UITestPixels.compare($0.shot, final).fraction < 0.001 }?.offset
        }
        func settleBySignature(_ r: OpenResult) -> Double? {
            guard !r.signatures.isEmpty else { return nil }
            return layerMotion(r).settledMs
        }
        let usePixels = first.windowCapture && again.windowCapture
        let firstSettle = usePixels ? settleOffset(first.shots) : settleBySignature(first)
        let secondSettle = usePixels ? settleOffset(again.shots) : settleBySignature(again)
        var settledBy120: Double = -1
        if usePixels, let at120 = again.shots.first(where: { $0.offset >= 100 }), let final = again.shots.last?.shot {
            settledBy120 = UITestPixels.compare(at120.shot, final).fraction < 0.001 ? 1 : 0
        }
        let openOk = again.clickMs <= first.clickMs * 1.5 + 20
        let shorter = (secondSettle ?? .infinity) <= (firstSettle ?? .infinity)
        let liveOk = (again.liveSeenMs ?? .infinity) <= 1500
        let gap = probe.maxAppGap(from: again.afterTime, to: again.refTime + 1.5)
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "never" }
        record("I", "再次打开", openOk && shorter && liveOk && again.timersWhileOpen == 2, since: t0,
               "open call \(String(format: "%.1f", again.clickMs)) ms (earlier open with the full entrance \(String(format: "%.1f", first.clickMs)) ms); settled at \(fmt(secondSettle)) ms (first open \(fmt(firstSettle)) ms); settled within 120 ms=\(settledBy120 == 1) (compared by \(usePixels ? "window pixels" : "layer values"), layer motion steps \(layerMotion(again).steps) after the reopen against \(layerMotion(first).steps) after the full entrance); longest main-thread gap after the show call \(String(format: "%.1f", gap)) ms; liveSampling at \(fmt(again.liveSeenMs)) ms",
               ["openCallMs": again.clickMs, "firstOpenCallMs": first.clickMs, "settledMs": secondSettle ?? -1,
                "firstSettledMs": firstSettle ?? -1, "settledWithin120ms": settledBy120, "gapAfterOpenMs": gap])

        // J: light and dark
        let t1 = now()
        guard let hv = hostView else { record("J", "深浅色", false, since: t1, "no hosting view"); return }
        // The popover takes its look from its own appearance, so set both the app and the popover.
        NSApp.appearance = NSAppearance(named: .aqua)
        popover.appearance = NSAppearance(named: .aqua)
        await sleepMs(600)
        let light = capture(hv)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        popover.appearance = NSAppearance(named: .darkAqua)
        await sleepMs(600)
        let dark = capture(hv)
        NSApp.appearance = nil
        popover.appearance = nil
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
        let gaps = probe.gaps()
        let all = UITestStats(gaps.all)
        let app = UITestStats(gaps.app)
        let render = UITestStats(renderMs)
        let ok = app.count > 500 && app.max < 250 && app.p95 < 40
        record("E", "主线程流畅度（回归门禁）", ok, since: t0,
               "timer 120 Hz over the warm opens, panel use and closes (the cold first open is judged in B), \(app.count) gaps outside harness work (\(gaps.harness) gaps overlapped harness captures and are left out): p50 \(String(format: "%.1f", app.p50)) ms p95 \(String(format: "%.1f", app.p95)) ms max \(String(format: "%.1f", app.max)) ms; all gaps incl. harness work: p95 \(String(format: "%.1f", all.p95)) ms max \(String(format: "%.1f", all.max)) ms; cacheDisplay render \(render.count) frames: p50 \(String(format: "%.1f", render.p50)) ms max \(String(format: "%.1f", render.max)) ms. This shows no long main-thread block in a VM. It is not a GPU frame rate.",
               ["p50": app.p50, "p95": app.p95, "max": app.max, "intervals": Double(app.count),
                "allP95": all.p95, "allMax": all.max,
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
        let center = CGPoint(x: loc.rect.midX, y: loc.rect.midY)
        // terminate(_:) ends the process. Still here after a click means that click did not reach the button.
        var tried = [String]()
        for activate in [false, true] {
            if activate {
                activateApp()
                await sleepMs(300)
            }
            for method in [ClickMethod.appKitEvent, ClickMethod.systemEvent] {
                tried.append("\(activate ? "activated" : "not activated") \(method.rawValue)")
                press(at: center, method: method)
                await sleepMs(120)
                release(at: center, method: method)
                await sleepMs(1500)
            }
        }
        if let index = items.firstIndex(where: { $0.id == "K" }) {
            if quitPressWorked {
                items[index].status = "fail"
                items[index].note = "The click on 退出 did not end the process although a press changes the button (G3); tried \(tried)."
                log("[FAIL] K the process is still running after the clicks.")
                finish(abort: nil, exitCode: 1)
            } else {
                items[index].status = "skipped"
                items[index].note = "Synthetic clicks do not reach the SwiftUI button in this VM (G3 shows no pressed look); tried \(tried). The quit action is the closure NSApplication.terminate(nil) in Sources/MoleMonitor.swift. Verify on a Mac by hand."
                log("[SKIP] K synthetic clicks did not reach the button.")
                finish(abort: nil, exitCode: 0)
            }
        }
    }

    // MARK: Output

    func writeReport() {
        let gaps = probe.gaps()
        let report = UITestReport(items: items,
                                  mainThreadIntervalsMs: gaps.app.isEmpty ? nil : UITestStats(gaps.app),
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
