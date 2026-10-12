// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Pointer and clock events from the panel window (docs/DESIGN_V2.md 10.6), with the time of each event.
// Output: HoverCommand values: open, switch, close, pin or unpin the sidebar. nextDeadline tells the window when to call fire(at:).
// Pos: Pure hover-intent state machine (gate W06, Core part). Foundation only, no clock, no timer: the caller passes the time
//      (seconds on any monotonic clock) and schedules one cancellable delayed call for `nextDeadline`. Owner WP-B.
//      Rules in short: a row opens the sidebar after 350 ms of rest, a fast pointer restarts that time, a pinned sidebar
//      ignores the pointer, a click pins, Esc and the close button close, the way to the sidebar is tolerated for 300 ms.

import Foundation

/// Where the pointer is.
enum HoverRegion: Equatable {
    case row(SidebarItem)      // A breakdown row or the anomaly bar
    case sidebar
    case neutral               // Hero, anomaly title, footer
    case outside               // Outside the panel
}

enum HoverEvent: Equatable {
    /// `speed` is the pointer speed in pt/ms. `inTriangle` is true while the pointer is inside the triangle that spans from the
    /// last point in the open row to the near edge of the sidebar (see `HoverGeometry`). Default false.
    case moved(HoverRegion, speed: Double, inTriangle: Bool = false)
    case clicked(SidebarItem)
    case escape
    case closeButton
}

enum HoverCommand: Equatable {
    case open(SidebarItem)
    case switchTo(SidebarItem)
    case close
    case pin(SidebarItem)
    case unpin
}

/// Pure state machine. Times are seconds on any monotonic clock chosen by the caller.
struct HoverIntent {
    static let openDelay = 0.350
    static let switchDelay = 0.120
    static let triangleHold = 0.300
    static let neutralCloseDelay = 0.400
    static let leaveCloseDelay = 1.000
    /// Faster than this restarts the open timer (pt/ms).
    static let fastSpeed = 0.6

    private enum Kind { case open, switchTo, closeNeutral, closeLeave }

    private struct Pending {
        var kind: Kind
        var item: SidebarItem?
        var deadline: TimeInterval
    }

    /// The item that the sidebar shows now. Nil when the sidebar is closed.
    private(set) var openItem: SidebarItem?
    /// The item that a click or a notification pinned. A pinned sidebar is always open.
    private(set) var pinnedItem: SidebarItem?
    private var pending: Pending?

    /// The item that a delayed open or switch waits for.
    var pendingItem: SidebarItem? {
        guard let p = pending, p.kind == .open || p.kind == .switchTo else { return nil }
        return p.item
    }

    /// Time at which the caller must call `fire(at:)`. Nil when nothing is pending.
    var nextDeadline: TimeInterval? { pending?.deadline }

    /// True while Esc closes the sidebar. When false, Esc closes the whole panel (docs/DESIGN_V2.md 10.7).
    var consumesEscape: Bool { openItem != nil }

    init() {}

    // MARK: Events

    /// Feeds one event and returns the commands to run now.
    mutating func handle(_ event: HoverEvent, at time: TimeInterval) -> [HoverCommand] {
        switch event {
        case let .moved(region, speed, inTriangle):
            return moved(region, speed: speed, inTriangle: inTriangle, at: time)
        case let .clicked(item):
            return click(item, toggles: true)
        case .escape, .closeButton:
            return closeAll()
        }
    }

    /// Opens and pins an item without a click (a tap on a notification, R-14). A second call for the same item changes nothing.
    mutating func pinExternally(_ item: SidebarItem) -> [HoverCommand] {
        click(item, toggles: false)
    }

    /// Called when `nextDeadline` has passed. Returns the commands of the pending action. An early call returns nothing.
    mutating func fire(at time: TimeInterval) -> [HoverCommand] {
        guard let p = pending, time >= p.deadline else { return [] }
        pending = nil
        switch p.kind {
        case .open:
            guard let item = p.item, pinnedItem == nil else { return [] }
            openItem = item
            return [.open(item)]
        case .switchTo:
            guard let item = p.item, pinnedItem == nil, openItem != nil else { return [] }
            openItem = item
            return [.switchTo(item)]
        case .closeNeutral, .closeLeave:
            guard pinnedItem == nil, openItem != nil else { return [] }
            openItem = nil
            return [.close]
        }
    }

    // MARK: Rules

