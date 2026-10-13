// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the fixtures of PreviewScenario and the real popover of AppDelegate.
// Output: The panel gates of docs/DESIGN_V2.md 13.2.1 and 13.3: M4 stable size, M5 contrast, M6 large type, M11 no focus ring, M12 first frame
//         with a curve, M13 copy, M19 dog, M14 icon, N1, N2, and the registered W01 (preview matrix), W02 (layout and problem-first),
//         W09 (copy), W19 (capacity, main column part), W22 (value column). M2 and M3 moved into W02.
// Pos: Test code. It exists only in the UITEST build. The release binary has none of it (checked by scripts/ci_acceptance.py).
//      The M gates open the real popover with a fixture model (engine not attached, invented data). The N gates attach the real engine.
//      The W gates register through `UITestPanelChecks.register(into:)` and run after step M.
// UITEST-REGISTER: UITestPanelChecks

#if UITEST
import AppKit
import CryptoKit
import SwiftUI

// MARK: - Contrast measurement

enum UITestContrast {
    typealias RGB = (r: Double, g: Double, b: Double)

    static let lightSurface: RGB = (236, 236, 236)   // #ECECEC
    static let darkSurface: RGB = (42, 42, 44)       // #2A2A2C

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (Swift.max(la, lb) + 0.05) / (Swift.min(la, lb) + 0.05)
    }

    /// The strongest ink pixel of a region against the dominant color of the region. The pixels are first composited over the
    /// surface color, because the hosting view draws no background of its own (the popover material is behind it).
    static func measure(_ shot: UITestShot, region: CGRect, surface: RGB) -> (ratio: Double, ink: Int)? {
        let box = UITestPixels.pixelRegion(region, of: shot)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return nil }
        var pixels = [RGB]()
        pixels.reserveCapacity((box.x1 - box.x0) * (box.y1 - box.y0))
        var counts = [Int: Int]()
        var sums = [Int: RGB]()
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * shot.w + x) * 4
                let alpha = Double(shot.rgba[i + 3]) / 255
                let behind = 1 - alpha
                let rawR = Double(shot.rgba[i]) + surface.r * behind
                let rawG = Double(shot.rgba[i + 1]) + surface.g * behind
                let rawB = Double(shot.rgba[i + 2]) + surface.b * behind
                let r = Swift.min(255.0, rawR)
                let g = Swift.min(255.0, rawG)
                let b = Swift.min(255.0, rawB)
                pixels.append((r, g, b))
                let kr: Int = Int(r) >> 4
                let kg: Int = Int(g) >> 4
                let kb: Int = Int(b) >> 4
                let key: Int = (kr << 8) | (kg << 4) | kb
                counts[key, default: 0] += 1
                let old = sums[key] ?? (0, 0, 0)
                sums[key] = (old.r + r, old.g + g, old.b + b)
            }
        }
        guard let top = counts.max(by: { $0.value < $1.value }), let sum = sums[top.key] else { return nil }
        let n = Double(top.value)
        let background: RGB = (sum.r / n, sum.g / n, sum.b / n)
        var far = background
        var farDistance = 0.0
        var ink = 0
        for p in pixels {
            let dr = p.r - background.r, dg = p.g - background.g, db = p.b - background.b
            let d = dr * dr + dg * dg + db * db
            if d > 900 { ink += 1 }
            if d > farDistance { farDistance = d; far = p }
        }
        guard ink > 0 else { return nil }
        return (ratio(far, background), ink)
    }
}

/// The pixels of the dog region: how many pixels differ from the dominant color, and how many distinct colors the region has.
struct UITestDogStats {
    var ink: Int
    var area: Int
    var colors: Int

    static func measure(_ shot: UITestShot, region: CGRect, surface: UITestContrast.RGB) -> UITestDogStats? {
        guard let m = UITestContrast.measure(shot, region: region, surface: surface) else { return nil }
        let box = UITestPixels.pixelRegion(region, of: shot)
        var seen = Set<Int>()
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * shot.w + x) * 4
                let r: Int = Int(shot.rgba[i]) >> 3
                let g: Int = Int(shot.rgba[i + 1]) >> 3
                let b: Int = Int(shot.rgba[i + 2]) >> 3
                seen.insert((r << 10) | (g << 5) | b)
            }
        }
        return UITestDogStats(ink: m.ink, area: (box.x1 - box.x0) * (box.y1 - box.y0), colors: seen.count)
    }
}

/// What the menu bar icon must show per scenario (docs/DESIGN.md 3.2). Written by hand, not computed by `MenuIconModel`.
enum UITestIconExpectation {
    static func expected(_ c: PreviewCase) -> (posture: MenuPosture, badge: HealthItem?) {
        switch c {
        case .allGreen: return (.relaxed, nil)
        case .collecting, .stale: return (.hollow, nil)
        case .cpuYellow: return (.raised, .cpu)
        case .diskRed: return (.pant, .disk)
        case .powerYellow: return (.raised, .power)
        case .multi: return (.pant, .disk)
        }
    }
}

final class UITestTextBox: @unchecked Sendable {
    var value: String?
}

// MARK: - Scenarios

extension UITestRunner {
    /// Frame of an id in hosting view points. The registry reports SwiftUI global space, so the origin of `panel.root` is removed.
    func panelRect(_ id: String) -> CGRect? {
        guard let root = UITestFrameStore.shared.get("panel.root"), let r = UITestFrameStore.shared.get(id) else { return nil }
        return r.offsetBy(dx: -root.minX, dy: -root.minY)
    }

    func setAppearance(dark: Bool) async {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        NSApp.appearance = NSAppearance(named: name)
        popover.appearance = NSAppearance(named: name)
        await sleepMs(500)
    }

    func resetAppearance() {
        NSApp.appearance = nil
        popover.appearance = nil
    }

    func openFixture(_ c: PreviewCase, copyBox: UITestTextBox) async -> PanelModel? {
        let model = PanelModel.fixture(c, full: true, now: Date())
        model.testDrive = true
        model.onCopyText = { text in
            copyBox.value = text
            return true
        }
        delegate.testModel = model
        let opened = await openPanel(offsets: [], via: .sendAction, holdMs: 750, prefix: "m-" + c.rawValue)
        guard opened != nil else {
            delegate.testModel = nil
            return nil
        }
        return model
    }

    func closeFixture() async {
        await closePanelQuietly()
        delegate.testModel = nil
    }

    /// Text and graphic regions whose contrast is measured. Text needs 4.5, graphics 3.
    /// Tertiary text (placeholder values of the collecting state, "近 7 天无记录") is inactive text and is not measured.
    func contrastTargets(_ model: PanelModel) -> [(id: String, minimum: Double)] {
        var out = [(id: String, minimum: Double)]()
        var text = ["txt.hero.title", "txt.anomaly.quiet", "txt.anomaly.count"]
        if model.footerState.enabled { text.append("txt.btn.title") }
        for id in text { out.append((id, 4.5)) }
        for row in model.rows {
            let id = row.item.rawValue
            out.append(("txt.row.name." + id, 4.5))
            out.append(("txt.row.note." + id, 4.5))
            if row.status != .collecting { out.append(("row." + id + ".value", 4.5)) }
            if row.status == .measured && !model.spark(for: row.item).isEmpty { out.append(("row." + id + ".spark", 3.0)) }
            if row.isProblem { out.append(("dot." + id, 3.0)) }
        }
        return out
    }

    // MARK: Entry

