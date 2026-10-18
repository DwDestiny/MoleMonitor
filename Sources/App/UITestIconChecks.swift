// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the fixtures of PanelModel.fixtureData, AppDelegate's status item,
//        MenuRunnerRenderer and StatusIconController.
// Output: Gate W08 (the five states: model table, applied state, text, not template, width, body ink and mark color under
//         forced light and dark), gate W29 (stand 1 frame and run 4 frames on one canvas, light and dark not empty, marks
//         present, run frames differ, mark box clear; writes the contact sheet ui-icon-sheet.png) and gate W30 (run start
//         and stop by CPU ticks with hysteresis, speed tiers, one timer while running, 0 icon timers under Reduce Motion,
//         locked screen, sleeping display, hidden icon, Low Power Mode, collecting). Helper of gate A: `headInkCheck`.
// Pos: Test code. It exists only in the UITEST build (`#if UITEST`). scripts/build.py finds the marker line below and
//      registers `UITestIconChecks.register` in the generated `uiTestRegisterAll`. Owner P-icon (v3, docs/DESIGN_V3.md 4.2).
//
// UITEST-REGISTER: UITestIconChecks

#if UITEST
import AppKit
import Foundation

@MainActor
enum UITestIconChecks {
    static func register(into registry: UITestRegistry) {
        registry.add("W08", "menu bar five states") { runner in await runner.stepIconFiveStates() }
        registry.add("W29", "menu bar runner frames") { runner in await runner.stepRunnerFrames() }
        registry.add("W30", "menu bar runner trigger and timer") { runner in await runner.stepRunnerTrigger() }
    }

    /// One W08 scenario: the input and the expected icon, written by hand (not computed by MenuIconModel).
    struct Scenario {
        var name: String
        var verdicts: [ItemVerdict]
        var dataState: DataState
        var kind: MenuIconKind
        var posture: MenuPosture
        var badge: HealthItem?
        var mark: MenuMark?
        /// The label must start with this text (DESIGN_V2.md 9.2), or contain it for more than one problem.
        var label: String
        var labelIsPrefix = true
    }

    /// The 9 scenarios: the 7 fixtures of PreviewScenario plus memory yellow and thermal red.
    static func scenarios(now: Date) -> [Scenario] {
        func verdicts(_ c: PreviewCase) -> [ItemVerdict] { PanelModel.fixtureData(c, full: true, now: now).verdicts }
        func one(_ item: HealthItem, _ level: HealthLevel) -> [ItemVerdict] {
            verdicts(.allGreen).map { v in
                guard v.item == item else { return v }
                var p = v
                p.level = level
                p.since = now.addingTimeInterval(-600)
                return p
            }
        }
        return [
            Scenario(name: "allGreen", verdicts: verdicts(.allGreen), dataState: .fresh, kind: .normal, posture: .relaxed,
                     badge: nil, mark: nil, label: "MoleMonitor：一切正常"),
            Scenario(name: "cpuYellow", verdicts: verdicts(.cpuYellow), dataState: .fresh, kind: .caution, posture: .raised,
                     badge: .cpu, mark: nil, label: "MoleMonitor：CPU 需要留意"),
            Scenario(name: "powerYellow", verdicts: verdicts(.powerYellow), dataState: .fresh, kind: .caution, posture: .raised,
                     badge: .power, mark: nil, label: "MoleMonitor：耗电需要留意"),
            Scenario(name: "memoryYellow", verdicts: one(.memory, .yellow), dataState: .fresh, kind: .caution, posture: .raised,
                     badge: .memory, mark: nil, label: "MoleMonitor：内存需要留意"),
            Scenario(name: "diskRed", verdicts: verdicts(.diskRed), dataState: .fresh, kind: .alert, posture: .pant,
                     badge: .disk, mark: nil, label: "MoleMonitor：磁盘异常"),
            Scenario(name: "thermalRed", verdicts: one(.thermal, .red), dataState: .fresh, kind: .alert, posture: .pant,
                     badge: .thermal, mark: nil, label: "MoleMonitor：温度异常"),
            Scenario(name: "multi", verdicts: verdicts(.multi), dataState: .fresh, kind: .alert, posture: .pant,
                     badge: .disk, mark: nil, label: "磁盘异常", labelIsPrefix: false),
            Scenario(name: "collecting", verdicts: verdicts(.collecting), dataState: .collecting, kind: .collecting,
                     posture: .hollow, badge: nil, mark: .collecting, label: "MoleMonitor：正在采集"),
            Scenario(name: "stale", verdicts: verdicts(.stale), dataState: .stale(now.addingTimeInterval(-25 * 60)), kind: .stale,
                     posture: .hollow, badge: nil, mark: .stale, label: "MoleMonitor：数据已过期"),
        ]
    }

