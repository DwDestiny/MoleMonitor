// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The fixtures of PanelModel (diskRed, allGreen) and the UI test runner's output directory.
// Output: preview-stamp-{light,dark}.png (solid button, diskRed) and preview-stamp-quiet-{light,dark}.png (text button, allGreen):
//         the panel at the landed frame of the paw stamp (docs/DESIGN_V3.md 5.6), 352 pt wide at scale 2, in the UI test output folder.
// Pos: UI test build only (-D UITEST). The plain `--preview` binary has no copied state, so the stamp needs this entry.
//      It goes through the real copy path (`PanelModel.copy`) with a clipboard stub, renders with PanelPreview.png, then clears the state.
//      It records no gate: the frames are for the screenshot review. Normal runs do not compile this file.
// UITEST-REGISTER: UITestStampChecks

#if UITEST
import AppKit
import Foundation

@MainActor
enum UITestStampChecks {
    static func register(into registry: UITestRegistry) {
        registry.add("P5", "paw stamp preview frames") { runner in UITestStampChecks.writeStampFrames(to: runner.outDir) }
    }

    static func writeStampFrames(to dir: URL) {
        let cases: [(PreviewCase, String)] = [(.diskRed, "preview-stamp"), (.allGreen, "preview-stamp-quiet")]
        for (c, name) in cases {
            let model = PanelModel.fixture(c, full: true, now: Date())
            model.onCopyText = { _ in true }
            model.copy(.primary)
            for dark in [false, true] {
                guard let data = PanelPreview.png(model: model, dark: dark) else { continue }
                let file = dir.appendingPathComponent(name + "-" + (dark ? "dark" : "light") + ".png")
                try? data.write(to: file, options: .atomic)
            }
            model.cancelPending()
        }
    }
}
#endif