    func stepM() async {
        let t0 = now()
        // The J step leaves the real panel open. Close it, so each fixture opens its own popover.
        await closePanelQuietly()
        var contrastProblems = [String]()
        var contrastMin = [String: Double]()
        var measuredCount = 0
        var ringProblems = [String]()
        var ringNotes = [String]()
        var stableProblems = [String]()
        var stableNotes = [String]()
        let copyBox = UITestTextBox()
        var dogProblems = [String]()
        var dogNotes = [String]()

        for c in PreviewCase.allCases {
            guard let model = await openFixture(c, copyBox: copyBox), let hv = hostView else {
                ringProblems.append("\(c.rawValue): the panel did not open")
                continue
            }
            let name = c.rawValue

            // M19: no placeholder text in the accessibility tree, and a dog element with a Chinese label (when the tree is readable)
            if c == .allGreen || c == .diskRed {
                let nodes = axNodes()
                let placeholder = "SKEL" + "ETON"
                if nodes.contains(where: { $0.label.contains(placeholder) || $0.value.contains(placeholder) }) {
                    dogProblems.append("\(name): the accessibility tree contains the placeholder text")
                }
                if let dogNode = nodes.first(where: { $0.id == "dog" }) {
                    if !dogNode.label.hasPrefix("比熊") { dogProblems.append("\(name): dog label '\(dogNode.label)'") }
                    dogNotes.append("\(name) dog label '\(dogNode.label)'")
                }
            }

            // M11 and Q9: the first responder is no control, and no focus ring pixels around the button, the more button and the first row
            let responder = hv.window?.firstResponder
            let responderName = responder.map { String(describing: type(of: $0)) } ?? "nil"
            if responder is NSControl { ringProblems.append("\(name): first responder is \(responderName)") }
            for id in ["btn.copy", "btn.more", "row.0"] {
                if let rect = panelRect(id), let shot = capture(hv) {
                    let ring = focusRingPixels(shot, around: rect, margin: 4, outsideOnly: id == "btn.copy")
                    ringNotes.append("\(name) \(id): responder \(responderName), ring pixels \(ring)")
                    if ring > 0 { ringProblems.append("\(name): \(ring) focus ring pixels near \(id)") }
                } else {
                    ringProblems.append("\(name): no frame for \(id)")
                }
            }

            // M5 and Q1: contrast of text (4.5) and graphics (3) in both appearances
            for dark in [false, true] {
                await setAppearance(dark: dark)
                guard let shot = capture(hv) else { contrastProblems.append("\(name): cannot capture"); continue }
                if let png = UITestPixels.png(shot, dark: dark) {
                    try? png.write(to: outDir.appendingPathComponent("ui-m-\(name)-\(dark ? "dark" : "light").png"))
                    frameFiles.append("ui-m-\(name)-\(dark ? "dark" : "light").png")
                }
                let surface = dark ? UITestContrast.darkSurface : UITestContrast.lightSurface
                let dogKey = name + (dark ? " dark" : " light")
                if let rect = panelRect("dog"), let stats = UITestDogStats.measure(shot, region: rect, surface: surface) {
                    let share = Double(stats.ink) / Double(Swift.max(1, stats.area))
                    dogNotes.append("\(dogKey) \(Int(rect.width))x\(Int(rect.height)) ink \(stats.ink) (\(String(format: "%.1f", share * 100)) %), \(stats.colors) colors")
                    // The static gray dog (collecting, stale) is drawn at 85 % alpha (I2, stage 2), so it needs 1.5 % of the region.
                    // The live dog needs 1 %.
                    let staticDog = (c == .collecting || c == .stale)
                    let minShare = staticDog ? 0.015 : 0.01
                    if share < minShare {
                        dogProblems.append("\(dogKey): ink share \(String(format: "%.3f", share)) < \(minShare)")
                    }
                    if stats.colors < 12 { dogProblems.append("\(dogKey): only \(stats.colors) colors, not a drawn dog") }
                } else {
                    dogProblems.append("\(dogKey): no dog region or no ink")
                }
                for target in contrastTargets(model) {
                    guard var rect = panelRect(target.id), rect.width > 2, rect.height > 2 else { continue }
                    // A dot fills its own frame, so the region needs a margin of row background around it.
                    if target.id.hasPrefix("dot.") { rect = rect.insetBy(dx: -3, dy: -3) }
                    guard let m = UITestContrast.measure(shot, region: rect, surface: surface) else {
                        contrastProblems.append("\(name) \(dark ? "dark" : "light") \(target.id): no ink in the region")
                        continue
                    }
                    measuredCount += 1
                    let key = target.id + (dark ? ".dark" : ".light")
                    contrastMin[key] = Swift.min(contrastMin[key] ?? 99, m.ratio)
                    if m.ratio < target.minimum {
                        contrastProblems.append("\(name) \(dark ? "dark" : "light") \(target.id) \(String(format: "%.2f", m.ratio)) < \(target.minimum)")
                    }
                }
            }
            resetAppearance()
            await sleepMs(300)

            // M13 (part): the copy action on the fixture model. It runs before M4.
            if c == .diskRed {
                await stepCopy(model: model, hv: hv, box: copyBox)
            }

            // M4: a stable size (the real popover, fixture data): 10 refreshes, hover over 6 rows, open and close the sidebar by click
            if c == .multi || c == .cpuYellow || c == .diskRed {
                let h0 = Double(hv.bounds.height)
                var changes = 0
                for i in 1...10 {
                    model.load(c, full: true, now: Date().addingTimeInterval(Double(i) * 30))
                    await sleepMs(60)
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                }
                let items = model.layoutPlan.rows
                for (i, item) in items.enumerated() {
                    model.pointerMoved(.row(item), at: CGPoint(x: 100, y: 200 + 40 * Double(i)))
                    await sleepMs(30)
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                }
                model.pointerLeft()
                if let first = items.first {
                    model.rowClicked(first)
                    await sleepMs(400)
                    if model.sidebarItem != first { stableProblems.append("\(name): the clicked row did not open the sidebar") }
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                    model.rowClicked(first)
                    await sleepMs(400)
                    if model.sidebarItem != nil { stableProblems.append("\(name): the second click did not close the sidebar") }
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                }
                stableNotes.append("\(name): 10 refreshes, \(items.count) hovered rows, open and close by click, height \(Int(h0)) pt, changes \(changes)")
                if changes > 0 { stableProblems.append("\(name): the height changed \(changes) time(s)") }
            }

            model.panelDidClose()
            await closeFixture()
        }

        var note4 = stableNotes.joined(separator: "; ")
        if !stableProblems.isEmpty { note4 += "; " + stableProblems.joined(separator: "; ") }
        let values4: [String: Double] = ["problems": Double(stableProblems.count)]
        record("M4", "尺寸稳定（Q5）", stableProblems.isEmpty && !stableNotes.isEmpty, since: t0, note4, values4)

        let lowest = contrastMin.sorted { $0.value < $1.value }.prefix(6)
        var worstParts = [String]()
        for entry in lowest { worstParts.append(entry.key + " " + String(format: "%.2f", entry.value)) }
        var note5 = "\(measuredCount) regions measured in \(PreviewCase.allCases.count) scenarios x light and dark (text >= 4.5, dots and curves >= 3); "
        note5 += "lowest ratios: " + worstParts.joined(separator: ", ")
        if !contrastProblems.isEmpty { note5 += "; failures: " + contrastProblems.prefix(12).joined(separator: "; ") }
        let values5: [String: Double] = ["regions": Double(measuredCount), "failures": Double(contrastProblems.count),
                                         "lowest": contrastMin.values.min() ?? 0]
        record("M5", "对比度（Q1）", contrastProblems.isEmpty && measuredCount > 100, since: t0, note5, values5)

        var note11 = ringNotes.joined(separator: "; ")
        if !ringProblems.isEmpty { note11 += "; failures: " + ringProblems.joined(separator: "; ") }
        let values11: [String: Double] = ["problems": Double(ringProblems.count)]
        record("M11", "无焦点环（Q9）", ringProblems.isEmpty && !ringNotes.isEmpty, since: t0, note11, values11)
        var note19 = dogNotes.joined(separator: "; ")
        if !dogProblems.isEmpty { note19 += "; failures: " + dogProblems.joined(separator: "; ") }
        let values19: [String: Double] = ["problems": Double(dogProblems.count), "measured": Double(dogNotes.count)]
        record("M19", "面板里比熊真实渲染", dogProblems.isEmpty && dogNotes.count >= 14, since: t0, note19, values19)
        stepLargeType()
        await stepColdFirstFrame(copyBox: copyBox)
        await stepIcon()
        await stepVectorDog()
        await stepBitmapPanel()
        await stepHeroDog()
        await stepCollapsedRows()
    }