    private mutating func moved(_ region: HoverRegion, speed: Double, inTriangle: Bool, at t: TimeInterval) -> [HoverCommand] {
        // A pinned sidebar only closes by a click on the same row, the close button or Esc. The pointer changes nothing.
        if pinnedItem != nil {
            pending = nil
            return []
        }
        switch region {
        case let .row(item):
            rowMoved(item, speed: speed, inTriangle: inTriangle, at: t)
        case .sidebar:
            pending = nil
        case .neutral:
            guard openItem != nil else { pending = nil; return [] }
            if pending?.kind != .closeNeutral {
                pending = Pending(kind: .closeNeutral, item: nil, deadline: t + Self.neutralCloseDelay)
            }
        case .outside:
            guard openItem != nil else { pending = nil; return [] }
            if pending?.kind != .closeNeutral && pending?.kind != .closeLeave {
                pending = Pending(kind: .closeLeave, item: nil, deadline: t + Self.leaveCloseDelay)
            }
        }
        return []
    }

    private mutating func rowMoved(_ item: SidebarItem, speed: Double, inTriangle: Bool, at t: TimeInterval) {
        if let open = openItem {
            if item == open {
                pending = nil
                return
            }
            // Another row while the sidebar is open: switch after 120 ms, or after 300 ms on the way to the sidebar.
            let delay = inTriangle ? Self.triangleHold : Self.switchDelay
            if var p = pending, p.kind == .switchTo, p.item == item {
                // Same candidate. Leaving the triangle shortens the wait to the normal switch delay, it never extends it.
                if !inTriangle { p.deadline = min(p.deadline, t + Self.switchDelay) }
                pending = p
            } else {
                pending = Pending(kind: .switchTo, item: item, deadline: t + delay)
            }
            return
        }
        // The sidebar is closed: open after 350 ms of rest. A fast pointer restarts the time.
        if var p = pending, p.kind == .open, p.item == item {
            if speed > Self.fastSpeed { p.deadline = t + Self.openDelay }
            pending = p
        } else {
            pending = Pending(kind: .open, item: item, deadline: t + Self.openDelay)
        }
    }

    private mutating func click(_ item: SidebarItem, toggles: Bool) -> [HoverCommand] {
        pending = nil
        if pinnedItem == item {
            guard toggles else { return [] }
            pinnedItem = nil
            openItem = nil
            return [.unpin, .close]
        }
        var commands = [HoverCommand]()
        if openItem == nil {
            commands.append(.open(item))
        } else if openItem != item {
            commands.append(.switchTo(item))
        }
        openItem = item
        pinnedItem = item
        commands.append(.pin(item))
        return commands
    }

    private mutating func closeAll() -> [HoverCommand] {
        pending = nil
        guard openItem != nil else { return [] }
        var commands = [HoverCommand]()
        if pinnedItem != nil { commands.append(.unpin) }
        openItem = nil
        pinnedItem = nil
        commands.append(.close)
        return commands
    }
}

// MARK: - Pointer geometry

/// A point in the window, in points. The window converts its mouse location to it.
struct HoverPoint: Equatable {
    var x: Double
    var y: Double
}

/// Geometry helpers for the pointer: its speed and the triangle toward the sidebar (docs/DESIGN_V2.md 10.6).
enum HoverGeometry {
    /// Speed in pt/ms between two samples. `seconds` is the time between them. A time step of 0 or less gives 0.
    static func speed(from a: HoverPoint, to b: HoverPoint, seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot() / (seconds * 1000)
    }

    /// True when `p` is inside the triangle (or on its edge). The order of the corners does not matter.
    static func inTriangle(_ p: HoverPoint, _ a: HoverPoint, _ b: HoverPoint, _ c: HoverPoint) -> Bool {
        func side(_ p1: HoverPoint, _ p2: HoverPoint, _ p3: HoverPoint) -> Double {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = side(p, a, b), d2 = side(p, b, c), d3 = side(p, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    /// The tolerance triangle: the apex is the last pointer point in the open row. The base is the near edge of the sidebar,
    /// from `minY` to `maxY` at `nearX` (window coordinates).
    static func inSidebarTriangle(_ p: HoverPoint, apex: HoverPoint, nearX: Double, minY: Double, maxY: Double) -> Bool {
        inTriangle(p, apex, HoverPoint(x: nearX, y: minY), HoverPoint(x: nearX, y: maxY))
    }
}
