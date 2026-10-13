// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The UI regression runner (UITestHarness.swift), the live sidebar of PanelSidebarView (frames side.content, side.scroll, side.fade).
// Output: Gate W23 (docs/DESIGN_V2.md 6): on the 7 sidebar pages, at the laptop height (524 pt) all content is visible and no fade shows.
//         At the desktop height (484 pt) the fade shows exactly when the content is taller than the room.
// Pos: Test code. It exists only in the UITEST build. scripts/build.py finds the marker line below and registers it.
//
// UITEST-REGISTER: UITestSidebarChecks

#if UITEST
import AppKit
import Foundation

@MainActor
enum UITestSidebarChecks {
    static func register(into registry: UITestRegistry) {
        registry.add("W23", "sidebar content visible or faded") { runner in await runner.stepW23() }
    }
}

extension UITestRunner {
    /// A panel with the `multi` fixture. `desktop` removes the battery (the power verdict is "not applicable"), which gives 484 pt.
    func openSidebarFixture(desktop: Bool, copyBox: UITestTextBox) async -> PanelModel? {
        var data = PanelModel.fixtureData(.multi, full: true, now: Date())
        if desktop {
            data.verdicts = data.verdicts.map { v in
                var copy = v
                if v.item == .power { copy.level = .notApplicable }
                return copy
            }
        }
        let model = PanelModel(data: data)
        model.testDrive = true
        model.onCopyText = { text in
            copyBox.value = text
            return true
        }
        delegate.testModel = model
        let opened = await openPanel(offsets: [], via: .sendAction, holdMs: 750, prefix: "w23-" + (desktop ? "desktop" : "laptop"))
        guard opened != nil else {
            delegate.testModel = nil
            return nil
        }
        return model
    }

    func stepW23() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        var overflowing = 0
        let box = UITestTextBox()
        let items: [SidebarItem] = [.cpu, .memory, .disk, .network, .battery, .thermal, .anomalyLog]
        for desktop in [false, true] {
            let tier = desktop ? 484.0 : 524.0
            let label = desktop ? "484 pt" : "524 pt"
            guard let model = await openSidebarFixture(desktop: desktop, copyBox: box), let hv = hostView else {
                problems.append("\(label): the panel did not open")
                continue
            }
            let height = Double(hv.bounds.height)
            if abs(height - tier) > 1 { problems.append("\(label): the window is \(height) pt high") }
            for id in ["side.content", "side.scroll", "side.fade"] { UITestFrameStore.shared.remove(id) }
            for item in items {
                guard await openSidebar(model, item) else { problems.append("\(label) \(item.rawValue): the sidebar did not open"); continue }
                await sleepMs(350)
                guard let content = sideRect("side.content"), let scroll = sideRect("side.scroll") else {
                    problems.append("\(label) \(item.rawValue): no content or scroll frame")
                    continue
                }
                let fade = sideRect("side.fade")
                let tall = Double(content.height), room = Double(scroll.height)
                // The scroll area is the window height without the 44 pt header and the 28 pt range control.
                if abs(room - (tier - 72)) > 1.5 { problems.append("\(label) \(item.rawValue): room \(room) pt, expected \(tier - 72)") }
                if desktop {
                    let overflow = tall > room + 0.5
                    if overflow { overflowing += 1 }
                    if overflow && fade == nil { problems.append("\(label) \(item.rawValue): content \(Int(tall)) pt in \(Int(room)) pt, no fade") }
                    if !overflow && fade != nil { problems.append("\(label) \(item.rawValue): content fits but the fade shows") }
                } else {
                    if tall > room + 0.5 { problems.append("\(label) \(item.rawValue): content \(Int(tall)) pt is cut at \(Int(room)) pt") }
                    if fade != nil { problems.append("\(label) \(item.rawValue): a fade shows although the content fits") }
                }
                notes.append("\(label) \(item.rawValue) \(Int(tall))/\(Int(room))" + (fade != nil ? " fade" : ""))
            }
            model.panelDidClose()
            await closeFixture()
        }
        if overflowing == 0 { problems.append("no page is taller than the 484 pt room, so the fade was never tested") }
        var note = notes.joined(separator: ", ") + "."
        if !problems.isEmpty { note += " failures: " + problems.prefix(12).joined(separator: "; ") }
        let values: [String: Double] = ["problems": Double(problems.count), "overflowingAt484": Double(overflowing)]
        record("W23", "sidebar content visible or faded", problems.isEmpty && !notes.isEmpty, since: t0, note, values)
    }
}
#endif
