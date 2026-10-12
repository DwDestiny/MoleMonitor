// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel and the item whose sidebar is open.
// Output: The sidebar column (320 pt wide): header, range, chart, stats, capacity, ranking, footnote.
// Pos: Right or left column of the panel (docs/DESIGN_V2.md 6). It is built only while the sidebar is open, so closing releases it.

import AppKit
import SwiftUI

// MARK: - Icons

/// App icons by bundle id, kept for the life of the process. Static renders skip the lookup, so previews stay the same everywhere.
enum AppIconCache {
    private static let lock = NSLock()
    private static var icons = [String: NSImage]()
    private static var missing = Set<String>()

    static func icon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = icons[bundleID] { return hit }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[bundleID] = image
        return image
    }
}

struct AppIconView: View {
    let app: AppUsage
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    private var symbol: String {
        if app.isSystem { return "gearshape" }
        return app.bundleID == nil ? "terminal" : "app"
    }

    var body: some View {
        Group {
            if !snapshot, let image = AppIconCache.icon(bundleID: app.bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tok.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar (placeholder until C2)

struct PanelSidebarView: View {
    @ObservedObject var model: PanelModel
    let item: SidebarItem
    @Environment(\.tok) private var tok

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.label)
                .font(PanelType.sideTitle)
                .foregroundStyle(tok.textPrimary)
                .frame(height: 44, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PanelMetrics.sidebarPadding)
        .frame(width: PanelMetrics.sidebarWidth, alignment: .topLeading)
        .accessibilityIdentifier("sidebar")
    }
}
