// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Pointer and timer events from the panel window (docs/DESIGN_V2.md 10.6).
// Output: HoverCommand values: open, switch or close the sidebar. nextDeadline tells the window when to call fire(at:).
// Pos: A1 contract skeleton: types, constants and signatures are final, the state machine does nothing yet. Foundation only. The window schedules one cancellable delayed call, never a Timer. A1 creates it, WP-B owns it after the A1 merge.

import Foundation

/// Where the pointer is.
enum HoverRegion: Equatable {
    case row(SidebarItem)      // A breakdown row or the anomaly bar
    case sidebar
    case neutral               // Hero, anomaly title, footer
    case outside               // Outside the panel
}

enum HoverEvent: Equatable {
    /// `speed` is the pointer speed in pt/ms.
    case moved(HoverRegion, speed: Double)
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

    private(set) var openItem: SidebarItem?
    private(set) var pinnedItem: SidebarItem?
    private(set) var pendingItem: SidebarItem?
    /// Time at which the caller must call `fire(at:)`. Nil when nothing is pending.
    private(set) var nextDeadline: TimeInterval?

    init() {}

    /// Feeds one event. Skeleton: returns no command (filled in by WP-B).
    mutating func handle(_ event: HoverEvent, at time: TimeInterval) -> [HoverCommand] {
        []
    }

    /// Called when `nextDeadline` has passed. Skeleton: returns no command (filled in by WP-B).
    mutating func fire(at time: TimeInterval) -> [HoverCommand] {
        []
    }
}