    /// Pixels near the system focus ring color in the ring zone around a frame (`margin` points outside the frame, plus the frame).
    func focusRingPixels(_ shot: UITestShot, around frame: CGRect, margin: CGFloat, outsideOnly: Bool = false) -> Int {
        let outer = frame.insetBy(dx: -margin, dy: -margin)
        let box = UITestPixels.pixelRegion(outer, of: shot)
        let color = NSColor.keyboardFocusIndicatorColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        let fr: Double = Double(color.redComponent) * 255
        let fg: Double = Double(color.greenComponent) * 255
        let fb: Double = Double(color.blueComponent) * 255
        var count = 0
        guard box.x1 > box.x0, box.y1 > box.y0 else { return 0 }
        let inner = UITestPixels.pixelRegion(frame, of: shot)
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                if outsideOnly && x >= inner.x0 && x < inner.x1 && y >= inner.y0 && y < inner.y1 { continue }
                let i = (y * shot.w + x) * 4
                let a = Double(shot.rgba[i + 3])
                guard a > 40 else { continue }
                // Un-premultiply.
                let scale: Double = 255 / a
                let r: Double = Double(shot.rgba[i]) * scale
                let g: Double = Double(shot.rgba[i + 1]) * scale
                let b: Double = Double(shot.rgba[i + 2]) * scale
                let distance: Double = abs(r - fr) + abs(g - fg) + abs(b - fb)
                let near = distance < 90
                let blue = (b - r > 60) && (b - g > 20)
                if near || blue { count += 1 }
            }
        }
        return count
    }

    // MARK: M13 (part), the copy state machine

    func stepCopy(model: PanelModel, hv: NSView, box: UITestTextBox) async {
        let t0 = now()
        box.value = nil
        let rect = panelRect("btn.copy")
        let before = capture(hv)
        model.copy(.primary)
        let tCopy = now()
        await sleepMs(250)
        let during = capture(hv)
        let text = box.value ?? ""
        let expected = model.promptText(model.scope(for: .primary))
        let homeFree = !text.contains(NSHomeDirectory()) && (NSUserName().count < 3 || !text.contains(NSUserName()))
        let copiedNow = model.copied.contains(.primary)
        var changed = -1.0
        if let before, let during, let rect { changed = UITestPixels.compare(before, during, region: rect, threshold: 24).fraction }
        let reverted = await waitFor(timeoutMs: 2500) { !model.copied.contains(.primary) }
        let seconds = (now() - tCopy)
        await sleepMs(300)
        var back = -1.0
        if let before, let after = capture(hv), let rect { back = UITestPixels.compare(before, after, region: rect, threshold: 24).fraction }
        let timing = reverted != nil && abs(seconds - 1.5) <= 0.3
        let equal = (text == expected)
        let ok = !text.isEmpty && equal && homeFree && copiedNow && changed > 0.02 && timing && back < 0.01
        var note = "text length \(text.count) equals PromptBuilder text=\(equal); no home directory or user name=\(homeFree); "
        note += "copied state set=\(copiedNow); button pixels changed \(String(format: "%.3f", changed)) in the copied state; "
        note += "reverted after \(String(format: "%.2f", seconds)) s (needs 1.5 +- 0.3); "
        note += "button pixels after the revert differ by \(String(format: "%.3f", back)). "
        note += "Part check on fixtures: the click path and the pasteboard are not exercised. "
        note += "The text is built from the fixture with PromptBuilder; the engine copy is judged in N1."
        let values: [String: Double] = ["copiedSeconds": seconds, "changedShare": changed, "textLength": Double(text.count)]
        record("M13", "复制状态机", ok, since: t0, note, values)
    }

    // MARK: M14, menu bar icon states

    /// The menu bar icon of each scenario: the state the app gave to `StatusIconController`, the image and the text.
    /// The real menu bar is not needed. The engine is held back while this runs.
    func stepIcon() async {
        let t0 = now()
        delegate.suspendIconUpdates = true
        var problems = [String]()
        var notes = [String]()
        var hashes = [String: String]()
        let button = delegate.statusItem?.button
        for c in PreviewCase.allCases {
            let data = PanelModel.fixtureData(c, full: true, now: Date())
            let want = UITestIconExpectation.expected(c)
            let modelState = MenuIconModel.state(data.verdicts, dataState: data.dataState)
            if modelState.posture != want.posture || modelState.badge?.item != want.badge {
                problems.append("\(c.rawValue): MenuIconModel gives \(modelState.posture.rawValue)/\(modelState.badge?.item.rawValue ?? "-")")
            }
            delegate.suspendIconUpdates = false
            delegate.applyMenuIcon(verdicts: data.verdicts, dataState: data.dataState)
            delegate.suspendIconUpdates = true
            let applied = delegate.menuIconState
            if applied?.posture != want.posture || applied?.badge?.item != want.badge {
                problems.append("\(c.rawValue): the app applied \(applied?.posture.rawValue ?? "nil")/\(applied?.badge?.item.rawValue ?? "-")")
            }
            let text = MenuIconModel.text(data.verdicts, dataState: data.dataState, now: Date())
            var line = "\(c.rawValue)=\(want.posture.rawValue)/\(want.badge?.rawValue ?? "-")"
            if let button, let image = button.image {
                // DESIGN_V2.md 9.2 rule 2: a yellow or red badge makes a colored image; the other states stay templates.
                if image.isTemplate != (want.badge == nil) {
                    problems.append("\(c.rawValue): isTemplate is \(image.isTemplate), expected \(want.badge == nil)")
                }
                if abs(Double(image.size.width) - 24) > 0.01 { problems.append("\(c.rawValue): the icon is \(image.size.width) pt wide") }
                if button.toolTip != text { problems.append("\(c.rawValue): the tooltip differs from the icon text") }
                if (button.accessibilityLabel() ?? "") != text { problems.append("\(c.rawValue): the accessibility label differs from the icon text") }
                if let raster = UITestIconRaster.alphaFingerprint(image) {
                    hashes[c.rawValue] = raster.hash
                    line += " (\(raster.opaque) px)"
                    if raster.opaque < 40 { problems.append("\(c.rawValue): the icon image is nearly empty (\(raster.opaque) px)") }
                } else {
                    problems.append("\(c.rawValue): cannot rasterize the icon image")
                }
            } else {
                line += " (no button image here)"
            }
            // The problem items appear in ProblemOrder in the text.
            var last = -1
            for v in ProblemOrder.problems(data.verdicts) {
                if let r = text.range(of: v.item.label) {
                    let at = text.distance(from: text.startIndex, to: r.lowerBound)
                    if at < last { problems.append("\(c.rawValue): the problem order in the text is wrong") }
                    last = at
                } else {
                    problems.append("\(c.rawValue): the text lacks \(v.item.label)")
                }
            }
            notes.append(line)
        }
        // Different states need different images.
        let states: [String: String] = ["allGreen": "allGreen", "collecting": "collecting", "stale": "stale",
                                        "cpuYellow": "cpuYellow", "diskRed": "diskRed", "powerYellow": "powerYellow", "multi": "diskRed"]
        var byState = [String: String]()
        for (name, state) in states {
            guard let h = hashes[name] else { continue }
            if let old = byState[state], old != h { problems.append("the same state \(state) gives different images") }
            byState[state] = h
        }
        if !hashes.isEmpty {
            let names = byState.keys.sorted()
            for (i, a) in names.enumerated() {
                for b in names[(i + 1)...] where byState[a] == byState[b] {
                    problems.append("two different states give the same image: \(a) and \(b)")
                }
            }
        }
        delegate.suspendIconUpdates = false
        // Hand the icon back to the engine.
        delegate.applyMenuIcon(verdicts: engine.verdicts, dataState: engine.dataState)
        var note = notes.joined(separator: ", ") + "; images compared: \(hashes.count)"
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        let values: [String: Double] = ["problems": Double(problems.count), "images": Double(hashes.count)]
        record("M14", "菜单栏图标状态", problems.isEmpty, since: t0, note, values)
    }

    // MARK: N1 and N2, the real engine drives the card

    private func trendPointCount(_ series: TrendSeries) -> Int {
        series.segments.reduce(0) { $0 + $1.count }
    }

    /// N2: a cold start restores the history, so the card has curve points at the moment it opens.
    /// N1: the copy button of the engine model copies the text of `PromptBuilder` for the engine input.
    func stepN() async {
        let t0 = now()
        await closePanelQuietly()
        delegate.testModel = nil
        delegate.showPanel()
        guard let model = delegate.panelModel else {
            record("N2", "打开即有历史", false, since: t0, "The engine model was not created.")
            record("N1", "真实引擎复制", false, since: t0, "The engine model was not created.")
            return
        }
        // N2: read the model in the same turn as the show call, before any 2 second point exists.
        let seeded = MonitorEngine.trendSeed?.count ?? 0
        let atOpen = trendPointCount(model.data.trend)
        let needed = Swift.max(30, seeded / 2)
        let sectionKeys = model.layoutPlan.sections.map { $0.key }
        var note2 = "the trend seed has \(seeded) points. The model had \(atOpen) points when the card opened (needs at least \(needed)). "
        note2 += "Sections: " + sectionKeys.joined(separator: ", ") + "; plan height \(Int(model.layoutPlan.height)) pt."
        let values2: [String: Double] = ["seedPoints": Double(seeded), "pointsAtOpen": Double(atOpen), "sections": Double(sectionKeys.count)]
        record("N2", "打开即有历史", seeded > 0 && atOpen >= needed, since: t0, note2, values2)

        await sleepMs(700)
        if let hv = hostView, let shot = capture(hv) { save(shot, "ui-real-engine.png") }

        // N1
        let t1 = now()
        let box = UITestTextBox()
        model.onCopyText = { text in
            box.value = text
            return true
        }
        model.copy(.primary)
        let text = box.value ?? ""
        let options = PromptOptions.forCurrentUser(includeAppNames: engine.includeAppNamesInPrompt)
        let expected = PromptBuilder.build(engine.promptInput(), scope: model.scope(for: .primary), options: options)
        let equal = (text == expected)
        let short = text.count <= 3000
        let homeFree = !text.contains(NSHomeDirectory()) && (NSUserName().count < 3 || !text.contains(NSUserName()))
        let hasTopic = text.contains("磁盘")
        var note1 = "text length \(text.count) (limit 3000)=\(short); equals PromptBuilder text of the engine input=\(equal); "
        note1 += "no home directory or user name=\(homeFree); names the disk problem=\(hasTopic). "
        note1 += "The click path and the pasteboard are not exercised."
        let values1: [String: Double] = ["textLength": Double(text.count)]
        record("N1", "真实引擎复制", !text.isEmpty && equal && short && homeFree && hasTopic, since: t1, note1, values1)
        model.onCopyText = { Clipboard.copy($0) }
        await closePanelQuietly()
    }

    // MARK: M6 and Q2, 1.25 times type

    func stepLargeType() {
        let t0 = now()
        var problems = [String]()
        var widest = [String]()
        for slot in PanelSlots.all {
            var font = NSFont.systemFont(ofSize: slot.size * 1.25, weight: slot.weight)
            if slot.rounded, let descriptor = font.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: slot.size * 1.25) {
                font = rounded
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let string = NSAttributedString(string: slot.sample, attributes: attributes)
            if slot.lines <= 1 {
                var width = Double(string.size().width) * Double(slot.minScale)
                if !slot.prefix.isEmpty {
                    let prefixFont = NSFont.systemFont(ofSize: 11 * 1.25, weight: .regular)
                    width += Double(NSAttributedString(string: slot.prefix, attributes: [.font: prefixFont]).size().width) + 3
                }
                widest.append("\(slot.name) \(Int(width.rounded(.up)))/\(Int(slot.width))")
                if width > Double(slot.width) + 0.5 { problems.append("\(slot.name): \(Int(width.rounded(.up))) pt > \(Int(slot.width)) pt") }
            } else {
                let bound = string.boundingRect(with: NSSize(width: slot.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
                let lineHeight = Double(font.ascender - font.descender + font.leading)
                let lines = Int((Double(bound.height) / Swift.max(1, lineHeight)).rounded())
                widest.append("\(slot.name) \(lines)/\(slot.lines) lines")
                if lines > slot.lines { problems.append("\(slot.name): \(lines) lines > \(slot.lines)") }
            }
        }
        var note6 = "\(PanelSlots.all.count) slots at 1.25 times the font size: "
        note6 += problems.isEmpty ? "all fit. " : "overflow: " + problems.joined(separator: "; ") + ". "
        note6 += "measured " + widest.joined(separator: ", ")
        let values6: [String: Double] = ["slots": Double(PanelSlots.all.count), "overflow": Double(problems.count)]
        record("M6", "大字号不溢出（Q2）", problems.isEmpty && !widest.isEmpty, since: t0, note6, values6)
    }

    // MARK: M12, the first frame has a curve

    func stepColdFirstFrame(copyBox: UITestTextBox) async {
        let t0 = now()
        let model = PanelModel.fixture(.allGreen, full: true, now: Date())
        model.testDrive = true
        model.onCopyText = { text in
            copyBox.value = text
            return true
        }
        delegate.testModel = model
        UITestFrameStore.shared.reset()
        let box = UITestTimeBox()
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: popover, queue: nil) { _ in
            box.value = CACurrentMediaTime()
        }
        let start = now()
        delegate.showPanel()
        NotificationCenter.default.removeObserver(observer)
        let ref = box.value ?? start
        var ink = 0
        var elapsed = -1.0
        var found = false
        while (now() - ref) * 1000 < 800 {
            if let hv = hostView, let rect = panelRect("row.cpu.spark"), rect.width > 20, rect.height > 10, let shot = capture(hv) {
                let surface = UITestContrast.lightSurface
                if let m = UITestContrast.measure(shot, region: rect, surface: surface) {
                    ink = m.ink
                    elapsed = (now() - ref) * 1000
                    found = true
                    break
                }
            }
            await sleepMs(8)
        }
        await sleepMs(200)
        await closeFixture()
        let ok = found && elapsed <= 300 && ink >= 30
        var note = "no frame with line pixels in row.cpu.spark within 800 ms"
        if found {
            note = "the first frame with line pixels in row.cpu.spark came " + String(format: "%.0f", elapsed)
            note += " ms after the show call (limit 300 ms), \(ink) line pixels"
        }
        let values: [String: Double] = ["firstFrameMs": elapsed, "inkPixels": Double(ink)]
        record("M12", "冷启动首帧有曲线（Q8）", ok, since: t0, note, values)
    }
}

