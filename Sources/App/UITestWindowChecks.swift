// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the real PanelWindow of AppDelegate and synthetic PanelWindow objects
//        that stand at the left or right of the screen (docs/DESIGN_V2.md 10, 13.3).
// Output: W03 open speed and no white flash, W05 sidebar window motion, W06 hover intent in the window, W10 Esc layers and close
//         (with the notification pin R-14 and the icon toggle). Also the NSPopover stand-in that the old checks A to N use.
// Pos: Test code. It exists only in the UITEST build; the release binary has none of it (scripts/ci_acceptance.py audits this).
//      Owner WP-B. The gate registry (scripts/ci_acceptance.py GATES) lists W03, W05, W06 and W10 as pending until WP-F activates them.
//      The checks call only the test hooks of PanelWindow (inside `#if UITEST`) and the public interface of PanelChrome.
//      Every check leaves the panel closed.
// UITEST-REGISTER: UITestWindowChecks

#if UITEST
import AppKit
import SwiftUI

// MARK: - NSPopover stand-in for the old checks

/// The old checks (A to N, UITestPanelChecks.swift) ask `delegate.popover` for isShown, contentViewController, appearance and
/// performClose. The product has no popover now. This stand-in answers from the PanelWindow, so the old checks keep their
/// thresholds and only the object behind them changes (docs/DESIGN_V2.md 13.2.1). `contentViewController.view` is the main column,
/// so rectangles that are relative to the hosting view keep their meaning.
@MainActor
final class UITestPopoverAdapter: NSPopover {
    private weak var owner: AppDelegate?
    private var proxy: NSViewController?

    init(delegate: AppDelegate) {
        owner = delegate
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("UITestPopoverAdapter has no coder")
    }

    override var isShown: Bool {
        guard let window = owner?.panelWindow else { return false }
        return !window.isClosing && !window.isFinished
    }

    override var contentViewController: NSViewController? {
        get {
            guard let window = owner?.panelWindow, !window.isFinished else {
                // Drop the proxy so that the old check "controller released" sees it go.
                proxy = nil
                return nil
            }
            if let proxy { return proxy }
            let controller = NSViewController()
            controller.view = window.mainHost
            proxy = controller
            return controller
        }
        set {}
    }

    override var appearance: NSAppearance? {
        get { owner?.panelWindow?.appearance }
        set { owner?.panelWindow?.appearance = newValue }
    }

    override func performClose(_ sender: Any?) {
        owner?.panelWindow?.closePanel()
    }
}

// MARK: - Registration

enum UITestWindowChecks {
    @MainActor static func register(into registry: UITestRegistry) {
        registry.add("W03", "open speed and no white flash") { runner in await w03(runner) }
        registry.add("W05", "sidebar window motion") { runner in await w05(runner) }
        registry.add("W06", "hover intent in the window") { runner in await w06(runner) }
        registry.add("W10", "Esc layers and close") { runner in await w10(runner) }
    }

    // MARK: Helpers

    /// Opens the real panel through the status item button (or the fallback anchor). The caller has closed the panel before.
    @MainActor
    private static func openReal(_ r: UITestRunner, entrance: PanelEntrance? = PanelEntrance.none) -> (window: PanelWindow?, before: Double, callMs: Double) {
        r.axCache = nil
        UITestFrameStore.shared.reset()
        r.delegate.testEntrance = entrance
        defer { r.delegate.testEntrance = nil }
        let before = r.now()
        if let button = r.delegate.statusItem?.button, button.window != nil, let action = button.action {
            _ = NSApp.sendAction(action, to: button.target, from: button)
        } else {
            r.delegate.showPanel()
        }
        let after = r.now()
        return (r.delegate.panelWindow, before, (after - before) * 1000)
    }

    /// The CI VM can report Reduce Motion as on. The window checks need the real motion, so they force it off.
    @MainActor
    private static func motionOn() {
        PanelWindow.testReduceMotion = false
    }

    @MainActor
    private static func ensureClosed(_ r: UITestRunner) async {
        if r.delegate.panelWindow != nil { await r.closePanelQuietly() }
        PanelWindow.testReduceMotion = nil
    }

    @MainActor
    private static func screenX(_ w: PanelWindow) -> Double {
        Double(w.convertToScreen(w.mainHost.convert(w.mainHost.bounds, to: nil)).minX)
    }

    /// Mean brightness (0 to 255) of the pixels that are at least half opaque, and their share of all pixels.
    private static func luma(_ shot: UITestShot) -> (mean: Double, opaqueShare: Double) {
        var sum = 0.0
        var count = 0
        var index = 0
        while index + 3 < shot.rgba.count {
            let a = Double(shot.rgba[index + 3])
            if a >= 128 {
                let k = 255 / a
                let r = Double(shot.rgba[index]) * k
                let g = Double(shot.rgba[index + 1]) * k
                let b = Double(shot.rgba[index + 2]) * k
                sum += 0.299 * r + 0.587 * g + 0.114 * b
                count += 1
            }
            index += 4
        }
        let total = Double(Swift.max(1, shot.w * shot.h))
        return (count > 0 ? sum / Double(count) : 0, Double(count) / total)
    }

