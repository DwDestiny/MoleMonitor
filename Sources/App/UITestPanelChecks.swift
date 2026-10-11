// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the fixtures of PreviewScenario and the real popover of AppDelegate.
// Output: The panel gates of docs/DESIGN.md 9.2: M2 order, M3 height tiers, M4 stable size, M5 contrast (Q1), M6 large type (Q2),
//         M11 no focus ring (Q9), M12 first frame with a curve, M13 copy (the part that fixtures can check).
// Pos: Test code. It exists only in the UITEST build. The release binary has none of it (checked by scripts/ci_acceptance.py).
//      Each scenario opens the real popover with a fixture model. The engine is not attached, so the data is the invented fixture.

#if UITEST
import AppKit
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
    func contrastTargets(_ model: PanelModel) -> [(id: String, minimum: Double)] {
        var out = [(id: String, minimum: Double)]()
        let text = ["txt.hero.title", "txt.hero.subtitle", "txt.card.title", "txt.card.figure", "txt.card.caption",
                    "txt.card.duration", "txt.summary", "txt.footer.time", "txt.cta.label", "label.authorization",
                    "txt.disclosure.title.apps", "txt.disclosure.preview.apps", "txt.disclosure.title.more",
                    "txt.disclosure.preview.more", "txt.disk.available", "txt.trend.empty"]
        for id in text { out.append((id, 4.5)) }
        for v in model.data.verdicts {
            out.append(("txt.row.title." + v.item.rawValue, 4.5))
            out.append(("txt.row.detail." + v.item.rawValue, 4.5))
            out.append(("lamp." + v.item.rawValue, 3.0))
        }
        for id in ["chart.cpu", "chart.net", "chart.problem", "chart.disk"] { out.append((id, 3.0)) }
        return out
    }

    // MARK: Entry

    func stepM() async {
        let t0 = now()
        // The J step leaves the real panel open. Close it, so each fixture opens its own popover.
        await closePanelQuietly()
        var orderProblems = [String]()
        var heightNotes = [String]()
        var heightProblems = [String]()
        var contrastProblems = [String]()
        var contrastMin = [String: Double]()
        var measuredCount = 0
        var ringProblems = [String]()
        var ringNotes = [String]()
        var stableProblems = [String]()
        var stableNotes = [String]()
        let copyBox = UITestTextBox()
        var tierByCase = [String: Double]()

        for c in PreviewCase.allCases {
            guard let model = await openFixture(c, copyBox: copyBox), let hv = hostView else {
                orderProblems.append("\(c.rawValue): the panel did not open")
                continue
            }
            let name = c.rawValue
            let plan = model.layoutPlan

            // M2: the order of the blocks equals the plan, from the layout registry
            var lastY = -Double.infinity
            var missing = [String]()
            for section in plan.sections {
                guard let frame = UITestFrameStore.shared.get("sec." + section.key) else { missing.append(section.key); continue }
                if Double(frame.minY) < lastY - 0.5 { orderProblems.append("\(name): \(section.key) is above its predecessor") }
                lastY = Double(frame.minY)
            }
            if !missing.isEmpty { orderProblems.append("\(name): no frame for \(missing.joined(separator: ","))") }
            let problems = ProblemOrder.problems(model.data.verdicts).map { $0.item }
            if problems.isEmpty {
                if plan.sections.contains(where: { $0.key.hasPrefix("card.") }) { orderProblems.append("\(name): quiet mode has a problem card") }
            } else {
                var shown = [HealthItem]()
                for section in plan.sections {
                    if case .problemCard(let item, _, _) = section { shown.append(item) }
                    if case .problemRow(let item, _) = section { shown.append(item) }
                }
                if shown != problems {
                    let shownNames: [String] = shown.map { $0.rawValue }
                    let wantedNames: [String] = problems.map { $0.rawValue }
                    orderProblems.append(name + ": card and rows " + shownNames.joined(separator: ",") + " differ from ProblemOrder " + wantedNames.joined(separator: ","))
                }
                if plan.sections.count > 1, !plan.sections[1].key.hasPrefix("card.") { orderProblems.append("\(name): the card is not right after the hero") }
            }
            let lampItems = model.data.lamps.map { $0.item }
            var lampFrames = [(item: HealthItem, rect: CGRect)]()
            for item in lampItems {
                if let r = UITestFrameStore.shared.get("lamp." + item.rawValue) { lampFrames.append((item, r)) }
            }
            lampFrames.sort { a, b in
                let ay = (Double(a.rect.minY) / 4).rounded(), by = (Double(b.rect.minY) / 4).rounded()
                return ay != by ? ay < by : a.rect.minX < b.rect.minX
            }
            if lampFrames.map({ $0.item }) != lampItems { orderProblems.append("\(name): the lamp order differs from ProblemOrder.all") }

            // M3: the height is one of the three tiers
            let height = Double(hv.bounds.height)
            let expected = problems.isEmpty ? PanelMetrics.heightQuiet : (problems.count == 1 ? PanelMetrics.heightSingle : PanelMetrics.heightMulti)
            tierByCase[name] = height
            heightNotes.append("\(name)=\(Int(height))")
            if abs(height - expected) > 1 { heightProblems.append("\(name): \(height) pt, expected \(expected) pt") }

            // M11 and Q9: no first-responder button, no focus ring pixels around the quit button
            let responder = hv.window?.firstResponder
            let responderName = responder.map { String(describing: type(of: $0)) } ?? "nil"
            if responder is NSControl { ringProblems.append("\(name): first responder is \(responderName)") }
            if let quit = panelRect("btn.quit"), let shot = capture(hv) {
                let ring = focusRingPixels(shot, around: quit, margin: 4)
                ringNotes.append("\(name): responder \(responderName), ring pixels \(ring)")
                if ring > 0 { ringProblems.append("\(name): \(ring) focus ring pixels near btn.quit") }
            } else {
                ringProblems.append("\(name): no frame for btn.quit")
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
                for target in contrastTargets(model) {
                    guard let rect = panelRect(target.id), rect.width > 2, rect.height > 2 else { continue }
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

            // M13 (part): the copy action on the fixture model. It runs before M4, which scrolls the CTA away.
            if c == .diskRed {
                await stepCopy(model: model, hv: hv, box: copyBox)
            }

            // M4: a stable size (the real popover, fixture data)
            if c == .multi || c == .cpuYellow || c == .diskRed {
                let h0 = Double(hv.bounds.height)
                var changes = 0
                for i in 1...10 {
                    model.load(c, full: true, now: Date().addingTimeInterval(Double(i) * 30))
                    await sleepMs(60)
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                }
                let rows = model.layoutPlan.sections.compactMap { section -> HealthItem? in
                    if case .problemRow(let item, _) = section { return item }
                    return nil
                }
                if let row = rows.first {
                    model.toggleProblem(row)
                    await sleepMs(500)
                    if model.openItem != row { stableProblems.append("\(name): the clicked row did not open") }
                    if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                }
                model.setApps(expanded: true)
                await sleepMs(400)
                if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                model.setMore(expanded: true)
                await sleepMs(400)
                if abs(Double(hv.bounds.height) - h0) > 0.5 { changes += 1 }
                stableNotes.append("\(name): 10 refreshes, 1 row click, 2 disclosures, height \(Int(h0)) pt, changes \(changes)")
                if changes > 0 { stableProblems.append("\(name): the height changed \(changes) time(s)") }
            }

            await closeFixture()
        }

        let heightCount = tierByCase.count
        let quietMax = ["allGreen", "collecting", "stale"].compactMap { tierByCase[$0] }.max() ?? 0
        let problemMin = ["cpuYellow", "diskRed", "powerYellow", "multi"].compactMap { tierByCase[$0] }.min() ?? 0
        let gapOk = quietMax > 0 && problemMin - quietMax >= 200

        var note2 = "all 7 scenarios: the block order in the layout registry equals the plan. "
        note2 += "Quiet mode has no card. The card follows the hero. Card and rows follow ProblemOrder. The lamp order equals ProblemOrder.all."
        if !orderProblems.isEmpty { note2 = orderProblems.joined(separator: "; ") }
        let values2: [String: Double] = ["scenarios": Double(PreviewCase.allCases.count), "problems": Double(orderProblems.count)]
        record("M2", "区块顺序（Q6）", orderProblems.isEmpty, since: t0, note2, values2)

        var note3 = "popover content heights " + heightNotes.joined(separator: ", ")
        note3 += "; quiet at most \(Int(quietMax)) pt, smallest problem card \(Int(problemMin)) pt"
        note3 += ", difference \(Int(problemMin - quietMax)) pt (needs at least 200)"
        if !heightProblems.isEmpty { note3 += "; " + heightProblems.joined(separator: "; ") }
        let values3: [String: Double] = ["quietMax": quietMax, "problemMin": problemMin]
        record("M3", "版面高度三档（Q5）", heightProblems.isEmpty && gapOk && heightCount == 7, since: t0, note3, values3)

        var note4 = stableNotes.joined(separator: "; ")
        if !stableProblems.isEmpty { note4 += "; " + stableProblems.joined(separator: "; ") }
        let values4: [String: Double] = ["problems": Double(stableProblems.count)]
        record("M4", "尺寸稳定（Q5）", stableProblems.isEmpty && !stableNotes.isEmpty, since: t0, note4, values4)

        let lowest = contrastMin.sorted { $0.value < $1.value }.prefix(6)
        var worstParts = [String]()
        for entry in lowest { worstParts.append(entry.key + " " + String(format: "%.2f", entry.value)) }
        var note5 = "\(measuredCount) regions measured in 7 scenarios x light and dark (text >= 4.5, lamps and curves >= 3); "
        note5 += "lowest ratios: " + worstParts.joined(separator: ", ")
        if !contrastProblems.isEmpty { note5 += "; failures: " + contrastProblems.prefix(12).joined(separator: "; ") }
        let values5: [String: Double] = ["regions": Double(measuredCount), "failures": Double(contrastProblems.count),
                                         "lowest": contrastMin.values.min() ?? 0]
        record("M5", "对比度（Q1）", contrastProblems.isEmpty && measuredCount > 100, since: t0, note5, values5)

        var note11 = ringNotes.joined(separator: "; ")
        if !ringProblems.isEmpty { note11 += "; failures: " + ringProblems.joined(separator: "; ") }
        let values11: [String: Double] = ["problems": Double(ringProblems.count)]
        record("M11", "无焦点环（Q9）", ringProblems.isEmpty && !ringNotes.isEmpty, since: t0, note11, values11)
        stepLargeType()
        await stepColdFirstFrame(copyBox: copyBox)
    }

    /// Pixels near the system focus ring color in the ring zone around a frame (`margin` points outside the frame, plus the frame).
    func focusRingPixels(_ shot: UITestShot, around frame: CGRect, margin: CGFloat) -> Int {
        let outer = frame.insetBy(dx: -margin, dy: -margin)
        let box = UITestPixels.pixelRegion(outer, of: shot)
        let color = NSColor.keyboardFocusIndicatorColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        let fr: Double = Double(color.redComponent) * 255
        let fg: Double = Double(color.greenComponent) * 255
        let fb: Double = Double(color.blueComponent) * 255
        var count = 0
        guard box.x1 > box.x0, box.y1 > box.y0 else { return 0 }
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
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
        let rect = panelRect("btn.copy.primary")
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
        note += "The text comes from the PromptBuilder skeleton until I1 lands."
        let values: [String: Double] = ["copiedSeconds": seconds, "changedShare": changed, "textLength": Double(text.count)]
        record("M13", "复制状态机", ok, since: t0, note, values)
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
                let width = Double(string.size().width)
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
            if let hv = hostView, let rect = panelRect("chart.cpu"), rect.width > 20, rect.height > 10, let shot = capture(hv) {
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
        var note = "no frame with line pixels in chart.cpu within 800 ms"
        if found {
            note = "the first frame with line pixels in chart.cpu came " + String(format: "%.0f", elapsed)
            note += " ms after the show call (limit 300 ms), \(ink) line pixels"
        }
        let values: [String: Double] = ["firstFrameMs": elapsed, "inkPixels": Double(ink)]
        record("M12", "冷启动首帧有曲线（Q8）", ok, since: t0, note, values)
    }
}
#endif