// MARK: - Registered W gates (docs/DESIGN_V2.md 13.3)

enum UITestPanelChecks {
    @MainActor
    static func register(into registry: UITestRegistry) {
        registry.add("W01", "preview matrix") { runner in await runner.stepW01() }
        registry.add("W02", "layout and problem-first") { runner in await runner.stepW02() }
        registry.add("W06", "hover intent (UI part)") { runner in await runner.stepW06() }
        registry.add("W07", "drag readout") { runner in await runner.stepW07() }
        registry.add("M10b", "sidebar controls and chart descriptor") { runner in await runner.stepSidebarControls() }
        registry.add("W09", "copy") { runner in await runner.stepW09() }
        registry.add("W19", "capacity text") { runner in await runner.stepW19() }
        registry.add("W22", "value column alignment") { runner in await runner.stepW22() }
    }
}

extension UITestRunner {
    /// Mean color of a region, composited over the surface (the hosting view draws no background). Pixels are 0...255.
    func regionColor(_ shot: UITestShot, region: CGRect, surface: UITestContrast.RGB) -> UITestContrast.RGB? {
        let box = UITestPixels.pixelRegion(region, of: shot)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0
        var n = 0.0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * shot.w + x) * 4
                let behind = 1 - Double(shot.rgba[i + 3]) / 255
                sr += Swift.min(255.0, Double(shot.rgba[i]) + surface.r * behind)
                sg += Swift.min(255.0, Double(shot.rgba[i + 1]) + surface.g * behind)
                sb += Swift.min(255.0, Double(shot.rgba[i + 2]) + surface.b * behind)
                n += 1
            }
        }
        return (sr / n, sg / n, sb / n)
    }

    func hexOf(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: W01

    /// The preview matrix rendered by PanelPreview: every file is a PNG of the right width, and no two files are equal.
    func stepW01() async {
        let t0 = now()
        var problems = [String]()
        var hashes = [String: String]()
        var count = 0
        let when = Date()
        func check(_ data: Data?, _ label: String, widthPx: Int) {
            guard let data, let rep = NSBitmapImageRep(data: data) else { problems.append("\(label): no image"); return }
            count += 1
            if data.count < 4000 { problems.append("\(label): only \(data.count) bytes") }
            if abs(rep.pixelsWide - widthPx) > 1 { problems.append("\(label): \(rep.pixelsWide) px wide, expected \(widthPx)") }
            let hash = hexOf(data)
            if let other = hashes[hash] { problems.append("\(label) equals \(other)") }
            hashes[hash] = label
        }
        for empty in [false, true] {
            for c in PreviewCase.allCases {
                let model = PanelModel.fixture(c, full: !empty, now: when)
                for dark in [false, true] {
                    check(PanelPreview.png(model: model, dark: dark), "\(c.rawValue)-\(dark ? "dark" : "light")\(empty ? "-empty" : "")", widthPx: 704)
                }
            }
        }
        let mainCount = count
        for item in PanelPreview.sidebarItems {
            let model = PanelModel.fixture(.multi, full: true, now: when)
            model.pinSidebar(item)
            for dark in [false, true] {
                check(PanelPreview.png(model: model, dark: dark), "side-\(item.rawValue)-\(dark ? "dark" : "light")", widthPx: 1344)
            }
        }
        let expectedMain = PreviewCase.allCases.count * 4
        if mainCount != expectedMain { problems.append("rendered \(mainCount) main files, expected \(expectedMain)") }
        var note = "\(mainCount) main column files (\(PreviewCase.allCases.count) cases x light and dark x full and empty, 704 px wide) and "
        note += "\(count - mainCount) sidebar files (1344 px wide); pairwise different sha256: \(hashes.count) of \(count)."
        if !problems.isEmpty { note += " failures: " + problems.prefix(12).joined(separator: "; ") }
        let values: [String: Double] = ["files": Double(count), "mainFiles": Double(mainCount), "problems": Double(problems.count)]
        record("W01", "预览矩阵", problems.isEmpty && count > 0, since: t0, note, values)
    }

    // MARK: W02

    /// The independent row order of DESIGN_V2.md 5.2: problems first (red before yellow), then CPU, memory, disk, network, battery, thermal.
    func expectedRowOrder(_ data: PanelData) -> [String] {
        var out = [String]()
        let ranked = data.verdicts.filter { $0.level == .red } + data.verdicts.filter { $0.level == .yellow }
        for v in ranked {
            let id = SidebarItem(v.item).rawValue
            if v.item == .power && !data.hasBattery { continue }
            if !out.contains(id) { out.append(id) }
        }
        for id in ["cpu", "memory", "disk", "network", "battery", "thermal"] where !out.contains(id) {
            if id == "battery" && !data.hasBattery { continue }
            out.append(id)
        }
        return out
    }

    func measureTokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: "[+-]?[0-9]+(?:\\.[0-9]+)? ?(?:GB|MB|KB|TB|%|\u{00B0}C)", options: []) else { return out }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            if let r = Range(match.range, in: text) { out.insert(String(text[r])) }
        }
        return out
    }

    func stepW02() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        let copyBox = UITestTextBox()
        for c in PreviewCase.allCases {
            guard let model = await openFixture(c, copyBox: copyBox), let hv = hostView else {
                problems.append("\(c.rawValue): the panel did not open")
                continue
            }
            let name = c.rawValue
            let data = model.data
            let plan = model.layoutPlan
            // Height equals the formula of 2.3 (written out here, not read from PanelLayout.height).
            let anomalyCount = data.problems.filter { $0.item != .power || data.hasBattery }.count
            let rowCount = data.hasBattery ? 6 : 5
            // The anomaly area is one 36 pt line, so the height changes with the battery row only (design change 2026-10-12).
            let anomalyArea = 36.0
            let formula = 12.0 + 152.0 + 8.0 + Double(rowCount) * 40.0 + 12.0 + anomalyArea + 12.0 + 40.0 + 12.0
            let height = Double(hv.bounds.height)
            if abs(height - formula) > 1 { problems.append("\(name): height \(height) pt, formula \(formula) pt") }
            if abs(plan.height - formula) > 0.01 { problems.append("\(name): plan height \(plan.height), formula \(formula)") }
            if let column = panelRect("column.main"), abs(Double(column.width) - 352) > 0.5 {
                problems.append("\(name): main column \(column.width) pt wide, expected 352")
            }
            // Section order.
            var lastY = -Double.infinity
            for key in ["hero", "rows", "anomaly", "footer"] {
                guard let frame = panelRect("sec." + key) else { problems.append("\(name): no frame for sec.\(key)"); continue }
                if Double(frame.minY) < lastY - 0.5 { problems.append("\(name): sec.\(key) is above its predecessor") }
                lastY = Double(frame.minY)
            }
            // Row order on screen equals 5.2.
            let wanted = expectedRowOrder(data)
            var onScreen = [(id: String, y: Double)]()
            for id in wanted {
                if let r = panelRect("row." + id) { onScreen.append((id, Double(r.minY))) }
            }
            onScreen.sort { $0.y < $1.y }
            if onScreen.map({ $0.id }) != wanted { problems.append("\(name): rows on screen \(onScreen.map { $0.id }) differ from \(wanted)") }
            if model.rows.map({ $0.item.rawValue }) != wanted { problems.append("\(name): model rows differ from \(wanted)") }
            // Colors: only the first (most severe) problem row carries its level tint. Other problem rows and normal rows have none.
            for dark in [false, true] {
                await setAppearance(dark: dark)
                guard let shot = capture(hv) else { problems.append("\(name): cannot capture"); continue }
                let surface = dark ? UITestContrast.darkSurface : UITestContrast.lightSurface
                for (rowIndex, row) in model.rows.enumerated() {
                    guard let r = panelRect("row." + row.item.rawValue) else { continue }
                    let strip = CGRect(x: r.minX + 1, y: r.minY + 12, width: 4, height: 16)
                    guard let color = regionColor(shot, region: strip, surface: surface) else { continue }
                    if row.isProblem && rowIndex == 0 {
                        let alpha = dark ? 0.10 : 0.06
                        var level: UITestContrast.RGB = (229.0, 48.0, 42.0)
                        if row.dot == .red {
                            level = dark ? (255.0, 69.0, 58.0) : (229.0, 48.0, 42.0)
                        } else {
                            level = dark ? (255.0, 159.0, 10.0) : (194.0, 100.0, 0.0)
                        }
                        let expected: UITestContrast.RGB = (surface.r * (1 - alpha) + level.r * alpha, surface.g * (1 - alpha) + level.g * alpha,
                                                            surface.b * (1 - alpha) + level.b * alpha)
                        let diff = Swift.max(abs(color.r - expected.r), abs(color.g - expected.g), abs(color.b - expected.b))
                        if diff > 30 { problems.append("\(name) \(dark ? "dark" : "light") \(row.item.rawValue): tint differs by \(Int(diff))") }
                    } else {
                        let spread = Swift.max(color.r, color.g, color.b) - Swift.min(color.r, color.g, color.b)
                        let surfaceSpread = Swift.max(surface.r, surface.g, surface.b) - Swift.min(surface.r, surface.g, surface.b)
                        if spread - surfaceSpread > 4 { problems.append("\(name) \(dark ? "dark" : "light") \(row.item.rawValue): row without tint has color (spread \(Int(spread)))") }
                    }
                }
            }
            resetAppearance()
            // A measured value does not appear in a row and in an anomaly bar (7.3).
            var rowTokens = Set<String>()
            for row in model.rows { rowTokens.formUnion(measureTokens(row.measurement)); rowTokens.formUnion(measureTokens(row.note)) }
            let barTokens = measureTokens(model.anomalySummary)
            let both = rowTokens.intersection(barTokens)
            if !both.isEmpty { problems.append("\(name): measured values in a row and the anomaly line: \(both.sorted())") }
            // The anomaly area lists no item: no row name appears in the anomaly line.
            if !model.layoutPlan.anomalies.isEmpty {
                for row in model.rows where model.anomalySummary.contains(row.name) { problems.append("\(name): the anomaly line names \(row.name)") }
            }
            notes.append("\(name)=\(Int(height)) pt, \(wanted.count) rows, \(anomalyCount) anomalies")
            model.panelDidClose()
            await closeFixture()
        }
        // Type sizes: the rows, the anomaly area and the footer use 4 sizes at most.
        let sizes = Set(PanelSlots.all.map { Double($0.size) })
        if sizes.count > 4 || !sizes.isSubset(of: PanelType.allowedSizes) { problems.append("type sizes \(sizes.sorted())") }
        var note = notes.joined(separator: ", ") + "; type sizes \(sizes.sorted())."
        note += " Width 672 pt with the sidebar is judged by WP-B window frames (not in this check)."
        if !problems.isEmpty { note += " failures: " + problems.prefix(12).joined(separator: "; ") }
        let values: [String: Double] = ["scenarios": Double(PreviewCase.allCases.count), "problems": Double(problems.count), "sizeKinds": Double(sizes.count)]
        record("W02", "版面与问题优先", problems.isEmpty && !notes.isEmpty, since: t0, note, values)
    }

    // MARK: W09

    func stepW09() async {
        let t0 = now()
        let box = UITestTextBox()
        var problems = [String]()
        guard let model = await openFixture(.diskRed, copyBox: box), let hv = hostView else {
            record("W09", "复制", false, since: t0, "the panel did not open")
            return
        }
        let copyButtons = axNodes().filter { $0.id == "btn.copy" }
        if !copyButtons.isEmpty && copyButtons.count != 1 { problems.append("\(copyButtons.count) nodes named btn.copy") }
        let ids = UITestFrameStore.shared.ids.filter { $0.hasPrefix("btn.") }
        // W09 counts primary buttons. The frame store keeps the ids of earlier checks, so it also holds the sidebar controls of
        // DESIGN_V2.md 6: the close button and the range segments (6.4: 2 小时 / 24 小时 / 7 天, disk 30 天). They are not primary buttons.
        let sidebar = Set(["btn.sideClose"] + SidebarRange.allCases.map { "btn.range." + $0.rawValue })
        let allowed: Set<String> = Set(["btn.copy", "btn.more", "btn.records", "btn.notifyAuth"]).union(sidebar)
        let extra = ids.filter { !allowed.contains($0) }
        if !extra.isEmpty { problems.append("other buttons: \(extra)") }
        let rect = panelRect("btn.copy")
        let before = capture(hv)
        box.value = nil
        let tCopy = now()
        model.copy(.primary)
        // The state is set in the same call. Poll for it so that a slow VM does not count as a slow state.
        let shownAt = await waitFor(timeoutMs: 300) { !model.copied.isEmpty }
        let shownMs = shownAt ?? 300
        if shownAt == nil { problems.append("no copied state 300 ms after the click") }
        if shownMs > 100 { problems.append("the copied state needed \(Int(shownMs)) ms (limit 100 ms)") }
        await sleepMs(250)
        let during = capture(hv)
        var changed = -1.0
        if let before, let during, let rect { changed = UITestPixels.compare(before, during, region: rect, threshold: 24).fraction }
        if changed < 0.02 { problems.append("button pixels changed only \(changed)") }
        if model.copyBubble != "已复制，去问你的 Agent 吧" { problems.append("bubble text '\(model.copyBubble ?? "nil")'") }
        let reverted = await waitFor(timeoutMs: 2500) { model.copied.isEmpty }
        let seconds = now() - tCopy
        if reverted == nil || abs(seconds - 1.5) > 0.3 { problems.append("reverted after \(String(format: "%.2f", seconds)) s") }
        let text = box.value ?? ""
        let expected = model.promptText(model.scope(for: .primary))
        if text.isEmpty || text != expected { problems.append("the copied text differs from the PromptBuilder text") }
        if text.contains(NSHomeDirectory()) || (NSUserName().count >= 3 && text.contains(NSUserName())) { problems.append("the text holds the home folder or user name") }
        model.panelDidClose()
        await closeFixture()
        var note = "one primary button btn.copy (other btn ids: \(ids.sorted())); copied state seen at \(Int(shownMs)) ms; reverted after "
        note += String(format: "%.2f", seconds) + " s; text length \(text.count). The click path and the pasteboard are not exercised."
        if !problems.isEmpty { note += " failures: " + problems.joined(separator: "; ") }
        let values: [String: Double] = ["copiedSeconds": seconds, "shownMs": shownMs, "changedShare": changed, "textLength": Double(text.count)]
        record("W09", "复制", problems.isEmpty, since: t0, note, values)
    }

    // MARK: W19

    /// "已用 593 / 995 GB" or "已用 31.4 / 64 GB": the used value, the total and the unit. A ", 可用 ..." part after the comma is ignored.
    func parseNote(_ note: String) -> (used: Double, total: Double, unit: String)? {
        let head = note.components(separatedBy: "，").first ?? note
        let parts = head.replacingOccurrences(of: "已用 ", with: "").split(separator: " ").map(String.init)
        guard parts.count == 4, parts[1] == "/", let used = Double(parts[0]), let total = Double(parts[2]) else { return nil }
        return (used, total, parts[3])
    }

    func stepW19() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        for c in PreviewCase.allCases {
            for full in [true, false] {
                let data = PanelModel.fixtureData(c, full: full, now: Date())
                let model = PanelModel(data: data)
                for item in [SidebarItem.disk, SidebarItem.memory] {
                    guard let row = model.rows.first(where: { $0.item == item }) else { problems.append("\(c.rawValue): no \(item.rawValue) row"); continue }
                    if row.status == .collecting {
                        if row.note != "正在采集" { problems.append("\(c.rawValue) \(item.rawValue): collecting note '\(row.note)'") }
                        continue
                    }
                    let cap = item == .disk ? CapacityFormat.disk(data.current) : CapacityFormat.memory(data.current)
                    // The free part is in the note unless the value on the right is the free space ("可用 412 GB").
                    let valueIsAvailable = item == .disk && !row.value.hasPrefix("+")
                    let expectedNote = (item == .memory || !valueIsAvailable) ? cap.usedOfTotalAvailable : cap.usedOfTotal
                    if row.note != expectedNote {
                        problems.append("\(c.rawValue) \(item.rawValue): note '\(row.note)' differs from '\(expectedNote)'")
                    }
                    if cap.isMissing {
                        if cap.total != "—" || cap.used != "—" || cap.available != "—" { problems.append("\(c.rawValue) \(item.rawValue): missing source gives no three dashes") }
                        if row.note != "已用 —" { problems.append("\(c.rawValue) \(item.rawValue): missing note '\(row.note)'") }
                        continue
                    }
                    guard let p = parseNote(row.note) else { problems.append("\(c.rawValue) \(item.rawValue): cannot parse '\(row.note)'"); continue }
                    let availableNumber = Double(cap.available.split(separator: " ").first ?? "") ?? -1
                    if abs(p.used + availableNumber - p.total) > 0.0001 { problems.append("\(c.rawValue) \(item.rawValue): used + available differs from total") }
                    if cap.available.split(separator: " ").last.map(String.init) != p.unit { problems.append("\(c.rawValue) \(item.rawValue): units differ") }
                    notes.append("\(c.rawValue) \(item.rawValue) \(row.note)")
                }
            }
        }
        let sidebarNotes = await sidebarCapacityChecks(&problems)
        var note = "\(notes.count) capacity notes checked (used + available = total, one unit); missing sources give three dashes and '已用 —'. "
        note += sidebarNotes.joined(separator: "; ") + ". "
        if !problems.isEmpty { note += " failures: " + problems.prefix(12).joined(separator: "; ") }
        let values: [String: Double] = ["checked": Double(notes.count), "problems": Double(problems.count)]
        record("W19", "容量三元组", problems.isEmpty && !notes.isEmpty, since: t0, note, values)
    }

    // MARK: W22

    func stepW22() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        let copyBox = UITestTextBox()
        for c in [PreviewCase.allGreen, PreviewCase.multi, PreviewCase.diskRed] {
            guard let model = await openFixture(c, copyBox: copyBox) else { problems.append("\(c.rawValue): the panel did not open"); continue }
            var edges = [Double]()
            for row in model.rows {
                guard let r = panelRect("row." + row.item.rawValue + ".value") else { problems.append("\(c.rawValue): no value frame for \(row.item.rawValue)"); continue }
                edges.append(Double(r.maxX))
            }
            if let low = edges.min(), let high = edges.max() {
                if high - low > 0.5 { problems.append("\(c.rawValue): value right edges differ by \(String(format: "%.2f", high - low)) pt") }
                notes.append("\(c.rawValue) edges \(String(format: "%.1f", low))...\(String(format: "%.1f", high))")
            } else {
                problems.append("\(c.rawValue): no value frames")
            }
            model.panelDidClose()
            await closeFixture()
        }
        // Monospaced digits: the 10 digits have one advance width.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        let widths = (0...9).map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }
        if let low = widths.min(), let high = widths.max(), high - low > 0.01 { problems.append("digit widths differ by \(high - low)") }
        var note = notes.joined(separator: ", ") + "; the ten digits have one width at 17 pt."
        if !problems.isEmpty { note += " failures: " + problems.joined(separator: "; ") }
        let values: [String: Double] = ["problems": Double(problems.count)]
        record("W22", "数值列右对齐", problems.isEmpty && !notes.isEmpty, since: t0, note, values)
    }
}

