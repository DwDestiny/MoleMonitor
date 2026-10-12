// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the real panel with fixture models, an own test window for the hero alone,
//        DogSpriteProbe and DogSpriteLibrary (docs/DESIGN_V2.md 4, 11, 13.3).
// Output: W04 action mapping, W11 strips at run time, W12 bubble and dog gap (with the screenshots ui-w12-*.png), W14 main thread work,
//         W15 Reduce Motion, W17 CPU while open (measured in the W14 window), W18 sprite memory, and ui-wpd-items.json (all items so
//         far, rewritten after each check). M20 and M21 (UITestBitmapChecks.swift) reuse the helpers here; W04 reuses the M20 mapping.
// Pos: Test code. It exists only in the UITEST build. Owner WP-D. The gates are pending in scripts/ci_acceptance.py until WP-F
//      activates them, so their results are information. The motion checks force Reduce Motion off (the CI VM reports it on),
//      the RM check forces it on; every check restores the switches and leaves the panel closed.
// UITEST-REGISTER: UITestSpriteChecks

#if UITEST
import AppKit
import SwiftUI

enum UITestSpriteChecks {
    @MainActor static func register(into registry: UITestRegistry) {
        registry.add("W04", "action mapping") { runner in await w04(runner) }
        registry.add("W11", "dog strips at run time") { runner in w11(runner) }
        registry.add("W12", "bubble and dog gap") { runner in await w12(runner) }
        registry.add("W14", "main thread work per frame") { runner in await w14(runner) }
        registry.add("W15", "Reduce Motion") { runner in await w15(runner) }
        registry.add("W17", "CPU while open") { runner in await w17(runner) }
        registry.add("W18", "sprite memory") { runner in await w18(runner) }
    }

    // MARK: Helpers

    @MainActor
    static func motion(_ on: Bool?) {
        DogSpriteProbe.forceReduceMotion = on.map { !$0 }
        PanelWindow.testReduceMotion = on.map { !$0 }
    }

    @MainActor
    static func restore() {
        DogSpriteProbe.forceReduceMotion = nil
        PanelWindow.testReduceMotion = nil
        PanelHero.nightOverride = false
    }

    static func code(_ item: HealthItem, _ level: HealthLevel) -> String {
        switch (item, level) {
        case (.thermal, .red): return "thermal_critical"
        case (.thermal, .yellow): return "thermal_fair"
        case (.memory, .red): return "pressure_critical"
        case (.memory, .yellow): return "pressure_warning"
        case (.power, _): return "awake_drain"
        case (.disk, _): return "low_space"
        case (.cpu, .red): return "cpu_mean_10m"
        case (.cpu, _): return "cpu_mean_5m"
        default: return "ok"
        }
    }

    /// A data point: every item green unless listed, the CPU, the data state, and the clock `seconds` after the base.
    static func point(_ base: PanelData, cpu: Double?, _ levels: [HealthItem: HealthLevel] = [:], state: DataState = .fresh,
                      seconds: Double) -> PanelData {
        var d = base
        d.current.cpuPercent = cpu
        d.current.cpuMean5m = cpu
        d.current.cpuMean10m = cpu
        d.current.memoryPressurePercent = levels[.memory] == .red ? 93 : 40
        d.current.diskAvailable = 60_000_000_000
        d.dataState = state
        d.now = base.now.addingTimeInterval(seconds)
        d.verdicts = d.verdicts.map { v in
            var v = v
            v.level = levels[v.item] ?? .green
            v.reasonCode = code(v.item, v.level)
            v.since = v.level == .green ? nil : d.now.addingTimeInterval(-600)
            return v
        }
        return d
    }

    struct Step {
        var name: String
        var cpu: Double?
        var levels: [HealthItem: HealthLevel] = [:]
        var state: DataState = .fresh
        var night = false
        var action: DogAction
        var variant: DogVariant
    }

