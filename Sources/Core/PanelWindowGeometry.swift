// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The menu bar item position, the visible frame of its screen and the content height (docs/DESIGN_V2.md 10.3, 10.4).
// Output: PanelPlacement (window frames with the sidebar closed and open, sidebar edge), motion constants and the click policy.
// Pos: Pure window geometry for the NSPanel of WP-B (Sources/App/PanelWindow.swift); Foundation only so Linux can test it.
//      Coordinates follow AppKit: y grows upward, the visible frame is below the menu bar. Created by WP-B.

import Foundation

/// A rectangle in points. Same meaning as NSRect, but Foundation only.
struct PanelRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
}

/// Sizes of the window (docs/DESIGN_V2.md 2.2, 10.3).
enum PanelWindowMetrics {
    static let mainWidth = 352.0
    static let sidebarWidth = 320.0
    static let expandedWidth = 672.0
    /// Gap between the menu bar and the top edge of the panel.
    static let topGap = 4.0
    /// Smallest distance to the left and right edge of the visible frame.
    static let screenMargin = 8.0
    static let cornerRadius = 12.0
    /// Room the sidebar needs next to the main column: sidebar width plus margin (328 pt).
    static var sidebarRoom: Double { sidebarWidth + screenMargin }
}

/// Where the panel stands. The main column keeps its screen position while the sidebar opens (except in the narrow case).
struct PanelPlacement: Equatable {
    /// Side on which the sidebar opens. Fixed while the panel is open (docs/DESIGN_V2.md 10.4).
    var edge: SidebarEdge
    /// Window frame with the sidebar closed: the main column only.
    var collapsed: PanelRect
    /// Window frame with the sidebar open: main column plus sidebar.
    var expanded: PanelRect
    /// Movement of the main column when the sidebar opens. 0 unless the screen is narrower than 688 pt (10.4 rule 4).
    var mainShift: Double
    /// Top edge of the window (y of the top). It stays fixed when the height changes (docs/DESIGN_V2.md 2.3 rule 3).
    var top: Double

    /// x of the main column inside the window for a window of the given width: the sidebar is on one side of it.
    func mainOffsetInWindow(sidebarOpen: Bool) -> Double {
        (edge == .left && sidebarOpen) ? PanelWindowMetrics.sidebarWidth : 0
    }
}

enum PanelWindowGeometry {
    /// Computes the placement.
    /// - anchorMidX: x of the center of the menu bar item (screen coordinates).
    /// - anchorMinY: y of the lower edge of the menu bar item.
    /// - visible: the visible frame of the screen that holds the item.
    /// - height: the content height of the main column.
    static func place(anchorMidX: Double, anchorMinY: Double, visible: PanelRect, height: Double) -> PanelPlacement {
        let w = PanelWindowMetrics.mainWidth
        let margin = PanelWindowMetrics.screenMargin
        // Rule 3 and 4: center on the item, then clamp into the visible frame with 8 pt on both sides.
        let low = visible.minX + margin
        let high = visible.maxX - margin - w
        var mainX = anchorMidX - w / 2
        if high >= low {
            mainX = min(max(mainX, low), high)
        } else {
            mainX = visible.minX
        }
        // Rule 2: the top edge is 4 pt below the menu bar. The visible frame already ends at the menu bar.
        let top = min(anchorMinY, visible.maxY) - PanelWindowMetrics.topGap
        let h = max(0, min(height, top - visible.minY))
        let collapsed = PanelRect(x: mainX, y: top - h, width: w, height: h)

        let rightRoom = visible.maxX - (mainX + w)
        let leftRoom = mainX - visible.minX
        let need = PanelWindowMetrics.sidebarRoom
        var edge = SidebarEdge.left
        var shift = 0.0
        if rightRoom >= need {
            edge = .right
        } else if leftRoom >= need {
            edge = .left
        } else {
            // Narrow screen: the side with more room wins, the main column moves by the smallest amount.
            if rightRoom > leftRoom {
                edge = .right
                let overflow = (mainX + PanelWindowMetrics.expandedWidth) - (visible.maxX - margin)
                shift = -max(0, overflow)
            } else {
                edge = .left
                let expandedX = mainX - PanelWindowMetrics.sidebarWidth
                let deficit = (visible.minX + margin) - expandedX
                shift = max(0, deficit)
            }
        }
        var expandedX = (edge == .right) ? mainX + shift : mainX + shift - PanelWindowMetrics.sidebarWidth
        // A screen narrower than the window: keep the window inside the visible frame as far as possible.
        if expandedX + PanelWindowMetrics.expandedWidth > visible.maxX { expandedX = visible.maxX - PanelWindowMetrics.expandedWidth }
        if expandedX < visible.minX { expandedX = visible.minX }
        let expanded = PanelRect(x: expandedX, y: collapsed.y, width: PanelWindowMetrics.expandedWidth, height: h)
        return PanelPlacement(edge: edge, collapsed: collapsed, expanded: expanded, mainShift: shift, top: top)
    }