/// Rasterizes a menu bar icon image at 2x into an alpha-only bitmap and hashes it.
/// The `tiffRepresentation` of a drawing-handler image is not a reliable fingerprint, so the pixels are drawn here.
enum UITestIconRaster {
    static func alphaFingerprint(_ image: NSImage) -> (hash: String, opaque: Int)? {
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var hash: UInt64 = 1469598103934665603
        var opaque = 0
        for y in 0..<h {
            for x in 0..<w {
                let alpha = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                let a = UInt64((alpha * 255).rounded())
                if a > 20 { opaque += 1 }
                hash = (hash ^ a) &* 1099511628211
            }
        }
        return (String(hash, radix: 16), opaque)
    }
}

// MARK: - Sidebar gates (WP-C C2)

extension UITestRunner {
    /// The sidebar frame of an id, or nil. The sidebar may lie outside the clipped hosting view, so the registry is the source.
    func sideRect(_ id: String) -> CGRect? {
        UITestFrameStore.shared.get(id)
    }

    /// Opens the sidebar of `item` on the fixture model and waits for its frame. Returns false on timeout.
    func openSidebar(_ model: PanelModel, _ item: SidebarItem) async -> Bool {
        model.pinSidebar(item)
        let found = await waitFor(timeoutMs: 1500) { self.sideRect("sidebar") != nil && self.sideRect("side.title") != nil }
        await sleepMs(150)
        axCache = nil
        return found != nil
    }

