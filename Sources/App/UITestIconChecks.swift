// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the fixtures of PanelModel.fixtureData, AppDelegate's status item.
// Output: Gate W08 (docs/DESIGN_V2.md 9.2, 9.3, 13.3): 9 scenarios against a hand-written table (posture, badge, data mark,
//         template flag, width, accessibility label), the head ink against labelColor and the badge color against its
//         token under forced light and dark appearances, five states pairwise XOR at 1x, the glyph matrices.
//         Also the helper of the updated gate A (13.2.1): `headInkCheck`.
// Pos: Test code. It exists only in the UITEST build (`#if UITEST`). scripts/build.py finds the marker line below and
//      registers `UITestIconChecks.register` in the generated `uiTestRegisterAll`. Owner WP-E.
//
// UITEST-REGISTER: UITestIconChecks

#if UITEST
import AppKit
import Foundation

@MainActor
enum UITestIconChecks {
    static func register(into registry: UITestRegistry) {
        registry.add("W08", "menu bar five states") { runner in await runner.stepIconFiveStates() }
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
        return Raster(width: w, height: h, bytes: bytes)
    }

    static let light = NSAppearance(named: .aqua)!
    static let dark = NSAppearance(named: .darkAqua)!

    /// Gate A (13.2.1) and W08: the head of a non-template icon has the menu bar text color. In the head columns
    /// (x < 14 pt), the pixels at the largest alpha must equal `labelColor` of the appearance: RGB and alpha each within
    /// 8 (0 to 255), in light and in dark, at 2x. Returns the worst channel difference.
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
            notes.append("\(name) head px \(n) diff \(Int(diff.rounded()))")
            if n < 40 { worst = 255 }
        }
        return (worst <= IconMetrics.headInkTolerance, worst, notes.joined(separator: ", "))
    }

    /// W08: the badge pixels (full alpha, in the badge box) have the token color of the appearance (each channel
    /// within 8), light and dark, 1x and 2x. Returns the worst difference and the count of badge pixels.
    @MainActor static func badgeColorCheck(_ image: NSImage, kind: MenuIconKind) -> (ok: Bool, worst: Double, note: String) {
        guard let token = kind.badgeToken else { return (true, 0, "no colored badge") }
        let box = kind == .alert
            ? CGRect(x: DogArt.alarmOrigin.x, y: DogArt.alarmOrigin.y, width: DogArt.alarmSize, height: DogArt.alarmSize)
            : CGRect(x: DogArt.menuBadgeOrigin.x, y: DogArt.menuBadgeOrigin.y, width: DogArt.badgeSize, height: DogArt.badgeSize)
        var worst = 0.0
        var notes = [String]()
        for (name, appearance, isDark) in [("light", light, false), ("dark", dark, true)] {
            let hex = MenuIconPalette.hex(token, dark: isDark)
            let want = (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
            for scale in [1, 2] {
                guard let r = render(image, appearance: appearance, scale: scale) else { return (false, 255, "cannot render") }
                var n = 0
                var diff = 0.0
                let k = CGFloat(scale)
                for y in Int(box.minY * k)..<min(r.height, Int(box.maxY * k)) {
                    for x in Int(box.minX * k)..<min(r.width, Int(box.maxX * k)) {
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
}

extension UITestRunner {
    /// W08: the menu bar five states (DESIGN_V2.md 9). The engine is held back while this runs, then gets the icon back.
    func stepIconFiveStates() async {
        let t0 = now()
        delegate.suspendIconUpdates = true
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let button = delegate.statusItem?.button
        var grids = [(kind: MenuIconKind, name: String, grid: [[Double]])]()
        var worstHead = 0.0, worstBadge = 0.0
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
                if button.toolTip != text { problems.append("\(s.name): tooltip differs from the icon text") }
                if (button.accessibilityLabel() ?? "") != text { problems.append("\(s.name): accessibility label differs") }
            } else {
                image = MenuIconRenderer.image(model)
                notes.append("\(s.name): no button image here, renderer image used")
            }
            // (3) Template flag and width.
            if image.isTemplate != s.kind.isTemplate {
                problems.append("\(s.name): isTemplate \(image.isTemplate), expected \(s.kind.isTemplate)")
            }
            if abs(Double(image.size.width) - 24) > 0.01 { problems.append("\(s.name): width \(image.size.width) pt") }
            // (4) Colors under forced light and dark.
            var line = "\(s.name)=\(s.kind.rawValue)"
            if !s.kind.isTemplate {
                let head = UITestIconChecks.headInkCheck(image)
                worstHead = max(worstHead, head.worst)
                if !head.ok { problems.append("\(s.name): head ink \(head.note)") }
                let badge = UITestIconChecks.badgeColorCheck(image, kind: s.kind)
                worstBadge = max(worstBadge, badge.worst)
                if !badge.ok { problems.append("\(s.name): badge color \(badge.note)") }
                line += " head \(Int(head.worst.rounded())) badge \(Int(badge.worst.rounded()))"
            }
            notes.append(line)
            // (5) The 1x alpha grid (light) for the five-state matrix.
            if let r = UITestIconChecks.render(image, appearance: UITestIconChecks.light, scale: 1) {
                grids.append((s.kind, s.name, r.alphaGrid))
            } else {
                problems.append("\(s.name): cannot render at 1x")
            }
        }
        // Five states pairwise at 1x (states of a different kind only).
        var worst = (value: Double.infinity, pair: "")
        for i in 0..<grids.count {
            for j in (i + 1)..<grids.count where grids[i].kind != grids[j].kind {
                let r = IconMetrics.xorRatio(grids[i].grid, grids[j].grid)
                if r < worst.value { worst = (r, grids[i].name + "/" + grids[j].name) }
            }
        }
        if !worst.value.isFinite || worst.value < IconMetrics.fiveStatePass {
            problems.append("five-state XOR \(String(format: "%.3f", worst.value)) (\(worst.pair)) < \(IconMetrics.fiveStatePass)")
        }
        // Glyph matrices at 1x: category glyphs and data marks >= 0.35, alarm discs >= 0.30.
        var glyphs = HealthItem.allCases.map { ($0.rawValue, DogGallery.badgeGrid($0, style: GlyphPaths.chosen)) }
        for mark in MenuMark.allCases { glyphs.append((mark.rawValue, DogGallery.markGrid(mark))) }
        let gm = IconMetrics.matrix(glyphs)
        if gm.minimum < IconMetrics.badgePass { problems.append("glyph XOR \(String(format: "%.3f", gm.minimum)) < \(IconMetrics.badgePass)") }
        let am = IconMetrics.matrix(HealthItem.allCases.map { ($0.rawValue, DogGallery.alarmGrid($0, style: GlyphPaths.chosen)) })
        if am.minimum < IconMetrics.alarmPass { problems.append("alarm XOR \(String(format: "%.3f", am.minimum)) < \(IconMetrics.alarmPass)") }
        // Badge contrast against the reference bars.
        var minContrast = Double.infinity
        for token in MenuIconPalette.Token.allCases {
            for isDark in [false, true] {
                minContrast = min(minContrast, IconMetrics.contrast(MenuIconPalette.hex(token, dark: isDark), MenuIconPalette.bar(dark: isDark)))
            }
        }
        if minContrast < IconMetrics.badgeContrastPass { problems.append("badge contrast \(String(format: "%.2f", minContrast)) < 3") }

        delegate.suspendIconUpdates = false
        delegate.applyMenuIcon(verdicts: engine.verdicts, dataState: engine.dataState)
        values["scenarios"] = Double(scenarios.count)
        values["fiveStateMinXOR"] = worst.value.isFinite ? (worst.value * 1000).rounded() / 1000 : -1
        values["glyphMinXOR"] = (gm.minimum * 1000).rounded() / 1000
        values["alarmMinXOR"] = (am.minimum * 1000).rounded() / 1000
        values["badgeMinContrast"] = (minContrast * 100).rounded() / 100
        values["headInkWorst"] = worstHead
        values["badgeColorWorst"] = worstBadge
        values["problems"] = Double(problems.count)
        var note = notes.joined(separator: ", ")
            + String(format: "; five-state min XOR %.3f", worst.value) + " (\(worst.pair))"
            + String(format: ", glyph min %.3f, alarm min %.3f, contrast min %.2f", gm.minimum, am.minimum, minContrast)
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("W08", "菜单栏五态", problems.isEmpty, since: t0, note, values)
    }
}
#endif
