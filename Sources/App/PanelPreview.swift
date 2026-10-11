// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: An output path prefix from `--preview <prefix>` and the invented fixtures of PreviewScenario.
// Output: 28 PNG files named `<prefix>-<case>-<light|dark>[-empty].png`: 7 cases x 2 color schemes x full and empty data.
// Pos: Static preview of the status card. It renders with ImageRenderer in snapshot mode (no ScrollView, no Menu),
//      at scale 2, on the explicit surface color of the scheme. The data is invented. No real user data is shown.

import AppKit
import SwiftUI

@MainActor
enum PanelPreview {
    /// File names for one prefix, in render order.
    static func fileNames(prefix: String) -> [String] {
        var names = [String]()
        for empty in [false, true] {
            for c in PreviewCase.allCases {
                for scheme in ["light", "dark"] {
                    names.append(prefix + "-" + c.rawValue + "-" + scheme + (empty ? "-empty" : "") + ".png")
                }
            }
        }
        return names
    }

    /// The static view of one model on the surface color of a scheme.
    static func staticView(model: PanelModel, dark: Bool) -> some View {
        let scheme: ColorScheme = dark ? .dark : .light
        return PanelRoot(model: model, entrance: .none)
            .frame(width: PanelMetrics.width, height: model.layoutPlan.height)
            .background(PanelTokens.surface(dark: dark))
            .environment(\.colorScheme, scheme)
            .environment(\.panelSnapshot, true)
    }

    /// PNG data of one model, or nil when the renderer gives no image.
    static func png(model: PanelModel, dark: Bool) -> Data? {
        let renderer = ImageRenderer(content: staticView(model: model, dark: dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Renders all 28 files. `output` is the prefix path, for example `/dir/preview.png` gives `/dir/preview-allGreen-light.png`.
    /// Returns an error text, or nil on success.
    static func render(to output: URL) -> String? {
        let base = output.deletingPathExtension()
        let directory = base.deletingLastPathComponent()
        let now = Date()
        for empty in [false, true] {
            for c in PreviewCase.allCases {
                let model = PanelModel.fixture(c, full: !empty, now: now)
                for dark in [false, true] {
                    guard let data = png(model: model, dark: dark) else {
                        return "Preview rendering is not available."
                    }
                    let name = base.lastPathComponent + "-" + c.rawValue + "-" + (dark ? "dark" : "light")
                        + (empty ? "-empty" : "")
                    let target = directory.appendingPathComponent(name).appendingPathExtension("png")
                    do {
                        try data.write(to: target, options: .atomic)
                    } catch {
                        return "Cannot write the preview file."
                    }
                }
            }
        }
        return nil
    }
}