    // MARK: W19, sidebar part

    func sidebarCapacityChecks(_ problems: inout [String]) async -> [String] {
        var notes = [String]()
        let box = UITestTextBox()
        for c in [PreviewCase.allGreen, PreviewCase.diskRed] {
            guard let model = await openFixture(c, copyBox: box) else {
                problems.append("\(c.rawValue): the panel did not open for the sidebar check")
                continue
            }
            for item in [SidebarItem.disk, SidebarItem.memory] {
                guard await openSidebar(model, item) else {
                    problems.append("\(c.rawValue) \(item.rawValue): the sidebar did not open")
                    continue
                }
                let state = model.sidebarContent(for: item)
                guard let cap = state.capacity else { problems.append("\(c.rawValue) \(item.rawValue): no capacity area"); continue }
                let totalRect = sideRect("cap.total"), usedRect = sideRect("cap.used"), availableRect = sideRect("cap.available")
                guard let totalRect, let usedRect, let availableRect else {
                    problems.append("\(c.rawValue) \(item.rawValue): capacity frames missing")
                    continue
                }
                // The three columns are 95 pt wide and right aligned: the text boxes end at the column edge (tolerance 0.5 pt).
                let edges = [totalRect.maxX, usedRect.maxX, availableRect.maxX]
                let gap1 = abs((edges[1] - edges[0]) - 96), gap2 = abs((edges[2] - edges[1]) - 96)
                if gap1 > 0.5 || gap2 > 0.5 { problems.append("\(c.rawValue) \(item.rawValue): column edges \(edges) are not 96 pt apart") }
                let units = [cap.total, cap.used, cap.available].map { $0.split(separator: " ").last.map(String.init) ?? "" }
                if Set(units).count != 1 { problems.append("\(c.rawValue) \(item.rawValue): units differ \(units)") }
                let n = [cap.total, cap.used, cap.available].map { Double($0.split(separator: " ").first ?? "") ?? -1 }
                if abs(n[1] + n[2] - n[0]) > 0.0001 { problems.append("\(c.rawValue) \(item.rawValue): used + available differs from total") }
                // The main column note shows the same used and total strings.
                if let row = model.rows.first(where: { $0.item == item }), !row.note.hasPrefix(cap.usedOfTotal) {
                    problems.append("\(c.rawValue) \(item.rawValue): main note '\(row.note)' does not start with '\(cap.usedOfTotal)'")
                }
                // The accessibility tree carries the same strings.
                if let node = axNodes().first(where: { $0.id == "cap.area" }) {
                    if !node.label.contains(cap.total) || !node.label.contains(cap.used) || !node.label.contains(cap.available) {
                        problems.append("\(c.rawValue) \(item.rawValue): cap.area label '\(node.label)'")
                    }
                } else {
                    problems.append("\(c.rawValue) \(item.rawValue): no cap.area node in the accessibility tree")
                }
                notes.append("\(c.rawValue) \(item.rawValue) sidebar \(cap.total) / \(cap.used) / \(cap.available)")
            }
            // A missing source gives three dashes.
            var data = model.data
            data.current.diskTotal = nil
            data.current.memory = nil
            data.current.physicalMemory = nil
            model.replace(data)
            for item in [SidebarItem.disk, SidebarItem.memory] {
                if !(await openSidebar(model, item)) { continue }
                let cap = model.sidebarContent(for: item).capacity
                if cap?.total != "\u{2014}" || cap?.used != "\u{2014}" || cap?.available != "\u{2014}" {
                    problems.append("\(c.rawValue) \(item.rawValue): missing source gives no three dashes in the sidebar")
                }
            }
            model.panelDidClose()
            await closeFixture()
        }
        return ["sidebar capacity checked: " + (notes.isEmpty ? "none" : notes.joined(separator: ", ")) + " (column edges 96 pt apart, +-0.5 pt)"]
    }

