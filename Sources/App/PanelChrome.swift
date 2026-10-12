// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Calls from the panel content (WP-C) and from the window and notification code (WP-B).
// Output: Two protocols: PanelChrome (the window serves the content), PanelPinning (the content serves the window).
// Pos: A1 contract between the NSPanel window and the SwiftUI panel content (docs/DESIGN_V2.md 14.2, 14.3).
//      Protocols only, no AppKit type, so the file also type-checks on Linux. A1 creates it, WP-B owns it after the A1 merge.
//      WP-B implements PanelChrome (PanelWindow). WP-C implements PanelPinning in PanelModel and calls reportHover, reportClick,
//      reportCloseButton on the PanelChrome it receives. The three report calls and previewSidebar were added by WP-B with default no-op bodies.

import Foundation

/// What the window gives to the content.
@MainActor
protocol PanelChrome: AnyObject {
    /// Opens or closes the sidebar. The window animates its frame (DESIGN_V2.md 10.5) when `animated` is true.
    func setSidebar(open: Bool, animated: Bool)
    /// Side on which the sidebar opens. Fixed while the panel is open (10.4).
    var sidebarEdge: SidebarEdge { get }
    /// Closes the whole panel.
    func closePanel()
    /// True when the system setting "Reduce motion" is on.
    var isReduceMotion: Bool { get }
    /// Added by WP-B: hover and click reports from the content (default: no-op, see the extension below).
    func reportHover(_ region: HoverRegion)
    func reportClick(_ item: SidebarItem)
    func reportCloseButton()
}

/// What the content gives to the window. The notification click (R-14) and a click on a row call it.
@MainActor
protocol PanelPinning: AnyObject {
    func pinSidebar(_ item: SidebarItem)
    func unpinSidebar()
    /// Added by WP-B: hover preview without pinning (default: no-op, see the extension below).
    func previewSidebar(_ item: SidebarItem?)
}

// MARK: - Additions of WP-B (default no-op, so a conforming type that ignores them still compiles)

extension PanelChrome {
    /// The content tells the window where the pointer is (a row, the anomaly bar, the neutral zone). The window adds the pointer
    /// speed and the region of the sidebar itself, and runs the hover rules of DESIGN_V2.md 10.6. Call it when the region changes.
    func reportHover(_ region: HoverRegion) {}
    /// A click or a Return/Right key on a row or on the anomaly bar. The window pins the sidebar of that item, or closes it when
    /// the item is pinned already (DESIGN_V2.md 5.6).
    func reportClick(_ item: SidebarItem) {}
    /// A click on the `xmark` of the sidebar.
    func reportCloseButton() {}
}

extension PanelPinning {
    /// Hover preview: the sidebar shows `item` without pinning it. Nil clears it when the sidebar closes.
    func previewSidebar(_ item: SidebarItem?) {}
}