    /// The same placement for a new content height. The top edge stays, the bottom edge moves (docs/DESIGN_V2.md 2.3 rule 3).
    /// `minY` is the lower limit of the visible frame.
    static func resized(_ p: PanelPlacement, height: Double, minY: Double) -> PanelPlacement {
        let h = max(0, min(height, p.top - minY))
        var out = p
        out.collapsed.height = h
        out.collapsed.y = p.top - h
        out.expanded.height = h
        out.expanded.y = p.top - h
        return out
    }

    /// The frame for a state of the sidebar.
    static func frame(_ p: PanelPlacement, sidebarOpen: Bool) -> PanelRect {
        sidebarOpen ? p.expanded : p.collapsed
    }

    /// Screen x of the main column in a state of the sidebar.
    static func mainColumnX(_ p: PanelPlacement, sidebarOpen: Bool) -> Double {
        let f = frame(p, sidebarOpen: sidebarOpen)
        return f.x + p.mainOffsetInWindow(sidebarOpen: sidebarOpen)
    }
}

// MARK: - Motion constants

/// Durations and curves of the window (docs/DESIGN_V2.md 3.7, 10.5). The App layer turns them into animation objects.
enum WindowMotion {
    static let openDuration = 0.160
    static let openRise = 4.0
    static let closeDuration = 0.120
    static let sideOpenDuration = 0.220
    static let sideCloseDuration = 0.180
    /// The sidebar content fades in this long after the expansion starts (10.5 rule 4).
    static let sideContentDelay = 0.060
    static let sideContentFade = 0.120
    /// Reduce Motion: sidebar content fade (10.5 last paragraph).
    static let reduceMotionFade = 0.150
    /// Control points of the cubic Bezier curves (x1, y1, x2, y2).
    static let sideOpenCurve: [Double] = [0.2, 0.8, 0.2, 1.0]
    static let sideCloseCurve: [Double] = [0.4, 0.0, 1.0, 1.0]

    /// Duration of the window resize. Reduce Motion gives 0 (no animation).
    static func sideDuration(open: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        return open ? sideOpenDuration : sideCloseDuration
    }
}

// MARK: - Click policy

/// Decides what the local mouse monitor does with a click (docs/DESIGN_V2.md 10.7 table, rule 2 and 3).
enum PanelClickPolicy {
    enum Decision: Equatable { case keepOpen, close }

    /// The click goes to a window of this app. Inside the panel, a child window of the panel (the "…" menu), a system menu
    /// window and the window of the menu bar item do not close the panel. Every other window of the app does.
    static func local(isPanelWindow: Bool, isChildOfPanel: Bool, isMenuWindow: Bool, isStatusItemWindow: Bool) -> Decision {
        (isPanelWindow || isChildOfPanel || isMenuWindow || isStatusItemWindow) ? .keepOpen : .close
    }

    /// The global monitor only sees clicks that go to other apps. Every one of them closes the panel.
    static func global() -> Decision { .close }
}