    // MARK: W07, drag readout

    func stepW07() async {
        let t0 = now()
        let box = UITestTextBox()
        var problems = [String]()
        guard let model = await openFixture(.multi, copyBox: box) else {
            record("W07", "拖动读数", false, since: t0, "the panel did not open")
            return
        }
        defer { model.panelDidClose() }
        guard await openSidebar(model, .cpu), let readout = ChartProbe.shared.readout, let chart = model.sidebarContent(for: .cpu).chart else {
            await closeFixture()
            record("W07", "拖动读数", false, since: t0, "the sidebar chart did not appear")
            return
        }
        await sleepMs(200)
        ChartProbe.shared.reset()
        let drawsBefore = ChartProbe.shared.mainDraws
        let updatesBefore = readout.updates
        var worstMs = 0.0
        var updated = 0
        for i in 0..<120 {
            let fraction = (Double(i) + 0.5) / 120
            let before = readout.updates
            let start = now()
            readout.move(to: fraction, in: chart, timeZone: TimeZone.current)
            let spent = (now() - start) * 1000
            worstMs = Swift.max(worstMs, spent)
            if readout.updates > before { updated += 1 }
            await sleepMs(16)
        }
        await sleepMs(150)
        let draws = ChartProbe.shared.mainDraws - drawsBefore
        let share = Double(updated) / 120
        if share < 0.95 { problems.append("only \(updated) of 120 moves updated the readout") }
        if worstMs > 8 { problems.append("the slowest move took \(String(format: "%.2f", worstMs)) ms") }
        if draws > 2 { problems.append("the main chart was evaluated \(draws) times during the drag") }
        if readout.text == nil || readout.text?.contains("·") != true { problems.append("readout text '\(readout.text ?? "nil")'") }
        readout.clear()
        await closeFixture()
        var note = "120 synthetic moves at 60 Hz: \(updated) updated the readout (\(Int(share * 100)) %), slowest \(String(format: "%.2f", worstMs)) ms, "
        note += "main chart evaluations \(draws) (limit 2: a stray refresh is allowed, a per-move evaluation is not), updates counted \(readout.updates - updatesBefore). The pointer and the drag call the same move function."
        if !problems.isEmpty { note += " failures: " + problems.joined(separator: "; ") }
        let values: [String: Double] = ["updatedShare": share, "worstMs": worstMs, "mainDraws": Double(draws)]
        record("W07", "拖动读数", problems.isEmpty, since: t0, note, values)
    }