    /// RGBA bytes (premultiplied, sRGB) of an image drawn under an appearance, row 0 at the top.
    struct Raster {
        var width: Int
        var height: Int
        var bytes: [UInt8]
        var cgImage: CGImage?

        func alpha(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * width + x) * 4 + 3]) / 255 }
        /// Unpremultiplied RGB (0 to 255) and alpha (0 to 255) of one pixel.
        func color(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            let a = Double(bytes[i + 3])
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(bytes[i]) * 255 / a, Double(bytes[i + 1]) * 255 / a, Double(bytes[i + 2]) * 255 / a, a)
        }
        /// Alpha grid of the whole image (for IconMetrics.xorRatio).
        var alphaGrid: [[Double]] { (0..<height).map { y in (0..<width).map { x in alpha(x, y) } } }
        var solidCount: Int { alphaGrid.joined().filter { $0 >= IconMetrics.solidThreshold }.count }
    }

    /// Draws `image` at `scale` with `appearance` as the current drawing appearance (as the status bar button does).
    @MainActor static func render(_ image: NSImage, appearance: NSAppearance, scale: Int) -> Raster? {
        let w = Int(image.size.width) * scale, h = Int(image.size.height) * scale
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let cg = ctx.makeImage(), let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let row = cg.bytesPerRow
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<(w * 4) { bytes[y * w * 4 + x] = p[y * row + x] }
        }
        return Raster(width: w, height: h, bytes: bytes, cgImage: cg)
    }

    static let light = NSAppearance(named: .aqua)!
    static let dark = NSAppearance(named: .darkAqua)!

    /// Gate A and W08: the body of the icon has the menu bar text color. In the columns x < 14 pt, the pixels at the
    /// largest alpha must equal `labelColor` of the appearance: RGB and alpha each within 8 (0 to 255), in light and in
    /// dark, at 2x. Returns the worst channel difference.
    @MainActor static func headInkCheck(_ image: NSImage) -> (ok: Bool, worst: Double, note: String) {
        var worst = 0.0
        var notes = [String]()
        for (name, appearance) in [("light", light), ("dark", dark)] {
            guard let r = render(image, appearance: appearance, scale: 2) else {
                return (false, 255, "\(name): cannot render")
            }
            let want = MenuIconInk.labelColor(appearance)
            let c = want.components ?? [0, 0, 0, 1]
            let wr = Double(c.count >= 3 ? c[0] : c[0]) * 255, wg = Double(c.count >= 3 ? c[1] : c[0]) * 255
            let wb = Double(c.count >= 3 ? c[2] : c[0]) * 255, wa = Double(want.alpha) * 255
            var maxA = 0.0
            for y in 0..<r.height { for x in 0..<(14 * 2) { maxA = max(maxA, r.color(x, y).a) } }
            var n = 0
            var diff = 0.0
            for y in 0..<r.height {
                for x in 0..<(14 * 2) {
                    let p = r.color(x, y)
                    guard p.a >= maxA - 2, p.a > 0 else { continue }
                    n += 1
                    diff = max(diff, abs(p.r - wr), abs(p.g - wg), abs(p.b - wb))
                }
            }
            diff = max(diff, abs(maxA - wa))
            worst = max(worst, diff)
            notes.append("\(name) body px \(n) diff \(Int(diff.rounded()))")
            if n < 40 { worst = 255 }
        }
        return (worst <= IconMetrics.headInkTolerance, worst, notes.joined(separator: ", "))
    }

    /// The mark box in px at `scale`.
    static func markBox(scale: Int) -> (x: Range<Int>, y: Range<Int>) {
        let k = Double(scale)
        let x0 = Int((MenuRunnerArt.markOrigin.x * k).rounded(.down)), y0 = Int((MenuRunnerArt.markOrigin.y * k).rounded(.down))
        let x1 = min(Int((MenuRunnerArt.markOrigin.x + MenuRunnerArt.markSize) * k), 24 * scale)
        let y1 = min(Int((MenuRunnerArt.markOrigin.y + MenuRunnerArt.markSize) * k), 18 * scale)
        return (x0..<x1, y0..<y1)
    }

    /// W08 and W29: the full-alpha pixels in the mark box have the token color of the appearance (each channel within
    /// 8), light and dark, 1x and 2x. Returns the worst difference and the count of mark pixels.
    @MainActor static func markColorCheck(_ image: NSImage, kind: MenuIconKind) -> (ok: Bool, worst: Double, note: String) {
        guard let token = kind.badgeToken else { return (true, 0, "no colored mark") }
        var worst = 0.0
        var notes = [String]()
        for (name, appearance, isDark) in [("light", light, false), ("dark", dark, true)] {
            let hex = MenuIconPalette.hex(token, dark: isDark)
            let want = (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
            for scale in [1, 2] {
                guard let r = render(image, appearance: appearance, scale: scale) else { return (false, 255, "cannot render") }
                let box = markBox(scale: scale)
                var n = 0
                var diff = 0.0
                for y in box.y {
                    for x in box.x {
                        let p = r.color(x, y)
                        guard p.a >= 250 else { continue }
                        n += 1
                        diff = max(diff, abs(p.r - want.0), abs(p.g - want.1), abs(p.b - want.2))
                    }
                }
                if n < 6 * scale * scale { diff = 255 }
                worst = max(worst, diff)
                notes.append("\(name)@\(scale)x px \(n) diff \(Int(diff.rounded()))")
            }
        }
        return (worst <= IconMetrics.headInkTolerance, worst, notes.joined(separator: ", "))
    }

    /// Pixels with alpha >= 0.5 inside the mark box (any color).
    static func markPixels(_ r: Raster, scale: Int) -> Int {
        let box = markBox(scale: scale)
        var n = 0
        for y in box.y { for x in box.x where r.alpha(x, y) >= 0.5 { n += 1 } }
        return n
    }

    /// The contact sheet (W29): one row on the light reference bar, one on the dark; each cell is a 2x render of the
    /// real NSImage under that appearance, enlarged 4 times (8 px per pt), nearest neighbour. Cells: stand, run 1 to 4,
    /// stand with the yellow triangle, run 2 with the red square, collecting, stale.
    static func contactSheet(cells: [(MenuRunPose, MenuIconKind)], images: (MenuRunPose, MenuIconKind) -> NSImage) -> Data? {
        let zoom = 4, scale = 2, gap = 24, pad = 24
        let cw = 24 * scale * zoom, ch = 18 * scale * zoom
        let width = pad * 2 + cells.count * cw + (cells.count - 1) * gap
        let height = (ch + pad * 2) * 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        for (row, (appearance, isDark)) in [(light, false), (dark, true)].enumerated() {
            let bar = MenuIconPalette.bar(dark: isDark)
            let y0 = height - (row + 1) * (ch + pad * 2)   // CG y up: row 0 on top
            ctx.setFillColor(MenuIconInk.hex(bar))
            ctx.fill(CGRect(x: 0, y: y0, width: width, height: ch + pad * 2))
            for (i, cell) in cells.enumerated() {
                guard let r = render(images(cell.0, cell.1), appearance: appearance, scale: scale), let cg = r.cgImage else { continue }
                let x = pad + i * (cw + gap)
                ctx.draw(cg, in: CGRect(x: x, y: y0 + pad, width: cw, height: ch))
            }
        }
        guard let sheet = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])
    }
}

