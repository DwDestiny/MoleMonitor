// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Calls from the panel content (WP-C) and from the window and notification code (WP-B).
// Output: Two protocols: PanelChrome (the window serves the content), PanelPinning (the content serves the window).
// Pos: A1 contract between the NSPanel window and the SwiftUI panel content (docs/DESIGN_V2.md 14.2, 14.3).
//      Protocols only, no AppKit type, so the file also type-checks on Linux. A1 creates it, WP-B owns it after the A1 merge.
//      WP-B implements PanelChrome. WP-C implements PanelPinning in PanelModel.

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
}

/// What the content gives to the window. The notification click (R-14) and a click on a row call it.
@MainActor
protocol PanelPinning: AnyObject {
    func pinSidebar(_ item: SidebarItem)
    func unpinSidebar()
}