    /// Writes every item recorded so far to ui-wpd-items.json (overwritten after each WP-D check), so the results stay in the
    /// artifact also when the runner stops before ui-report.json.
    @MainActor
    static func dump(_ r: UITestRunner) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(r.items) else { return }
        try? data.write(to: r.outDir.appendingPathComponent("ui-wpd-items.json"))
    }

    /// "layer:key" of every animation in the layer tree of the window of a view (W15 names them).
    @MainActor
    static func animationKeys(_ view: NSView) -> [String] {
        guard let root = view.window?.contentView?.superview?.layer ?? view.layer else { return [] }
        var out = [String]()
        func walk(_ layer: CALayer, _ depth: Int) {
            guard out.count < 50, depth < 40 else { return }
            let name = layer.name ?? String(describing: type(of: layer))
            out += (layer.animationKeys() ?? []).map { "\(name):\($0)" }
            for sub in layer.sublayers ?? [] { walk(sub, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /// The last result of runMapping. M20 and W04 run the same 10 points; the second one reuses the first result.
    @MainActor static var lastMapping: (problems: [String], notes: [String], latencies: [Double])?

    /// The 10 data points of W04 (1) and their expected base action and variant (DESIGN_V2.md 4.4).
    static let steps: [Step] = [
        Step(name: "cpu 5", cpu: 5, action: .lieIdle, variant: .normal),
        Step(name: "cpu 25", cpu: 25, action: .walk, variant: .normal),
        Step(name: "cpu 60", cpu: 60, action: .trot, variant: .normal),
        Step(name: "cpu 95", cpu: 95, action: .sprint, variant: .normal),
        Step(name: "thermal red", cpu: 95, levels: [.thermal: .red], action: .pantLie, variant: .normal),
        Step(name: "memory red", cpu: 95, levels: [.memory: .red], action: .walk, variant: .heavy),
        Step(name: "power yellow, cpu 20", cpu: 20, levels: [.power: .yellow], action: .lieIdle, variant: .tired),
        Step(name: "collecting", cpu: nil, state: .collecting, action: .sniff, variant: .normal),
        Step(name: "stale", cpu: nil, state: .stale(Date().addingTimeInterval(-900)), action: .sitGray, variant: .normal),
        Step(name: "night, cpu 5", cpu: 5, night: true, action: .lieIdle, variant: .sleep),
    ]

    /// Runs the 10 points on an open fixture model. Each point is 45 s after the previous one on the data clock.
    @MainActor
    static func runMapping(_ r: UITestRunner, _ model: PanelModel) async -> (problems: [String], notes: [String], latencies: [Double]) {
        var problems = [String]()
        var notes = [String]()
        var latencies = [Double]()
        let base = model.data
        for (i, step) in steps.enumerated() {
            PanelHero.nightOverride = step.night
            model.replace(point(base, cpu: step.cpu, step.levels, state: step.state, seconds: Double(i + 1) * 45))
            let ms = await r.waitFor(timeoutMs: 300) {
                DogSpriteProbe.currentAction == step.action && DogSpriteProbe.variant == step.variant
            }
            let seen = "\(DogSpriteProbe.currentAction?.rawValue ?? "nil")/\(DogSpriteProbe.variant?.rawValue ?? "nil")"
            if let ms {
                latencies.append(ms)
                notes.append("\(step.name) -> \(seen) in \(Int(ms)) ms")
            } else {
                problems.append("\(step.name): shows \(seen) after 300 ms, expected \(step.action.rawValue)/\(step.variant.rawValue)")
            }
            await r.sleepMs(250)
        }
        PanelHero.nightOverride = false
        lastMapping = (problems, notes, latencies)
        return (problems, notes, latencies)
    }

    // MARK: W04

    @MainActor
    static func w04(_ r: UITestRunner) async {
        let t0 = r.now()
        defer { dump(r) }
        let reused = lastMapping != nil
        let result: (problems: [String], notes: [String], latencies: [Double])
        if let last = lastMapping {
            result = last
        } else {
            await r.closePanelQuietly()
            motion(true)
            defer { restore() }
            let copyBox = UITestTextBox()
            guard let model = await r.openFixture(.allGreen, copyBox: copyBox) else {
                r.record("W04", "动作映射与速度连续", false, since: t0, "the panel did not open")
                return
            }
            await r.sleepMs(600)
            result = await runMapping(r, model)
            await r.closeFixture()
        }
        var note = "(1) 10 data points, Reduce Motion forced off" + (reused ? " (the run of M20 in the real panel)" : "") + ": "
        note += result.notes.joined(separator: "; ")
        note += ". (2) the 60 s CPU ramp is the Core test DogActionTests (W04 part 2)."
        note += " Hand-overs so far: \(DogSpriteProbe.delegateSteps) by animationDidStop, \(DogSpriteProbe.guardSteps) by the guard."
        if !result.problems.isEmpty { note += " Failures: " + result.problems.joined(separator: "; ") }
        r.record("W04", "动作映射与速度连续", result.problems.isEmpty, since: t0, note,
                 ["matched": Double(result.latencies.count), "maxMs": result.latencies.max() ?? -1,
                  "delegateSteps": Double(DogSpriteProbe.delegateSteps), "guardSteps": Double(DogSpriteProbe.guardSteps)])
    }

    // MARK: W11

    @MainActor
    static func w11(_ r: UITestRunner) {
        let t0 = r.now()
        // A fresh library, so the shared cache of the panel stays empty.
        let library = DogSpriteLibrary(directory: DogSpriteLibrary.shared.directory)
        var problems = [String]()
        var frames = 0
        var bytes = 0
        if let m = library.manifest {
            for action in DogAction.allCases {
                guard let e = m.action(action) else {
                    problems.append("\(action.rawValue): not in the manifest")
                    continue
                }
                frames += e.frames
                guard let strip = library.strip(action) else {
                    problems.append("\(action.rawValue): the strip does not load")
                    continue
                }
                bytes += strip.bytesPerRow * strip.height
                if strip.width != 320 * e.frames || strip.height != 240 {
                    problems.append("\(action.rawValue): \(strip.width) x \(strip.height) px for \(e.frames) frames")
                }
            }
            for bed in [DogBed.some, .full] where library.prop(bed) == nil { problems.append("\(bed.rawValue): the prop does not load") }
        } else {
            problems.append("no manifest")
        }
        let empty = DogSpriteLibrary(directory: URL(fileURLWithPath: "/nonexistent-dog-sprites", isDirectory: true))
        let fallback = !empty.hasManifest && empty.strip(.walk) == nil && empty.prop(.full) == nil
        if !fallback { problems.append("a missing folder still gives pictures") }
        let stills = DogAction.allCases.filter { empty.still($0) != nil }.count
        var note = "manifest \(library.hasManifest), \(frames) frames in 10 actions (DESIGN_V2.md 4.3 says 57; stand_up has 6 frames, "
        note += "coordinator decision), decoded \(bytes / 1024) KB in all; a missing folder: no strip, no crash, \(stills) of 10 still fallbacks."
        note += " The full W11 is scripts/check_sprites.py (needs Pillow and numpy)."
        if !problems.isEmpty { note += " Failures: " + problems.joined(separator: "; ") }
        r.record("W11", "比熊条带（运行时部分）", problems.isEmpty, since: t0, note,
                 ["frames": Double(frames), "decodedKB": Double(bytes / 1024), "stillFallbacks": Double(stills)])
        dump(r)
    }

    // MARK: W12

    /// Stage points of every pixel with alpha >= 8 in any frame of the 10 actions (one union mask of the 320 x 240 frame).
    static func inkUnion() -> [CGRect] {
        let library = DogSpriteLibrary(directory: DogSpriteLibrary.shared.directory)
        guard let m = library.manifest else { return [] }
        var mask = [Bool](repeating: false, count: 320 * 240)
        for action in DogAction.allCases {
            guard let e = m.action(action) else { continue }
            for i in 0..<e.frames {
                guard let frame = library.frame(action, i), let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 320 * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: 320, height: 240))
                guard let data = ctx.data else { continue }
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                for y in 0..<240 {
                    for x in 0..<320 where bytes[(y * 320 + x) * 4 + 3] >= 8 { mask[y * 320 + x] = true }
                }
            }
        }
        var out = [CGRect]()
        let box = DogStageGeometry.dogBox
        for y in 0..<240 {
            for x in 0..<320 where mask[y * 320 + x] {
                out.append(CGRect(x: box.minX + CGFloat(x) / 2, y: box.minY + CGFloat(y) / 2, width: 0.5, height: 0.5))
            }
        }
        return out
    }

    /// Smallest distance in points between a rectangle and the ink pixels.
    static func gap(_ rect: CGRect, _ ink: [CGRect]) -> Double {
        var best = Double.infinity
        for p in ink {
            let dx = max(0, max(rect.minX - p.maxX, p.minX - rect.maxX))
            let dy = max(0, max(rect.minY - p.maxY, p.minY - rect.maxY))
            best = min(best, Double(hypot(dx, dy)))
        }
        return best
    }

    @MainActor
    static func w12(_ r: UITestRunner) async {
        let t0 = r.now()
        await r.closePanelQuietly()
        motion(false)
        defer { restore(); dump(r) }
        let ink = inkUnion()
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let scenes: [(String, PreviewCase, Bool)] = PreviewCase.allCases.map { ($0.rawValue, $0, false) } + [("night", .allGreen, true)]
        let window = NSWindow(contentRect: NSRect(x: 60, y: 120, width: 360, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var minGap = Double.infinity
        for (name, c, night) in scenes {
            for dark in [false, true] {
                PanelHero.nightOverride = night
                UITestFrameStore.shared.reset()
                let data = PanelModel.fixtureData(c, full: true, now: Date())
                let view = PanelHero(data: data, quiet: data.problems.isEmpty)
                    .padding(16)
                    .environment(\.tok, PanelTokens(scheme: dark ? .dark : .light))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.backgroundColor = NSColor(PanelTokens.surface(dark: dark))
                window.contentView = host
                window.setContentSize(host.fittingSize)
                window.orderFrontRegardless()
                await r.sleepMs(250)
                let key = name + (dark ? ".dark" : ".light")
                guard let stage = UITestFrameStore.shared.get("hero.stage"), let bubble = UITestFrameStore.shared.get("bubble"),
                      let text = UITestFrameStore.shared.get("txt.hero.title") else {
                    problems.append("\(key): no stage, bubble or text frame")
                    continue
                }
                let s = stage.width / DogStageGeometry.size.width
                let local = CGRect(x: (bubble.minX - stage.minX) / s, y: (bubble.minY - stage.minY) / s, width: bubble.width / s,
                                   height: bubble.height / s)
                let g = gap(local, ink) * Double(s)
                minGap = min(minGap, g)
                // The stage text is clamped to 2 lines; a text that needs more shows in the template check below.
                let lines = Int(((text.height / s) + 2.5) / DogStageGeometry.bubbleLine + 0.5)
                values[key + ".gap"] = (g * 10).rounded() / 10
                values[key + ".width"] = Double((local.width * 10).rounded() / 10)
                notes.append("\(key) bubble \(Int(local.width)) x \(Int(local.height)) pt, gap \(String(format: "%.1f", g)) pt, \(lines) lines")
                if g < 4 { problems.append("\(key): gap \(String(format: "%.1f", g)) pt < 4") }
                if local.width > 192 { problems.append("\(key): bubble \(Int(local.width)) pt wide > 192") }
                if lines > 2 { problems.append("\(key): \(lines) lines") }
                // The window server image shows the layers of DogSpriteView; cacheDisplay is the fallback.
                let file = "ui-w12-\(name)-\(dark ? "dark" : "light").png"
                if let cg = r.windowImage(window), let shot = UITestPixels.shot(from: cg, pointWidth: window.frame.width) {
                    r.save(shot, file, dark: dark)
                } else if let shot = r.capture(host) {
                    r.save(shot, file, dark: dark)
                }
            }
        }
        // Every bubble template at its worst value, at scale 1, without the 2-line clamp (DESIGN_V2.md 4.10 rules 1, 2).
        // The line count is the text height against a one-line reference: 2 lines or fewer, and the bubble at most 184 pt wide.
        func measure(_ text: BubbleText) async -> (text: CGRect, bubble: CGRect)? {
            UITestFrameStore.shared.reset()
            let probe = HStack(spacing: 0) {
                HeroBubble(text: text, scale: 1, tokens: HeroTokens(dark: false, night: false), maxLines: nil).uiTestFrame("w12.bubble")
                Spacer(minLength: 0)
            }
            .frame(width: DogStageGeometry.bubbleMaxWidth)
            .padding(12)
            .environment(\.tok, PanelTokens(scheme: .light))
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: probe)
            window.setContentSize(NSSize(width: 220, height: 140))
            await r.sleepMs(80)
            guard let t = UITestFrameStore.shared.get("txt.hero.title"), let b = UITestFrameStore.shared.get("w12.bubble") else { return nil }
            return (t, b)
        }
        var worstLines = 0
        var templateProblems = [String]()
        let one = await measure(BubbleText(main: "一"))
        let two = await measure(BubbleText(main: String(repeating: "一", count: 20)))
        let lineHeight = one?.text.height ?? 0
        let pitch = (two?.text.height ?? 0) - lineHeight
        if lineHeight <= 0 || pitch <= 0 { templateProblems.append("no line reference (one \(lineHeight), pitch \(pitch))") }
        for (i, t) in BubbleCopy.allTemplates.enumerated() where lineHeight > 0 && pitch > 0 {
            guard let m = await measure(t.text) else {
                templateProblems.append("\(i) \(t.name): no frame")
                continue
            }
            let lines = 1 + Int(((m.text.height - lineHeight) / pitch).rounded())
            worstLines = max(worstLines, lines)
            if lines > 2 || m.bubble.width > DogStageGeometry.bubbleMaxWidth + 0.5 {
                templateProblems.append("\(i) \(t.name): \(lines) lines, \(Int(m.bubble.width)) pt wide")
            }
        }
        window.orderOut(nil)
        window.contentView = nil
        problems += templateProblems
        var note = "8 scenes x light and dark, gap from the bubble box (with its tail) to the ink (alpha >= 8) of all frames of the 10 actions; "
        note += notes.joined(separator: "; ")
        note += ". Templates: \(BubbleCopy.allTemplates.count) at their worst values, unclamped, most lines \(worstLines) (limit 2),"
        note += " line height \(String(format: "%.1f", lineHeight)) pt, pitch \(String(format: "%.1f", pitch)) pt."
        if !problems.isEmpty { note += " Failures: " + problems.joined(separator: "; ") }
        values["minGap"] = (minGap * 10).rounded() / 10
        values["templateMaxLines"] = Double(worstLines)
        r.record("W12", "气泡与比熊间距", problems.isEmpty && notes.count == 16, since: t0, note, values)
    }

    // MARK: W14 and W17

    /// Keeps the fixture model live: a new data point every 2 s, as the open panel samples (the CPU moves by a few percent).
    @MainActor @discardableResult
    static func feed(_ r: UITestRunner, _ model: PanelModel, base: PanelData, cpu: Double, seconds: Double) async -> Int {
        let t0 = r.now()
        var i = 0
        while r.now() - t0 < seconds {
            i += 1
            model.replace(point(base, cpu: cpu + Double(i % 3), seconds: Double(i) * 2))
            await r.sleepMs(2000)
        }
        return i
    }

    /// W17 is measured in the W14 window (one 10 s run at the highest step rate); W17 records this result.
    @MainActor static var lastCpu: (share: Double, action: String)?

    @MainActor
    static func w14(_ r: UITestRunner) async {
        let t0 = r.now()
        await r.closePanelQuietly()
        motion(true)
        defer { restore(); dump(r) }
        let copyBox = UITestTextBox()
        guard let model = await r.openFixture(.allGreen, copyBox: copyBox) else {
            r.record("W14", "主线程每帧工作", false, since: t0, "the panel did not open")
            return
        }
        let base = point(model.data, cpu: 95, seconds: 0)
        model.replace(base)
        await r.sleepMs(1500)
        DogSpriteProbe.reset()
        let cpu0 = r.cpuSeconds(), wall0 = r.now()
        let samples = await feed(r, model, base: base, cpu: 95, seconds: 10)
        let share = (r.cpuSeconds() - cpu0) / max(0.001, r.now() - wall0) * 100
        let bodies = DogSpriteProbe.heroBodies
        let draws = DogSpriteProbe.updateLayers
        let action = DogSpriteProbe.currentAction?.rawValue ?? "nil"
        lastCpu = (share, action)
        await r.closeFixture()
        // "at most one body evaluation per 2 s, with the live samples" (13.3): at most one per data point.
        let ok = bodies <= samples && draws == 0
        r.record("W14", "主线程每帧工作", ok, since: t0,
                 "10 s open with a data point every 2 s (\(action)): \(bodies) hero body evaluations for \(samples) data points "
                     + "(limit one per point), \(draws) updateLayer calls of "
                     + "DogSpriteView (limit 0). The frames run in Core Animation; the source audit of DogSpriteView.swift is WP-F's.",
                 ["heroBodies": Double(bodies), "samples": Double(samples), "updateLayer": Double(draws)])
    }

    @MainActor
    static func w17(_ r: UITestRunner) async {
        let t0 = r.now()
        defer { dump(r) }
        if lastCpu == nil { await w14Window(r) }
        guard let cpu = lastCpu else {
            r.record("W17", "打开时 CPU", false, since: t0, "the panel did not open")
            return
        }
        r.record("W17", "打开时 CPU", cpu.share <= 3, since: t0,
                 "10 s steady state with the panel open (the W14 window), \(cpu.action) at the highest step rate, a data point every 2 s: "
                     + "process CPU " + String(format: "%.2f", cpu.share) + " % (limit 3 %). VM numbers do not prove the real Mac (11.4).",
                 ["processCpuPercent": (cpu.share * 100).rounded() / 100])
    }

    /// The W14 window without a W14 record, for a run that has W17 without W14.
    @MainActor
    private static func w14Window(_ r: UITestRunner) async {
        await r.closePanelQuietly()
        motion(true)
        defer { restore() }
        let copyBox = UITestTextBox()
        guard let model = await r.openFixture(.allGreen, copyBox: copyBox) else { return }
        let base = point(model.data, cpu: 95, seconds: 0)
        model.replace(base)
        await r.sleepMs(1500)
        let cpu0 = r.cpuSeconds(), wall0 = r.now()
        await feed(r, model, base: base, cpu: 95, seconds: 10)
        lastCpu = ((r.cpuSeconds() - cpu0) / max(0.001, r.now() - wall0) * 100, DogSpriteProbe.currentAction?.rawValue ?? "nil")
        await r.closeFixture()
    }

    // MARK: W15

    @MainActor
    static func w15(_ r: UITestRunner) async {
        let t0 = r.now()
        await r.closePanelQuietly()
        defer { restore(); dump(r) }
        var counts = [Bool: (dog: Int, panel: Int)]()
        var rmKeys = [String]()
        for reduce in [true, false] {
            motion(!reduce)
            let copyBox = UITestTextBox()
            guard let model = await r.openFixture(.allGreen, copyBox: copyBox) else { continue }
            model.replace(point(model.data, cpu: 60, [.thermal: .yellow], seconds: 45))
            await r.sleepMs(1500)
            let dog = DogSpriteProbe.view?.animationCount ?? -1
            let panel = r.hostView.map { r.layerSignature($0).animated } ?? -1
            if reduce, let host = r.hostView { rmKeys = animationKeys(host) }
            counts[reduce] = (dog, panel)
            await r.closeFixture()
        }
        let still = counts[true], moving = counts[false]
        let left: String = rmKeys.isEmpty ? "" : " Animations left under RM: " + rmKeys.joined(separator: ", ")
        let ok = still?.dog == 0 && still?.panel == 0 && (moving?.dog ?? 0) > 0
        r.record("W15", "RM", ok, since: t0,
                 "trot with sweat, steady state after 1.5 s. Reduce Motion forced on: \(still?.dog ?? -1) animations on the dog layers, "
                     + "\(still?.panel ?? -1) in the whole panel window (limit 0). Control, motion on: \(moving?.dog ?? -1) on the dog, "
                     + "\(moving?.panel ?? -1) in the panel (needs > 0). The bubble pop is a SwiftUI keyframe with a fixed trigger under RM."
                     + left,
                 ["rmDog": Double(still?.dog ?? -1), "rmPanel": Double(still?.panel ?? -1), "motionDog": Double(moving?.dog ?? -1),
                  "motionPanel": Double(moving?.panel ?? -1)])
    }

    // MARK: W18

    @MainActor
    static func w18(_ r: UITestRunner) async {
        let t0 = r.now()
        await r.closePanelQuietly()
        motion(true)
        defer { restore(); dump(r) }
        let copyBox = UITestTextBox()
        guard let model = await r.openFixture(.allGreen, copyBox: copyBox) else {
            r.record("W18", "精灵内存", false, since: t0, "the panel did not open")
            return
        }
        let base = model.data
        var peak = 0
        var seen = Set<DogAction>()
        var log = [String]()
        func watch(_ ms: Double) async {
            let end = r.now() + ms / 1000
            while r.now() < end {
                if let a = DogSpriteProbe.view?.screenAction { seen.insert(a) }
                peak = max(peak, DogSpriteLibrary.shared.cachedBytes)
                await r.sleepMs(40)
            }
        }
        // The wait of each step covers the end of the previous loop (lie_idle 1.5 s, walk 1 s) and the one-shot before it.
        let plan: [(String, PanelData?, Double)] = [
            ("lie", point(base, cpu: 5, seconds: 45), 600),
            ("walk", point(base, cpu: 25, seconds: 90), 2200),
            ("trot", point(base, cpu: 60, seconds: 135), 1300),
            ("sprint", point(base, cpu: 95, seconds: 180), 1000),
            ("notice", point(base, cpu: 95, [.disk: .yellow], seconds: 225), 1600),
            ("wag", nil, 1200),
            ("pant", point(base, cpu: 95, [.disk: .yellow, .thermal: .red], seconds: 270), 1600),
            ("sniff", point(base, cpu: nil, state: .collecting, seconds: 315), 1300),
            ("gray", point(base, cpu: nil, state: .stale(Date().addingTimeInterval(-900)), seconds: 360), 1300),
        ]
        for (name, data, wait) in plan {
            if let data {
                model.replace(data)
            } else {
                DogSpriteProbe.view?.onTap?()
            }
            await watch(wait)
            log.append("\(name) \(DogSpriteLibrary.shared.cachedBytes / 1024) KB")
        }
        let final = DogSpriteLibrary.shared.cachedBytes
        await r.closeFixture()
        await r.sleepMs(300)
        let afterClose = DogSpriteLibrary.shared.cachedBytes
        let budget = DogSpriteLibrary.budgetBytes
        let names = DogAction.allCases.filter { seen.contains($0) }.map(\.rawValue)
        let ok = peak <= budget && final <= budget && seen.count == DogAction.allCases.count
        var note = "actions on screen \(seen.count) of 10 (\(names.joined(separator: ","))); cache after each step: \(log.joined(separator: ", ")); "
        note += "peak \(peak / 1024) KB, end \(final / 1024) KB (limit \(budget / 1024) KB); after close \(afterClose) bytes (W16 needs 0). "
        note += "Hand-overs \(DogSpriteProbe.delegateSteps) by animationDidStop, \(DogSpriteProbe.guardSteps) by the guard."
        r.record("W18", "精灵内存", ok, since: t0, note,
                 ["peakKB": Double(peak / 1024), "endKB": Double(final / 1024), "afterCloseBytes": Double(afterClose),
                  "actionsSeen": Double(seen.count)])
    }
}
#endif