extension UITestRunner {
    /// W08: the menu bar five states (DESIGN_V2.md 9.2, DESIGN_V3.md 4.2). The engine is held back while this runs.
    func stepIconFiveStates() async {
        let t0 = now()
        delegate.suspendIconUpdates = true
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let button = delegate.statusItem?.button
        var worstHead = 0.0, worstMark = 0.0
        let scenarios = UITestIconChecks.scenarios(now: Date())
        for s in scenarios {
            // (1) The model gives the expected state.
            let model = MenuIconModel.state(s.verdicts, dataState: s.dataState)
            let modelKind = MenuIconModel.kind(s.verdicts, dataState: s.dataState)
            if model.posture != s.posture || model.badge?.item != s.badge || model.mark != s.mark || model.kind != s.kind
                || modelKind != s.kind {
                problems.append("\(s.name): model gives \(model.kind.rawValue) \(model.posture.rawValue)/\(model.badge?.item.rawValue ?? "-")/\(model.mark?.rawValue ?? "-")")
            }
            // (2) The app applies it to the status item.
            delegate.suspendIconUpdates = false
            delegate.applyMenuIcon(verdicts: s.verdicts, dataState: s.dataState)
            delegate.suspendIconUpdates = true
            let applied = delegate.menuIconState
            if applied != model { problems.append("\(s.name): the app applied a different state") }
            let text = MenuIconModel.text(s.verdicts, dataState: s.dataState, now: Date())
            let labelOK = s.labelIsPrefix ? text.hasPrefix(s.label) : (text.hasPrefix("MoleMonitor：") && text.contains(s.label))
            if !labelOK { problems.append("\(s.name): label \"\(text)\" does not match \"\(s.label)\"") }
            let image: NSImage
            if let button, let shown = button.image {
                image = shown
                // The app's own icon does not run in the UI test build, so the text has no busy suffix.
                if button.toolTip != text { problems.append("\(s.name): tooltip differs from the icon text") }
                if (button.accessibilityLabel() ?? "") != text { problems.append("\(s.name): accessibility label differs") }
            } else {
                image = delegate.iconController.image(for: model)
                notes.append("\(s.name): no button image here, controller image used")
            }
            // (3) Not a template (v3), width 24 pt.
            if image.isTemplate { problems.append("\(s.name): the image is a template") }
            if abs(Double(image.size.width) - 24) > 0.01 { problems.append("\(s.name): width \(image.size.width) pt") }
            // (4) Body ink and mark color under forced light and dark.
            var line = "\(s.name)=\(s.kind.rawValue)"
            if s.mark == nil {
                let head = UITestIconChecks.headInkCheck(image)
                worstHead = max(worstHead, head.worst)
                if !head.ok { problems.append("\(s.name): body ink \(head.note)") }
                line += " body \(Int(head.worst.rounded()))"
            }
            if s.kind.badgeToken != nil {
                let mark = UITestIconChecks.markColorCheck(image, kind: s.kind)
                worstMark = max(worstMark, mark.worst)
                if !mark.ok { problems.append("\(s.name): mark color \(mark.note)") }
                line += " mark \(Int(mark.worst.rounded()))"
            }
            notes.append(line)
        }
        // Mark contrast against the reference bars.
        var minContrast = Double.infinity
        for token in MenuIconPalette.Token.allCases {
            for isDark in [false, true] {
                minContrast = min(minContrast, IconMetrics.contrast(MenuIconPalette.hex(token, dark: isDark), MenuIconPalette.bar(dark: isDark)))
            }
        }
        if minContrast < IconMetrics.badgeContrastPass { problems.append("mark contrast \(String(format: "%.2f", minContrast)) < 3") }

        delegate.suspendIconUpdates = false
        delegate.applyMenuIcon(verdicts: engine.verdicts, dataState: engine.dataState)
        values["scenarios"] = Double(scenarios.count)
        values["markMinContrast"] = (minContrast * 100).rounded() / 100
        values["bodyInkWorst"] = worstHead
        values["markColorWorst"] = worstMark
        values["problems"] = Double(problems.count)
        var note = notes.joined(separator: ", ") + String(format: "; contrast min %.2f", minContrast)
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("W08", "菜单栏五态", problems.isEmpty, since: t0, note, values)
    }

