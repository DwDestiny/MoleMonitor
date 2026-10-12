// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: An output path prefix from `--preview <prefix>` and the invented fixtures of PreviewScenario.
// Output: PNG files. Main column: `<prefix>-<case>-<light|dark>[-empty].png`, 352 pt wide at scale 2, one per case x scheme x full and empty data.
//         Sidebar: `<prefix>-side-<item>-<light|dark>.png`, 672 pt wide, six items plus the anomaly log, on the `multi` case.
// Pos: Static preview of the panel (docs/DESIGN_V2.md 13.3 W01). It renders with ImageRenderer in snapshot mode (no ScrollView, no Menu),
//      at scale 2, on the explicit surface color of the scheme. The data is invented. No real user data is shown.
//      PreviewOverlay adds the v2 fields that PreviewScenario does not have yet (pressure percent, memory split, rollups, records).
//      PreviewScenario now fills memory, pressure and records. The overlay keeps only rollups, interfaces, disk writers, sleep blockers.

import AppKit
import SwiftUI

// MARK: - Overlay

/// Invented values for the fields that the shared fixture lacks. Deterministic: no random numbers, no clock.
enum PreviewOverlay {
    static func apply(_ input: PanelData, full: Bool) -> PanelData {
        var d = input
        d.current = PanelEngineAdapter.withDiskTriple(d.current, status: d.status)
        guard full else { return d }
        // DESIGN_V2.md 2.6: while collecting, the items that already have a live value show it (CPU and battery here).
        if d.isCollecting {
            d.current.cpuPercent = 23
            d.current.batteryPercent = 82
            d.current.powerSource = .battery
            return d
        }
        d.rollups = rollups(now: d.now)
        d.interfaces = [InterfaceRate(name: "en0", displayName: "Wi-Fi", rxPerSecond: 1_100_000, txPerSecond: 96_000,
                                      rxTotal: 48_000_000_000, txTotal: 6_000_000_000),
                        InterfaceRate(name: "en5", displayName: "以太网", rxPerSecond: 2_000, txPerSecond: 800,
                                      rxTotal: 1_200_000_000, txTotal: 300_000_000)]
        d.diskWriters = [DiskWriterRow(key: "build", name: "Xcode", bundleID: "com.apple.dt.Xcode", bytes: 4_200_000_000, isSystem: false),
                         DiskWriterRow(key: "photos", name: "照片", bundleID: "com.apple.Photos", bytes: 1_100_000_000, isSystem: false),
                         DiskWriterRow(key: "spotlight", name: "mds_stores", bundleID: nil, bytes: 340_000_000, isSystem: true)]
        d.sleepBlockers = [SleepBlocker(name: "Zoom", preventsSystemSleep: true, preventsDisplaySleep: true)]
        return d
    }

    /// 7 days of 5 minute windows.
    static func rollups(now: Date) -> [RollupWindow] {
        let count = 7 * 288
        var out = [RollupWindow]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let age = Double(count - 1 - i)
            let end = now.addingTimeInterval(-age * 300)
            let hour = age / 12
            let cpu = 22 + 14 * sin(hour * 0.9) + 6 * sin(hour * 3.1)
            let pressure = 24 + 8 * sin(hour * 0.5) + (hour > 40 && hour < 46 ? 30 : 0)
            out.append(RollupWindow(end: end, pointCount: 10, cpuMean: cpu, cpuPeak: min(100, cpu * 1.8),
                                    pressureMean: pressure, pressurePeak: min(100, pressure * 1.2),
                                    swapMB: Int64(900 + 600 * sin(hour * 0.3) + 500), pressure: pressure > 55 ? .warning : .normal,
                                    thermal: .nominal, batteryPercent: 80 - 20 * sin(hour * 0.2), power: .battery,
                                    rxKBps: max(0, 600 + 500 * sin(hour * 1.7)), txKBps: max(0, 90 + 60 * sin(hour * 2.3))))
        }
        return out
    }
}

// MARK: - Render

@MainActor
enum PanelPreview {
    /// The six breakdown items and the anomaly log that get a sidebar preview.
    static let sidebarItems: [SidebarItem] = SidebarItem.allCases

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
        for item in sidebarItems {
            for scheme in ["light", "dark"] {
                names.append(prefix + "-side-" + item.rawValue + "-" + scheme + ".png")
            }
        }
        return names
    }

    /// The static view of one model on the surface color of a scheme. The width is 352 pt, or 672 pt with a sidebar.
    static func staticView(model: PanelModel, dark: Bool) -> some View {
        let scheme: ColorScheme = dark ? .dark : .light
        let width = model.sidebarItem == nil ? PanelMetrics.width : PanelMetrics.widthWithSidebar
        return PanelRoot(model: model, entrance: .none)
            .frame(width: width, height: model.layoutPlan.height, alignment: .topLeading)
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

    /// Renders all files. `output` is the prefix path, for example `/dir/preview.png` gives `/dir/preview-allGreen-light.png`.
    /// Returns an error text, or nil on success.
    static func render(to output: URL) -> String? {
        let base = output.deletingPathExtension()
        let directory = base.deletingLastPathComponent()
        let now = Date()
        func write(_ data: Data, _ name: String) -> Bool {
            let target = directory.appendingPathComponent(name).appendingPathExtension("png")
            do {
                try data.write(to: target, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        for empty in [false, true] {
            for c in PreviewCase.allCases {
                let model = PanelModel.fixture(c, full: !empty, now: now)
                for dark in [false, true] {
                    guard let data = png(model: model, dark: dark) else { return "Preview rendering is not available." }
                    let name = base.lastPathComponent + "-" + c.rawValue + "-" + (dark ? "dark" : "light") + (empty ? "-empty" : "")
                    if !write(data, name) { return "Cannot write the preview file." }
                }
            }
        }
        for item in sidebarItems {
            let model = PanelModel.fixture(.multi, full: true, now: now)
            model.pinSidebar(item)
            for dark in [false, true] {
                guard let data = png(model: model, dark: dark) else { return "Preview rendering is not available." }
                let name = base.lastPathComponent + "-side-" + item.rawValue + "-" + (dark ? "dark" : "light")
                if !write(data, name) { return "Cannot write the preview file." }
            }
        }
        return nil
    }
}