    // MARK: Sidebar controls and chart descriptor

    func stepSidebarControls() async {
        let t0 = now()
        let box = UITestTextBox()
        var problems = [String]()
        var notes = [String]()
        guard let model = await openFixture(.multi, copyBox: box) else {
            record("M10b", "侧栏控件与图表无障碍", false, since: t0, "the panel did not open")
            return
        }
        for item in SidebarItem.allCases {
            guard await openSidebar(model, item) else { problems.append("\(item.rawValue): the sidebar did not open"); continue }
            let ids = UITestFrameStore.shared.ids
            if !ids.contains("btn.sideClose") { problems.append("\(item.rawValue): no btn.sideClose") }
            for option in SidebarRange.options(for: item) where !ids.contains("btn.range." + option.rawValue) {
                problems.append("\(item.rawValue): no range button \(option.rawValue)")
            }
            let nodes = axNodes()
            if let close = nodes.first(where: { $0.id == "btn.sideClose" }) {
                if close.label.isEmpty { problems.append("\(item.rawValue): the close button has no label") }
            } else {
                problems.append("\(item.rawValue): no btn.sideClose in the accessibility tree")
            }
            if item != .anomalyLog {
                if let chart = nodes.first(where: { $0.id == "chart.main" }) {
                    if chart.label.isEmpty || !chart.label.contains(item.label) { problems.append("\(item.rawValue): chart label '\(chart.label)'") }
                } else {
                    problems.append("\(item.rawValue): no chart.main in the accessibility tree")
                }
            }
            notes.append(item.rawValue)
        }
        // A click on a range button changes the range, and the chart follows.
        if await openSidebar(model, .cpu) {
            let before = model.range(for: .cpu)
            model.setRange(.d7, for: .cpu)
            await sleepMs(150)
            let after = model.sidebarContent(for: .cpu)
            if before == .d7 || after.range != .d7 || after.chart?.range != .d7 { problems.append("the range did not change to 7 d") }
            // Keys: Tab moves the focus to the range control, an arrow key changes the range.
            model.setKeyFocus(.sidebarRange)
            _ = model.handleKey(.left)
            if model.range(for: .cpu) != .h24 { problems.append("left on the range control did not step back to 24 h, got \(model.range(for: .cpu).rawValue)") }
        }
        model.panelDidClose()
        await closeFixture()
        var note = "sidebar of \(notes.count) of \(SidebarItem.allCases.count) items opened; close button, range buttons and chart label found in the accessibility tree"
        if !problems.isEmpty { note += ". failures: " + problems.joined(separator: "; ") }
        record("M10b", "侧栏控件与图表无障碍", problems.isEmpty, since: t0, note, ["items": Double(notes.count)])
    }

    // MARK: W06, UI part

    func stepW06() async {
        let t0 = now()
        let box = UITestTextBox()
        // The state machine is filled in by WP-B. Until then the gate cannot judge and says so.
        var probe = HoverIntent()
        _ = probe.handle(.moved(.row(.cpu), speed: 0), at: 0)
        if probe.nextDeadline == nil {
            record("W06", "悬停意图（UI 部分）", nil, since: t0, "skipped: HoverIntent is still the A1 skeleton (WP-B fills it in). The 3 synthetic mouse cases run after the merge.")
            return
        }
        var problems = [String]()
        guard let model = await openFixture(.multi, copyBox: box) else {
            record("W06", "悬停意图（UI 部分）", false, since: t0, "the panel did not open")
            return
        }
        // Case 1: a stay of 200 ms does not open, a stay of 450 ms does.
        model.pointerMoved(.row(.cpu), at: CGPoint(x: 100, y: 300))
        await sleepMs(200)
        if model.sidebarItem != nil { problems.append("the sidebar opened after 200 ms") }
        await sleepMs(250)
        if model.sidebarItem != .cpu { problems.append("the sidebar did not open after 450 ms") }
        // Case 2: with the sidebar open, a move to another row switches within 200 ms (the limit is 200 ms plus 20 ms of margin).
        // Latency gate: at most 3 attempts, one attempt within the limit passes, the numbers of all attempts are in the note
        // (docs/CI.md, "延迟类门禁的重复测量"). A real regression is slow in every attempt. Case 1 and case 3 are not repeated.
        var switchAttempts = [Double]()
        var switchPassed = false
        for attempt in 1...3 {
            model.pointerMoved(.row(.memory), at: CGPoint(x: 100, y: 340))
            let switched = await waitFor(timeoutMs: 400) { model.sidebarItem == .memory }
            switchAttempts.append(switched ?? -1)
            if let ms = switched, ms <= 200 + 20 { switchPassed = true; break }
            if attempt < 3 {
                // Back to the first row and wait until its sidebar shows, then try again.
                model.pointerMoved(.row(.cpu), at: CGPoint(x: 100, y: 300))
                _ = await waitFor(timeoutMs: 600) { model.sidebarItem == .cpu }
                await sleepMs(300)
            }
        }
        let switchText = switchAttempts.map { $0 < 0 ? "none" : String(Int($0)) }.joined(separator: "/")
        if !switchPassed { problems.append("the switch took \(switchText) ms in 3 attempts (limit 220)") }
        // Leaving the panel closes the sidebar after 1.0 +- 0.1 s.
        let tLeave = now()
        model.pointerLeft()
        let closed = await waitFor(timeoutMs: 1500) { model.sidebarItem == nil }
        let closeSeconds = now() - tLeave
        if closed == nil || abs(closeSeconds - 1.0) > 0.1 + 0.03 { problems.append("the sidebar closed after \(String(format: "%.2f", closeSeconds)) s") }
        // Case 3: a fast pass over 3 rows does not open the sidebar.
        for (i, y) in [300.0, 340.0, 380.0].enumerated() {
            model.pointerMoved(.row(SidebarItem.fixedRows[i]), at: CGPoint(x: 100, y: y))
            await sleepMs(20)
        }
        model.pointerLeft()
        await sleepMs(500)
        if model.sidebarItem != nil { problems.append("a fast pass over 3 rows opened the sidebar") }
        model.panelDidClose()
        await closeFixture()
        var note = "3 synthetic mouse cases on the fixture model: stay 200/450 ms, switch within 200 ms (attempts \(switchText) ms), close after leave \(String(format: "%.2f", closeSeconds)) s, fast pass"
        if !problems.isEmpty { note += ". failures: " + problems.joined(separator: "; ") }
        record("W06", "悬停意图（UI 部分）", problems.isEmpty, since: t0, note, ["closeSeconds": closeSeconds])
    }
}
#endif