    /// W29: stand 1 frame and run 4 frames on one 24 x 18 pt canvas; light and dark not empty; the marks present in every
    /// frame and in their colors; the run frames differ pairwise in the leg band; the mark box clear of the dog in the
    /// normal frames. Writes ui-icon-sheet.png.
    func stepRunnerFrames() async {
        let t0 = now()
        var problems = [String]()
        var values = [String: Double]()
        let controller = StatusIconController(statusItem: nil)
        func img(_ p: MenuRunPose, _ k: MenuIconKind) -> NSImage { controller.image(p, kind: k) }
        var minSolid = Int.max
        var legGrids = [(String, [[Double]])]()
        for pose in MenuRunPose.all {
            for kind in [MenuIconKind.normal, .caution, .alert] {
                let image = img(pose, kind)
                if abs(image.size.width - 24) > 0.01 || abs(image.size.height - 18) > 0.01 {
                    problems.append("\(pose)/\(kind.rawValue): size \(image.size)")
                }
                if image.isTemplate { problems.append("\(pose)/\(kind.rawValue): template") }
                for (name, appearance) in [("light", UITestIconChecks.light), ("dark", UITestIconChecks.dark)] {
                    guard let r = UITestIconChecks.render(image, appearance: appearance, scale: 2) else {
                        problems.append("\(pose)/\(kind.rawValue)/\(name): cannot render")
                        continue
                    }
                    minSolid = min(minSolid, r.solidCount)
                    if r.solidCount < 400 { problems.append("\(pose)/\(kind.rawValue)/\(name): \(r.solidCount) solid px at 2x") }
                    let inBox = UITestIconChecks.markPixels(r, scale: 2)
                    if kind == .normal, inBox > 0 { problems.append("\(pose)/\(name): \(inBox) dog px in the mark box") }
                    if kind != .normal, inBox < 40 { problems.append("\(pose)/\(kind.rawValue)/\(name): mark has \(inBox) px") }
                    if kind == .normal, name == "light" { legGrids.append((pose.description, Array(r.alphaGrid[28..<36]))) }
                }
                if kind != .normal {
                    let c = UITestIconChecks.markColorCheck(image, kind: kind)
                    if !c.ok { problems.append("\(pose)/\(kind.rawValue): mark color \(c.note)") }
                }
            }
        }
        // Data states: hollow stand frame with its mark, both appearances.
        for kind in [MenuIconKind.collecting, .stale] {
            for appearance in [UITestIconChecks.light, UITestIconChecks.dark] {
                guard let r = UITestIconChecks.render(img(.stand, kind), appearance: appearance, scale: 2) else { continue }
                if UITestIconChecks.markPixels(r, scale: 2) < 10 { problems.append("\(kind.rawValue): no data mark") }
                if r.solidCount < 150 { problems.append("\(kind.rawValue): hollow outline has \(r.solidCount) px") }
            }
        }
        let runOnly = legGrids.filter { $0.0 != "stand" }
        let m = IconMetrics.matrix(runOnly)
        if m.minimum < 0.30 { problems.append(String(format: "run frames leg band min XOR %.3f < 0.30", m.minimum)) }
        let cells: [(MenuRunPose, MenuIconKind)] = [(.stand, .normal)] + MenuRunPose.runFrames.map { ($0, .normal) }
            + [(.stand, .caution), (.run(1), .alert), (.stand, .collecting), (.stand, .stale)]
        if let png = UITestIconChecks.contactSheet(cells: cells, images: img) {
            do { try png.write(to: outDir.appendingPathComponent("ui-icon-sheet.png")) } catch { problems.append("sheet: \(error)") }
        } else {
            problems.append("sheet: cannot draw")
        }
        values["minSolid2x"] = Double(minSolid)
        values["runLegMinXOR"] = (m.minimum * 1000).rounded() / 1000
        values["problems"] = Double(problems.count)
        var note = String(format: "min solid px %d, run leg band min XOR %.3f", minSolid, m.minimum)
        if !problems.isEmpty { note += "; failures: " + problems.prefix(12).joined(separator: "; ") }
        record("W29", "菜单栏奔跑帧", problems.isEmpty, since: t0, note, values)
    }