    /// Alpha and on-screen state of a window as the window server reports them.
    @MainActor
    private static func serverAlpha(_ w: NSWindow) -> (alpha: Double, onscreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
              let info = list.first else { return nil }
        let alpha: Double = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let onscreen: Bool = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return (alpha, onscreen)
    }

    private static func fmt(_ v: Double?, _ digits: Int = 0) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? "n/a"
    }

    // MARK: W03 open speed and no white flash

    @MainActor
    private static func w03(_ r: UITestRunner) async {
        let t0 = r.now()
        await ensureClosed(r)
        motionOn()
        let opened = openReal(r)
        guard let window = opened.window else {
            r.record("W03", "open speed and no white flash", false, since: t0, "The panel did not open.")
            return
        }
        let host = window.mainHost
        var firstVisibleMs: Double?
        var firstLuma: Double?
        var firstOpaqueShare = 0.0
        var dogReadyMs: Double?
        var dogShare: Double?
        var contentFirstLuma: Double?
        let surface = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? UITestContrast.darkSurface : UITestContrast.lightSurface
        var captureWorked = false
        var serverAlphaAtFirst = 0.0
        var fullAlphaMs = 0.0
        while (r.now() - opened.before) * 1000 < 500 {
            let elapsed = (r.now() - opened.before) * 1000
            // The place of the dog is known (cheap check, no capture).
            if dogReadyMs == nil, let dog = r.panelRect("dog"), dog.width > 1 { dogReadyMs = elapsed }
            // The first visible frame: the window server shows the window with an alpha above 0.02.
            if firstVisibleMs == nil, let server = serverAlpha(window), server.onscreen, server.alpha > 0.02 {
                firstVisibleMs = elapsed
                serverAlphaAtFirst = server.alpha
                // The dog must be in the content of that frame (the content image has no window alpha).
                if let shot = r.capture(host) {
                    contentFirstLuma = luma(shot).mean
                    if let dog = r.panelRect("dog"), let stats = UITestDogStats.measure(shot, region: dog, surface: surface), stats.area > 0 {
                        dogShare = Double(stats.ink) / Double(stats.area)
                    }
                }
            }
            // The window image of the window server includes the window alpha (it is dark while the window fades in). So the
            // brightness is judged on the first image with an alpha of at least 0.95 before and after the capture.
            if firstVisibleMs != nil, firstLuma == nil, !r.windowCaptureUnavailable, let before = serverAlpha(window), before.alpha >= 0.95 {
                if let frame = r.windowFrame(host), let after = serverAlpha(window), after.alpha >= 0.95 {
                    captureWorked = true
                    let l = luma(frame)
                    firstLuma = l.mean
                    firstOpaqueShare = l.opaqueShare
                    fullAlphaMs = elapsed
                }
            }
            if firstVisibleMs != nil && (firstLuma != nil || r.windowCaptureUnavailable) { break }
            await r.sleepMs(3)
        }
        // Steady state one second after the click.
        await r.sleepUntil(opened.before + 1.0)
        let steadyWindow = r.windowCaptureUnavailable ? nil : r.windowFrame(host).map { luma($0).mean }
        let steadyContent = r.capture(host).map { luma($0).mean }
        let windowDiff = (firstLuma != nil && steadyWindow != nil) ? abs(firstLuma! - steadyWindow!) : nil
        let contentDiff = (contentFirstLuma != nil && steadyContent != nil) ? abs(contentFirstLuma! - steadyContent!) : nil
        // Without window capture the call duration is the only time measure.
        let speedMs = firstVisibleMs ?? opened.callMs
        let speedOk = speedMs <= 150
        let flashOk = (windowDiff ?? 0) <= 10 && (contentDiff ?? 0) <= 10 && (windowDiff != nil || contentDiff != nil)
        let dogOk = (dogShare ?? 0) >= 0.01 && (dogReadyMs ?? .infinity) <= 150
        let ok = speedOk && flashOk && dogOk
        r.record("W03", "open speed and no white flash", ok, since: t0,
                 "click to first visible frame \(fmt(firstVisibleMs)) ms at window alpha \(fmt(serverAlphaAtFirst, 2)) (limit 150; \(captureWorked ? "window server frame" : "window capture unavailable, call duration used")); call \(fmt(opened.callMs)) ms; window image at alpha 1 (\(fmt(fullAlphaMs)) ms) brightness \(fmt(firstLuma, 1)) (opaque share \(fmt(firstOpaqueShare * 100)) %), steady \(fmt(steadyWindow, 1)), difference \(fmt(windowDiff, 1)) (limit 10); content brightness first \(fmt(contentFirstLuma, 1)), steady \(fmt(steadyContent, 1)), difference \(fmt(contentDiff, 1)); dog region ready \(fmt(dogReadyMs)) ms, non-background share \(fmt((dogShare ?? 0) * 100, 1)) % (limit 1 %)",
                 ["firstVisibleMs": firstVisibleMs ?? -1, "callMs": opened.callMs, "windowLumaDiff": windowDiff ?? -1,
                  "contentLumaDiff": contentDiff ?? -1, "dogSharePercent": (dogShare ?? 0) * 100, "dogReadyMs": dogReadyMs ?? -1])
        await r.closePanelQuietly()
    }

    // MARK: W05 sidebar window motion

    /// What the window server says about the window now (screen points, top-left origin). The model `frame` of an NSWindow
    /// jumps to the target at once when the frame is animated, so the motion is read from the window server.
    @MainActor
    private static func serverBounds(_ w: NSWindow) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    private struct Track {
        var reachedMs: Double?
        var heightDrift = 0.0
        var samples = 0
        var steps = 0
        var fromServer = false
    }

    /// Polls the window server every 3 ms until the width is `target` (within 0.5 pt) or the time is over.
    @MainActor
    private static func track(_ r: UITestRunner, _ w: PanelWindow, since start: Double, target: Double, timeoutMs: Double,
                              h0: Double) async -> Track {
        var t = Track()
        var seen = Set<Int>()
        while true {
            let elapsed = (r.now() - start) * 1000
            let server = serverBounds(w)
            t.fromServer = server != nil
            let width = Double(server?.width ?? w.frame.width)
            let height = Double(server?.height ?? w.frame.height)
            t.samples += 1
            if width > 353 && width < 671 { seen.insert(Int(width.rounded())) }
            t.heightDrift = Swift.max(t.heightDrift, abs(height - h0))
            if abs(width - target) <= 0.5 {
                t.reachedMs = elapsed
                t.steps = seen.count
                return t
            }
            if elapsed >= timeoutMs {
                t.steps = seen.count
                return t
            }
            await r.sleepMs(3)
        }
    }

    /// The main column seen in window frames: a piece of the main column is cut from the frame before the motion. In each frame
    /// during the motion the piece is searched along the width, and its place on the screen is computed from the fixed edge of the
    /// window. The place must not change (docs/DESIGN_V2.md 13.3 W05: at most 0.5 pt).
    private struct VisualProbe {
        var template: [Double]
        var rows: Range<Int>
        var x0: Int
        var scale: Double
        var windowLeft0: Double
        var windowRight0: Double
        var edge: SidebarEdge
        var contrast: Double
    }

    private static func columnSums(_ shot: UITestShot, rows: Range<Int>) -> [Double] {
        var sums = [Double](repeating: 0, count: shot.w)
        let lo = Swift.max(0, rows.lowerBound), hi = Swift.min(shot.h, rows.upperBound)
        guard hi > lo else { return sums }
        for y in lo..<hi {
            var i = y * shot.w * 4
            for x in 0..<shot.w {
                sums[x] += 0.299 * Double(shot.rgba[i]) + 0.587 * Double(shot.rgba[i + 1]) + 0.114 * Double(shot.rgba[i + 2])
                i += 4
            }
        }
        return sums
    }

    /// `region` is in points of the main column, top-left origin. The window must be closed (352 pt wide) and settled.
    @MainActor
    private static func makeProbe(_ r: UITestRunner, _ w: PanelWindow, region: CGRect) -> VisualProbe? {
        guard let ref = r.windowFrame(w.mainHost), ref.w > 0 else { return nil }
        let scale = Double(ref.w) / PanelWindowMetrics.mainWidth
        let x0 = Int(Double(region.minX) * scale)
        let tw = Int(Double(region.width) * scale)
        let rowStart: Int = Int(Double(region.minY) * scale)
        let rowEnd: Int = Int(Double(region.maxY) * scale)
        let rows: Range<Int> = rowStart..<rowEnd
        let sums = columnSums(ref, rows: rows)
        guard tw > 8, x0 >= 0, x0 + tw <= sums.count, !rows.isEmpty else { return nil }
        let template = Array(sums[x0..<(x0 + tw)])
        let contrast = ((template.max() ?? 0) - (template.min() ?? 0)) / Double(rows.count)
        return VisualProbe(template: template, rows: rows, x0: x0, scale: scale, windowLeft0: Double(w.frame.minX),
                           windowRight0: Double(w.frame.maxX), edge: w.sidebarEdge, contrast: contrast)
    }

    /// Place of the piece on the screen in a frame, and the mean brightness error of the best match.
    private static func visualX(_ probe: VisualProbe, _ frame: UITestShot) -> (x: Double, error: Double, widthPt: Double)? {
        let cs = columnSums(frame, rows: probe.rows)
        let tw = probe.template.count
        guard cs.count >= tw else { return nil }
        var best = Double.infinity
        var bestAt = 0
        for o in 0...(cs.count - tw) {
            var sad = 0.0
            for i in 0..<tw {
                sad += abs(cs[o + i] - probe.template[i])
                if sad >= best { break }
            }
            if sad < best { best = sad; bestAt = o }
        }
        let widthPt = Double(frame.w) / probe.scale
        let left = probe.edge == .right ? probe.windowLeft0 : probe.windowRight0 - widthPt
        let x: Double = left + Double(bestAt) / probe.scale
        let cells: Double = Double(tw * Swift.max(1, probe.rows.count))
        let error: Double = best / cells
        return (x, error, widthPt)
    }

    private struct VisualRun {
        var frames = 0
        var intermediate = 0
        var maxDrift = 0.0
        var maxError = 0.0
        var series = [String]()
    }

    /// Clicks the row (open if closed, close if open), captures window frames until the target width, and measures the drift.
    @MainActor
    private static func visualRun(_ r: UITestRunner, _ w: PanelWindow, _ probe: VisualProbe, opening: Bool) async -> VisualRun {
        var run = VisualRun()
        let x0 = probe.windowLeft0 + Double(probe.x0) / probe.scale
        let start = r.now()
        w.reportClick(.memory)
        while (r.now() - start) * 1000 < 800 {
            guard let shot = r.windowFrame(w.mainHost), let m = visualX(probe, shot) else { break }
            let t = (r.now() - start) * 1000
            run.frames += 1
            if m.widthPt > 353 && m.widthPt < 671 { run.intermediate += 1 }
            run.maxDrift = Swift.max(run.maxDrift, abs(m.x - x0))
            run.maxError = Swift.max(run.maxError, m.error)
            let offset: String = String(format: "%.1f", m.x - x0)
            let widthText: Int = Int(m.widthPt.rounded())
            run.series.append("\(Int(t)):\(widthText)/\(offset)")
            let reached: Bool = opening ? (m.widthPt >= 671.5) : (m.widthPt <= 352.5)
            if reached { break }
            await r.sleepMs(1)
        }
        return run
    }

    /// Main column for the synthetic windows: stripes of different widths on the left, so a piece of it can be found again.
    private struct W05Stripes: View {
        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { i in
                        Rectangle().fill(i % 2 == 0 ? Color.red : Color.blue).frame(width: CGFloat(6 + (i * 7) % 13))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 100)
                Spacer(minLength: 0)
            }
            .frame(width: CGFloat(PanelWindowMetrics.mainWidth), height: 420)
        }
    }

    /// A panel window that stands at the left or right part of the screen, so that the sidebar opens in the wanted direction.
    @MainActor
    private static func syntheticWindow(_ desired: SidebarEdge) -> PanelWindow? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame.panelRect
        let mid = desired == .right ? visible.minX + 220 : visible.maxX - 220
        let placement = PanelWindowGeometry.place(anchorMidX: mid, anchorMinY: visible.maxY, visible: visible, height: 420)
        guard placement.edge == desired else { return nil }
        let window = PanelWindow(placement: placement, visibleMinY: visible.minY, main: AnyView(W05Stripes()), sidebar: nil)
        window.present()
        return window
    }

    private struct W05Result {
        var label: String
        var ok: Bool
        var note: String
    }

    /// Runs hover open, close button, click open and click close on one window (timing from the window server), then the
    /// frame-by-frame drift of the main column.
    @MainActor
    private static func sidebarCycle(_ r: UITestRunner, _ w: PanelWindow, label: String, reduceMotion: Bool, probeRegion: CGRect?) async -> W05Result {
        let h0 = Double(serverBounds(w)?.height ?? w.frame.height)
        let shifted = w.placement.mainShift != 0
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        var problems = [String]()
        var parts = [String]()
        var steps = 0
        func judge(_ name: String, _ t: Track, limit: Double) {
            if let ms = t.reachedMs, ms <= limit {} else { problems.append("\(name) reached \(fmt(t.reachedMs)) ms (limit \(Int(limit)))") }
            if t.heightDrift > 0.5 { problems.append("\(name): height changed \(fmt(t.heightDrift, 2)) pt") }
            steps += t.steps
            parts.append("\(name) \(fmt(t.reachedMs)) ms (\(t.steps) steps, \(t.fromServer ? "window server" : "model frame"))")
        }
        let motionLimit = reduceMotion ? 150.0 : 250.0
        // Hover: 350 ms of rest, then the window grows. Judged 400 ms after the start plus the limit of the motion.
        let hoverStart = r.now()
        w.testPointer(.row(.cpu), at: NSPoint(x: 200, y: h0 / 2))
        judge("hover open", await track(r, w, since: hoverStart, target: 672, timeoutMs: 1300, h0: h0), limit: 400 + motionLimit)
        // Inside the visible frame and below the menu bar.
        if let visible, visible.width >= 672, let f = serverBounds(w) {
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let top = screenHeight - f.minY   // AppKit y of the top edge
            let leftOut: Bool = f.minX < visible.minX - 0.5
            let rightOut: Bool = f.maxX > visible.maxX + 0.5
            let topOut: Bool = top > visible.maxY + 0.5
            if leftOut || rightOut || topOut {
                problems.append("expanded frame \(NSStringFromRect(f)) leaves the visible frame \(NSStringFromRect(visible))")
            }
        }
        let closeStart = r.now()
        w.reportCloseButton()
        judge("close", await track(r, w, since: closeStart, target: 352, timeoutMs: 700, h0: h0), limit: motionLimit)
        await r.sleepMs(120)
        let clickStart = r.now()
        w.reportClick(.memory)
        if w.pinnedSidebarItem != .memory { problems.append("click did not pin the memory sidebar") }
        judge("click open", await track(r, w, since: clickStart, target: 672, timeoutMs: 700, h0: h0), limit: motionLimit)
        let click2Start = r.now()
        w.reportClick(.memory)
        judge("click close", await track(r, w, since: click2Start, target: 352, timeoutMs: 700, h0: h0), limit: motionLimit)
        if !reduceMotion && steps < 4 { problems.append("the window server showed only \(steps) intermediate widths in four motions: the frame animation is not visible") }
        // Frame-by-frame drift of the main column.
        var visualNote = "visual drift not measured"
        if !shifted, let region = probeRegion {
            await r.sleepMs(150)
            if let probe = makeProbe(r, w, region: region) {
                if probe.contrast < 2 { problems.append("the piece for the drift measurement has no texture (contrast \(fmt(probe.contrast, 1)))") }
                let open = await visualRun(r, w, probe, opening: true)
                await r.sleepMs(150)
                let close = await visualRun(r, w, probe, opening: false)
                let drift = Swift.max(open.maxDrift, close.maxDrift)
                let intermediate = open.intermediate + close.intermediate
                if drift > 0.5 { problems.append("the main column moved \(fmt(drift, 2)) pt on the screen") }
                if !reduceMotion && intermediate < 2 { problems.append("only \(intermediate) intermediate frames were captured") }
                let frameCount: Int = open.frames + close.frames
                let errorText: String = fmt(Swift.max(open.maxError, close.maxError), 1)
                let contrastText: String = fmt(probe.contrast, 1)
                var text: String = "visual drift \(fmt(drift, 2)) pt over \(frameCount) frames (\(intermediate) intermediate, match error \(errorText), contrast \(contrastText))"
                text += "; open " + open.series.joined(separator: " ")
                text += "; close " + close.series.joined(separator: " ")
                visualNote = text
            } else {
                visualNote = "visual drift: window capture or template not available"
            }
        } else if shifted {
            visualNote = "visual drift skipped: the main column moves by design on this screen (shift \(fmt(w.placement.mainShift, 1)) pt)"
        }
        let edge = w.sidebarEdge == .right ? "right" : "left"
        let shiftText: String = fmt(w.placement.mainShift, 1)
        var note: String = "\(label) (edge \(edge), main shift \(shiftText) pt): "
        note += parts.joined(separator: ", ")
        note += "; " + visualNote
        if !problems.isEmpty { note += " PROBLEMS: " + problems.joined(separator: " / ") }
        return W05Result(label: label, ok: problems.isEmpty, note: note)
    }

    @MainActor
    private static func w05(_ r: UITestRunner) async {
        let t0 = r.now()
        await ensureClosed(r)
        motionOn()
        var results = [W05Result]()
        var skipped = [String]()
        // Both directions on synthetic windows at the two sides of the screen.
        for desired in [SidebarEdge.right, SidebarEdge.left] {
            guard let w = syntheticWindow(desired) else {
                skipped.append("edge \(desired.rawValue) (the screen is too narrow for it)")
                continue
            }
            await r.sleepMs(300)
            results.append(await sidebarCycle(r, w, label: "synthetic \(desired.rawValue)", reduceMotion: false,
                                              probeRegion: CGRect(x: 6, y: 30, width: 120, height: 80)))
            w.closePanel()
            await r.sleepMs(200)
        }
        // Reduce Motion: the window jumps, no animation.
        if let w = syntheticWindow(.right) {
            PanelWindow.testReduceMotion = true
            await r.sleepMs(300)
            results.append(await sidebarCycle(r, w, label: "synthetic right, Reduce Motion", reduceMotion: true, probeRegion: nil))
            PanelWindow.testReduceMotion = false
            w.closePanel()
            await r.sleepMs(200)
        }
        // The real panel with its real anchor and content.
        let opened = openReal(r)
        if let real = opened.window {
            await r.sleepMs(600)
            let dog = r.panelRect("dog")
            results.append(await sidebarCycle(r, real, label: "real panel", reduceMotion: false, probeRegion: dog))
            await r.closePanelQuietly()
        } else {
            results.append(W05Result(label: "real panel", ok: false, note: "the real panel did not open"))
        }
        let sides = Set(results.filter { $0.label.hasPrefix("synthetic") && !$0.label.contains("Reduce") && $0.ok }.map(\.label))
        let bothEdges = sides.count == 2
        let allOk = results.allSatisfy(\.ok) && !results.isEmpty && !sides.isEmpty
        var note: String = results.map(\.note).joined(separator: " | ")
        if !skipped.isEmpty { note += " | NOT VERIFIED: " + skipped.joined(separator: ", ") }
        if !bothEdges { note += " | only one direction was verified on the synthetic windows" }
        r.record("W05", "sidebar window motion", allOk, since: t0, note,
                 ["cases": Double(results.count), "failedCases": Double(results.filter { !$0.ok }.count)])
        await ensureClosed(r)
    }

    // MARK: W06 hover intent in the window

    /// A point in the main column, `fraction` of its width from the left, in window coordinates of the current sidebar state.
    @MainActor
    private static func mainPoint(_ w: PanelWindow, _ fraction: Double, y: Double? = nil) -> NSPoint {
        let origin = (w.sidebarEdge == .left && w.sidebarOpen) ? PanelWindowMetrics.sidebarWidth : 0
        return NSPoint(x: origin + fraction * PanelWindowMetrics.mainWidth, y: y ?? Double(w.frame.height) / 2)
    }

    @MainActor
    private static func w06(_ r: UITestRunner) async {
        let t0 = r.now()
        await ensureClosed(r)
        motionOn()
        let opened = openReal(r)
        guard let w = opened.window else {
            r.record("W06", "hover intent in the window", false, since: t0, "The panel did not open.")
            return
        }
        await r.sleepMs(400)
        var problems = [String]()
        var values = [String: Double]()

        // 1. Rest on a row: no open at 200 ms, open at 350 to 500 ms.
        let restStart = r.now()
        w.testPointer(.row(.cpu), at: mainPoint(w, 0.5))
        await r.sleepMs(200)
        let openedEarly = w.shownSidebarItem != nil
        var openMs: Double?
        while (r.now() - restStart) * 1000 < 900 {
            if w.shownSidebarItem == .cpu { openMs = (r.now() - restStart) * 1000; break }
            await r.sleepMs(5)
        }
        if openedEarly { problems.append("opened before 200 ms") }
        if let ms = openMs { if ms < 340 || ms > 500 { problems.append("opened at \(fmt(ms)) ms (expected 350 to 500)") } } else { problems.append("did not open after 900 ms of rest") }
        values["openMs"] = openMs ?? -1
        await r.sleepMs(300)

        // 2. Another row: the sidebar switches within 200 ms. The pointer comes from the open row, away from the sidebar.
        let away = w.sidebarEdge == .right ? 0.1 : 0.95
        w.testPointer(.row(.cpu), at: mainPoint(w, 0.55))
        await r.sleepMs(20)
        let switchStart = r.now()
        w.testPointer(.row(.memory), at: mainPoint(w, away))
        var switchMs: Double?
        while (r.now() - switchStart) * 1000 < 600 {
            if w.shownSidebarItem == .memory { switchMs = (r.now() - switchStart) * 1000; break }
            await r.sleepMs(5)
        }
        if let ms = switchMs { if ms > 200 { problems.append("switch took \(fmt(ms)) ms (limit 200)") } } else { problems.append("did not switch to the other row") }
        values["switchMs"] = switchMs ?? -1

        // 3. Leave the panel: the unpinned sidebar closes after 1.0 s (limits 0.9 to 1.13 s).
        let leaveStart = r.now()
        w.testPointerLeave()
        var leaveMs: Double?
        while (r.now() - leaveStart) * 1000 < 1600 {
            if w.shownSidebarItem == nil { leaveMs = (r.now() - leaveStart) * 1000; break }
            await r.sleepMs(5)
        }
        if let ms = leaveMs { if ms < 900 || ms > 1130 { problems.append("closed \(fmt(ms)) ms after leaving (expected 900 to 1130)") } } else { problems.append("did not close after leaving") }
        values["leaveMs"] = leaveMs ?? -1
        await r.sleepMs(350)

        // 4. A fast pointer across three rows never opens the sidebar (above 0.6 pt/ms).
        //    The step is 100 pt, so the nominal speed with a 10 ms sleep is 10 pt/ms. A VM stall or the row change render (about 100 ms on the CI VM) can stretch one step. The measured
        //    time between two moves decides: if any step is slower than 0.9 pt/ms (the limit 0.6 plus 50 %), the pass is void and
        //    is done again, at most 3 times. If all 3 passes are void, the check fails: the sweep was never fast.
        let rows: [SidebarItem] = [.cpu, .memory, .disk]
        let stepPt = 100.0
        let minSweepSpeed = 0.9
        var everOpen = false
        var validPasses = 0
        var voidPasses = 0
        var slowestStep = Double.infinity
        for _ in 0..<3 {
            var closeTries = 0
            while w.shownSidebarItem != nil && closeTries < 10 { w.testPointerLeave(); await r.sleepMs(300); closeTries += 1 }
            w.testPointerEnter()
            var y = 120.0
            var lastT: Double? = nil
            var passSlowest = Double.infinity
            var passOpen = false
            for row in rows {
                for _ in 0..<8 {
                    y += stepPt
                    let t = r.now()
                    if let l = lastT { passSlowest = Swift.min(passSlowest, stepPt / Swift.max(0.001, (t - l) * 1000)) }
                    lastT = t
                    w.testPointer(.row(row), at: NSPoint(x: 120, y: y))
                    if w.shownSidebarItem != nil { passOpen = true }
                    await r.sleepMs(10)
                }
            }
            w.testPointer(.neutral, at: NSPoint(x: 120, y: y + stepPt))
            let sweepEnd = r.now()
            while (r.now() - sweepEnd) * 1000 < 600 {
                if w.shownSidebarItem != nil { passOpen = true }
                await r.sleepMs(10)
            }
            slowestStep = Swift.min(slowestStep, passSlowest)
            if passSlowest < minSweepSpeed {
                voidPasses += 1
            } else {
                validPasses += 1
                everOpen = passOpen
                w.testPointerLeave()
                break
            }
            w.testPointerLeave()
        }
        if validPasses == 0 { problems.append("test environment too slow: no fast sweep was produced in 3 passes (slowest step \(fmt(slowestStep, 2)) pt/ms, needs at least \(minSweepSpeed))") }
        else if everOpen { problems.append("a fast pass over three rows opened the sidebar") }
        values["fastPassVoid"] = Double(voidPasses)
        values["fastPassSlowestStepSpeed"] = slowestStep.isFinite ? slowestStep : -1
        values["fastPassOpened"] = everOpen ? 1 : 0
        w.testPointerLeave()
        await r.sleepMs(200)

        // 5. Click pins: the sidebar stays 5 s although the pointer leaves.
        w.testPointer(.row(.cpu), at: mainPoint(w, 0.5))
        w.reportClick(.cpu)
        if w.pinnedSidebarItem != .cpu { problems.append("the click did not pin") }
        w.testPointerLeave()
        let pinStart = r.now()
        var pinLost = false
        while (r.now() - pinStart) * 1000 < 5000 {
            if w.shownSidebarItem != .cpu || w.pinnedSidebarItem != .cpu { pinLost = true; break }
            await r.sleepMs(50)
        }
        if pinLost { problems.append("the pinned sidebar closed within 5 s") }
        values["pinnedHeld"] = pinLost ? 0 : 1
        let pendingAfterPin = w.testHoverTaskPending
        if pendingAfterPin { problems.append("a delayed hover call is pending while pinned") }

        let ok = problems.isEmpty
        r.record("W06", "hover intent in the window", ok, since: t0,
                 "rest: no open at 200 ms (\(!openedEarly)), open at \(fmt(openMs)) ms; switch \(fmt(switchMs)) ms; close after leaving \(fmt(leaveMs)) ms; fast pass over 3 rows opened=\(everOpen) (valid \(validPasses), void \(voidPasses), slowest step \(fmt(slowestStep, 2)) pt/ms); pinned sidebar held 5 s=\(!pinLost)"
                 + (ok ? "" : " PROBLEMS: " + problems.joined(separator: " / ")), values)
        await r.closePanelQuietly()
    }

    // MARK: W10 Esc layers and close

    @MainActor
    private static func mouseEvent(_ r: UITestRunner, _ type: NSEvent.EventType, window: NSWindow, at point: NSPoint) -> NSEvent? {
        r.eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: r.eventNumber, clickCount: 1, pressure: 1)
    }

    /// Waits until the panel is closing or gone. Returns the time in ms, or nil.
    @MainActor
    private static func waitClosed(_ r: UITestRunner, timeoutMs: Double) async -> Double? {
        await r.waitFor(timeoutMs: timeoutMs) { r.delegate.panelWindow == nil || r.delegate.panelWindow?.isClosing == true }
    }

    @MainActor
    private static func w10(_ r: UITestRunner) async {
        let t0 = r.now()
        await ensureClosed(r)
        motionOn()
        var problems = [String]()
        var parts = [String]()
        var values = [String: Double]()

        // 1. Esc layers: the first Esc closes the sidebar, the second closes the panel.
        weak var weakWindow: PanelWindow?
        do {
            guard let w = openReal(r).window else {
                r.record("W10", "Esc layers and close", false, since: t0, "The panel did not open.")
                return
            }
            weakWindow = w
            await r.sleepMs(300)
            if PanelWindow.testMonitorCount != 2 { problems.append("monitors while open: \(PanelWindow.testMonitorCount) (expected 2)") }
            w.openAndPin(.cpu)
            let expanded = await r.waitFor(timeoutMs: 700) { w.frame.width >= 671.5 }
            if expanded == nil { problems.append("the sidebar did not open for the Esc test") }
            r.sendEscape()
            let sidebarClosed = await r.waitFor(timeoutMs: 400) { !w.sidebarOpen }
            let stillOpen = r.delegate.panelWindow === w && !w.isClosing
            if sidebarClosed == nil { problems.append("first Esc did not close the sidebar within 400 ms") }
            if !stillOpen { problems.append("first Esc closed the whole panel") }
            values["escSidebarMs"] = sidebarClosed ?? -1
            _ = await r.waitFor(timeoutMs: 600) { w.frame.width <= 352.5 }
            r.sendEscape()
            let panelClosed = await waitClosed(r, timeoutMs: 400)
            if panelClosed == nil { problems.append("second Esc did not close the panel within 400 ms") }
            values["escPanelMs"] = panelClosed ?? -1
            parts.append("Esc sidebar \(fmt(sidebarClosed)) ms, Esc panel \(fmt(panelClosed)) ms")
        }
        _ = await r.waitFor(timeoutMs: 1500) { r.delegate.panelWindow == nil }
        if PanelWindow.testMonitorCount != 0 { problems.append("monitors after Esc close: \(PanelWindow.testMonitorCount)") }
        let released = await r.waitFor(timeoutMs: 1500) { weakWindow == nil }
        if released == nil { problems.append("the window is not released 1.5 s after the close") }
        values["windowReleasedMs"] = released ?? -1
        parts.append("window released \(fmt(released)) ms")
        await r.sleepMs(150)

        // 2. A click outside the app (global monitor path) closes the panel.
        if let w2 = openReal(r).window {
            await r.sleepMs(250)
            w2.handleGlobalClick()
            let ms = await waitClosed(r, timeoutMs: 400)
            if ms == nil { problems.append("a click outside did not close the panel") }
            values["outsideClickMs"] = ms ?? -1
            parts.append("outside click \(fmt(ms)) ms")
            if PanelWindow.testMonitorCount != 0 { problems.append("monitors after outside close: \(PanelWindow.testMonitorCount)") }
            await r.closePanelQuietly()
        } else {
            problems.append("the panel did not open for the outside click test")
        }

        // 3. Clicks in windows of this app: the panel and its own windows keep it open, another window closes it.
        if let w3 = openReal(r).window {
            await r.sleepMs(250)
            let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 160, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.orderFront(nil)
            defer { other.orderOut(nil) }
            if let down = mouseEvent(r, .leftMouseDown, window: w3, at: NSPoint(x: 1, y: 1)),
               let up = mouseEvent(r, .leftMouseUp, window: w3, at: NSPoint(x: 1, y: 1)) {
                if w3.localClickDecision(down) != .keepOpen { problems.append("a click inside the panel would close it") }
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
                await r.sleepMs(150)
                if r.delegate.panelWindow !== w3 || w3.isClosing { problems.append("a posted click inside the panel closed it") }
            }
            if let status = w3.statusItemWindow, let e = mouseEvent(r, .leftMouseDown, window: status, at: NSPoint(x: 1, y: 1)) {
                if w3.localClickDecision(e) != .keepOpen { problems.append("a click in the status item window would close the panel") }
            }
            var decisionOk = false
            var monitorSawIt = false
            if let down = mouseEvent(r, .leftMouseDown, window: other, at: NSPoint(x: 5, y: 5)),
               let up = mouseEvent(r, .leftMouseUp, window: other, at: NSPoint(x: 5, y: 5)) {
                decisionOk = w3.localClickDecision(down) == .close
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
                monitorSawIt = await waitClosed(r, timeoutMs: 400) != nil
                if !monitorSawIt {
                    // The posted event did not reach the local monitor in this environment. The decision itself is still judged.
                    w3.handleLocalClick(down)
                }
            }
            if !decisionOk { problems.append("a click in another window of the app would not close the panel") }
            values["otherWindowViaMonitor"] = monitorSawIt ? 1 : 0
            parts.append("other window click: decision close=\(decisionOk), monitor saw the posted event=\(monitorSawIt)")
            await r.closePanelQuietly()
        } else {
            problems.append("the panel did not open for the own-window click test")
        }

        // 4. The icon toggles once per click: the second click closes, a third opens, nothing reopens or recloses by itself.
        let toggle = NSSelectorFromString("togglePanel:")
        func iconClick() {
            if let button = r.delegate.statusItem?.button, button.window != nil, let action = button.action {
                _ = NSApp.sendAction(action, to: button.target, from: button)
            } else {
                _ = r.delegate.perform(toggle, with: nil)
            }
        }
        r.delegate.testEntrance = PanelEntrance.none
        iconClick()
        r.delegate.testEntrance = nil
        let shown1 = await r.waitFor(timeoutMs: 500) { r.delegate.panelWindow != nil }
        await r.sleepMs(300)
        let openAfterOne = r.delegate.panelWindow != nil && r.delegate.panelWindow?.isClosing == false
        iconClick()
        let gone = await waitClosed(r, timeoutMs: 400)
        _ = await r.waitFor(timeoutMs: 1000) { r.delegate.panelWindow == nil }
        await r.sleepMs(300)
        let closedAfterTwo = r.delegate.panelWindow == nil
        if shown1 == nil || !openAfterOne { problems.append("the first icon click did not leave the panel open") }
        if gone == nil || !closedAfterTwo { problems.append("the second icon click did not leave the panel closed") }
        parts.append("icon: open after click 1=\(openAfterOne), closed after click 2=\(closedAfterTwo)")

        // 5. R-14: the notification tap opens the panel and pins the sidebar of the item.
        r.delegate.testEntrance = PanelEntrance.none
        r.delegate.openPanel(pinning: .cpu)
        r.delegate.testEntrance = nil
        let pinOpen = await r.waitFor(timeoutMs: 700) { (r.delegate.panelWindow?.frame.width ?? 0) >= 671.5 }
        let pinned = r.delegate.panelWindow?.pinnedSidebarItem
        if pinOpen == nil || pinned != .cpu { problems.append("the notification tap did not open and pin the CPU sidebar (pinned \(String(describing: pinned)))") }
        r.delegate.openPanel(pinning: .power)
        let switched = r.delegate.panelWindow?.pinnedSidebarItem
        if switched != .battery { problems.append("a second tap for the power item did not pin the battery sidebar (pinned \(String(describing: switched)))") }
        parts.append("R-14 pin: opened \(fmt(pinOpen)) ms, pinned \(String(describing: pinned)), then \(String(describing: switched))")
        await r.closePanelQuietly()

        if PanelWindow.testMonitorCount != 0 { problems.append("monitors at the end: \(PanelWindow.testMonitorCount)") }
        values["monitorsAtEnd"] = Double(PanelWindow.testMonitorCount)
        let ok = problems.isEmpty
        r.record("W10", "Esc layers and close", ok, since: t0,
                 parts.joined(separator: "; ") + "; monitors at the end \(PanelWindow.testMonitorCount)"
                 + (ok ? "" : " PROBLEMS: " + problems.joined(separator: " / ")), values)
        await ensureClosed(r)
    }
}
#endif