    /// W30: the run trigger by CPU ticks and the timer rule (DESIGN_V3.md 4.2, AGENTS.md).
    func stepRunnerTrigger() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: [.borderless], backing: .buffered, defer: true)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 18))
        host.contentView?.addSubview(button)
        let controller = StatusIconController(statusItem: nil)
        controller.fallbackButton = button
        var conditions = MenuMotionConditions()
        controller.conditionsOverride = { conditions }
        var frames = [Int]()
        controller.onImage = { frames.append($0) }
        let normal = MenuIconState(posture: .relaxed, badge: nil)
        controller.apply(normal, text: "MoleMonitor：一切正常。")
        func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }

        expect(controller.timerCount == 0, "standing at start: \(controller.timerCount) timers")
        controller.cpuTick(30)
        expect(controller.timerCount == 0, "30 %: \(controller.timerCount) timers")
        controller.cpuTick(40)
        expect(controller.timerCount == 1, "40 %: \(controller.timerCount) timers, want 1")
        expect(abs((controller.frameInterval ?? 0) - 0.25) < 1e-6, "40 %: interval \(controller.frameInterval ?? -1)")
        expect(abs((controller.timerTolerance ?? 0) - 0.05) < 1e-6, "40 %: tolerance \(controller.timerTolerance ?? -1)")
        expect(button.toolTip == "MoleMonitor：一切正常，CPU 占用高。", "busy text: \(button.toolTip ?? "nil")")
        frames = []
        await sleepMs(1100)
        let window = frames
        let seen = Set(window.filter { $0 > 0 })
        expect(seen.count >= 3, "4 fps for 1.1 s showed frames \(window)")
        values["framesIn1100ms"] = Double(window.count)
        controller.cpuTick(70)
        expect(abs((controller.frameInterval ?? 0) - 1.0 / 6) < 1e-6, "70 %: interval \(controller.frameInterval ?? -1)")
        controller.cpuTick(90)
        expect(abs((controller.frameInterval ?? 0) - 0.125) < 1e-6, "90 %: interval \(controller.frameInterval ?? -1)")
        expect(controller.timerCount == 1, "retime keeps one timer: \(controller.timerCount)")
        // Hysteresis: one calm tick keeps running, a tick at 30 % resets, two calm ticks in a row stop.
        controller.cpuTick(20)
        expect(controller.timerCount == 1, "one tick < 25 % stopped the run")
        controller.cpuTick(30)
        controller.cpuTick(20)
        expect(controller.timerCount == 1, "calm count not reset by 30 %")
        controller.cpuTick(20)
        expect(controller.timerCount == 0, "two ticks < 25 %: \(controller.timerCount) timers, want 0")
        expect(button.toolTip == "MoleMonitor：一切正常。", "text after stop: \(button.toolTip ?? "nil")")
        expect(frames.last == 0, "stand frame after stop")

        // Each condition alone: 0 icon timers, stand frame; clearing it brings the run back.
        controller.cpuTick(90)
        let names = ["reduceMotion", "screenLocked", "displayAsleep", "iconHidden", "lowPower"]
        var zero = 0
        for (i, name) in names.enumerated() {
            conditions = MenuMotionConditions()
            switch i {
            case 0: conditions.reduceMotion = true
            case 1: conditions.screenLocked = true
            case 2: conditions.displayAsleep = true
            case 3: conditions.iconVisible = false
            default: conditions.lowPower = true
            }
            controller.refresh()
            if controller.timerCount == 0 && frames.last == 0 { zero += 1 } else { problems.append("\(name): \(controller.timerCount) timers") }
            expect(button.toolTip == "MoleMonitor：一切正常。", "\(name): text while still: \(button.toolTip ?? "nil")")
            conditions = MenuMotionConditions()
            controller.refresh()
            expect(controller.timerCount == 1, "\(name) cleared: \(controller.timerCount) timers")
        }
        // Collecting and stale never run.
        controller.apply(MenuIconState(posture: .hollow, badge: nil, mark: .collecting), text: "MoleMonitor：正在采集。")
        expect(controller.timerCount == 0, "collecting while busy: \(controller.timerCount) timers")
        expect(button.toolTip == "MoleMonitor：正在采集。", "collecting text: \(button.toolTip ?? "nil")")
        // A health mark keeps the run.
        controller.apply(MenuIconState(posture: .pant, badge: MenuBadge(item: .disk)), text: "MoleMonitor：磁盘异常。")
        expect(controller.timerCount == 1, "red mark while busy: \(controller.timerCount) timers")
        controller.cpuTick(10)
        controller.cpuTick(10)
        expect(controller.timerCount == 0, "end: \(controller.timerCount) timers")
        // The app's own icon in the UI test build: no icon timer.
        expect(delegate.iconController.timerCount == 0, "app icon: \(delegate.iconController.timerCount) timers")
        values["conditionsWithZeroTimers"] = Double(zero)
        values["problems"] = Double(problems.count)
        notes.append("frames in 1.1 s at 4 fps \(window.count) \(window), conditions with 0 timers \(zero)/5")
        var note = notes.joined(separator: ", ")
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("W30", "菜单栏奔跑触发与计时器", problems.isEmpty, since: t0, note, values)
    }
}
#endif
