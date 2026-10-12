// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for HoverIntent, the pointer geometry, PanelWindowGeometry, the click policy and the notification
//         target (docs/DESIGN_V2.md 10.3 to 10.7, gate W06 Core part and the Core part of W05, W10).
// Pos: Called from main.swift via runHoverIntentTests(); no top-level code in this file. A1 registers it, WP-B fills it.
//      All times come from a fixed clock: a test feeds (time, event) pairs and the simulator calls fire(at:) at each deadline.

import Foundation

/// Drives a HoverIntent with fixed times. Deadlines that pass before the next event fire in order, as the window's delayed call would.
private struct HoverSim {
    var intent = HoverIntent()
    /// Every command with the time at which it happened.
    var log = [(t: Double, command: HoverCommand)]()

    mutating func flush(until t: Double) {
        while let d = intent.nextDeadline, d <= t {
            for c in intent.fire(at: d) { log.append((d, c)) }
        }
    }

    @discardableResult
    mutating func send(_ event: HoverEvent, at t: Double) -> [HoverCommand] {
        flush(until: t)
        let commands = intent.handle(event, at: t)
        for c in commands { log.append((t, c)) }
        return commands
    }

    /// Moves at a slow speed into a region.
    mutating func move(_ region: HoverRegion, at t: Double, speed: Double = 0.1, triangle: Bool = false) {
        send(.moved(region, speed: speed, inTriangle: triangle), at: t)
    }

    /// Lets the clock run to `t` with no event.
    mutating func wait(until t: Double) { flush(until: t) }

    func count(_ c: HoverCommand) -> Int { log.filter { $0.command == c }.count }
    func time(of c: HoverCommand) -> Double? { log.first { $0.command == c }?.t }
    var opens: Int { log.filter { if case .open = $0.command { return true } else { return false } }.count }
}

/// Small deterministic generator for the long sequence (no Foundation randomness).
private struct HoverLCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0x1000000)
    }
}

/// Equal within a microsecond (sums such as 0.3 + 0.35 are not exact in binary).
private func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) < eps
}

func runHoverIntentTests() {
    section("HoverIntentTests")
    let cpu = SidebarItem.cpu, mem = SidebarItem.memory, disk = SidebarItem.disk, net = SidebarItem.network

    // MARK: Constants (docs/DESIGN_V2.md 10.6 table)
    expect(HoverIntent.openDelay == 0.350, "open delay is 350 ms")
    expect(HoverIntent.switchDelay == 0.120, "switch delay is 120 ms")
    expect(HoverIntent.triangleHold == 0.300, "triangle hold is 300 ms")
    expect(HoverIntent.neutralCloseDelay == 0.400, "neutral close delay is 400 ms")
    expect(HoverIntent.leaveCloseDelay == 1.0, "leave delay is 1.0 s")
    expect(HoverIntent.fastSpeed == 0.6, "fast speed is 0.6 pt/ms")

    // MARK: Empty machine
    do {
        var h = HoverIntent()
        expect(h.handle(.escape, at: 0).isEmpty && h.nextDeadline == nil, "Esc on a closed sidebar emits nothing")
        expect(!h.consumesEscape, "Esc is not consumed while the sidebar is closed")
        expect(h.fire(at: 5).isEmpty, "fire without a pending action emits nothing")
        expect(h.handle(.moved(.neutral, speed: 0), at: 0).isEmpty && h.nextDeadline == nil, "neutral with a closed sidebar starts nothing")
        expect(h.handle(.moved(.outside, speed: 0), at: 0).isEmpty && h.nextDeadline == nil, "outside with a closed sidebar starts nothing")
        // The default of inTriangle is false.
        expect(HoverEvent.moved(.sidebar, speed: 0.2) == HoverEvent.moved(.sidebar, speed: 0.2, inTriangle: false), "inTriangle defaults to false")
    }

    // MARK: Dwell: 200 ms no, 350 ms yes (W06)
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        expect(s.intent.pendingItem == cpu && s.intent.nextDeadline == 0.350, "entering a row waits 350 ms")
        s.wait(until: 0.200)
        expect(s.opens == 0, "200 ms of rest does not open")
        s.wait(until: 0.349)
        expect(s.opens == 0, "349 ms of rest does not open")
        s.wait(until: 0.350)
        expect(s.log.count == 1 && s.log[0].command == .open(cpu) && s.log[0].t == 0.350, "350 ms of rest opens the row")
        expect(s.intent.openItem == cpu && s.intent.pinnedItem == nil, "a hover preview is not pinned")
        expect(s.intent.pendingItem == nil && s.intent.nextDeadline == nil, "nothing is pending after the open")
        expect(s.intent.fire(at: 10).isEmpty, "a second fire emits nothing")
    }
    do {
        // fire before the deadline does nothing and keeps the pending action
        var h = HoverIntent()
        _ = h.handle(.moved(.row(mem), speed: 0), at: 1.0)
        expect(h.fire(at: 1.2).isEmpty && h.nextDeadline == 1.35, "an early fire changes nothing")
        expect(h.fire(at: 1.35) == [.open(mem)], "fire at the deadline opens")
    }

    // MARK: Slow moves inside a row do not restart the timer
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0, speed: 0.05)
        s.move(.row(cpu), at: 0.100, speed: 0.30)
        s.move(.row(cpu), at: 0.200, speed: 0.59)
        s.move(.row(cpu), at: 0.300, speed: 0.60)
        expect(s.intent.nextDeadline == 0.350, "speed 0.6 pt/ms or less keeps the 350 ms deadline")
        s.wait(until: 0.351)
        expect(s.time(of: .open(cpu)) == 0.350, "the row opens 350 ms after the entry")
    }

    // MARK: Fast pointer restarts the time (speed above 0.6 pt/ms)
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0, speed: 0.1)
        s.move(.row(cpu), at: 0.300, speed: 0.61)
        expect(near(s.intent.nextDeadline, 0.650), "a fast move restarts the 350 ms time")
        s.wait(until: 0.649)
        expect(s.opens == 0, "no open before the restarted time ends")
        s.wait(until: 0.650)
        expect(near(s.time(of: .open(cpu)), 0.650), "the row opens 350 ms after the fast move")
    }

    // MARK: Fast crossing of 3 rows does not open (W06)
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0.000, speed: 0.9)
        s.move(.row(mem), at: 0.040, speed: 0.9)
        s.move(.row(disk), at: 0.080, speed: 0.9)
        s.move(.neutral, at: 0.120, speed: 0.9)
        s.wait(until: 5)
        expect(s.log.isEmpty, "a fast crossing of 3 rows opens nothing")
        expect(s.intent.nextDeadline == nil, "nothing is pending after the crossing")
    }
    do {
        // Rows entered one after the other, each for less than 350 ms.
        var s = HoverSim()
        s.move(.row(cpu), at: 0.0)
        s.move(.row(mem), at: 0.3)
        s.move(.row(disk), at: 0.6)
        s.move(.row(net), at: 0.9)
        s.move(.outside, at: 1.2)
        s.wait(until: 10)
        expect(s.log.isEmpty, "rows left before 350 ms never open")
    }
    do {
        // The same, but the last row rests: it alone opens.
        var s = HoverSim()
        s.move(.row(cpu), at: 0.0)
        s.move(.row(mem), at: 0.3)
        s.move(.row(disk), at: 0.6)
        s.wait(until: 2)
        expect(s.log.count == 1 && s.log[0].command == .open(disk) && abs(s.log[0].t - 0.95) < 1e-9, "only the row that rests opens")
    }

    // MARK: Switch while open (120 ms, W06 needs at most 200 ms)
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.0)
        expect(s.intent.nextDeadline == 1.120, "a new row waits 120 ms")
        s.wait(until: 1.119)
        expect(s.count(.switchTo(mem)) == 0, "no switch before 120 ms")
        s.wait(until: 1.120)
        expect(s.time(of: .switchTo(mem)) == 1.120 && s.intent.openItem == mem, "the sidebar switches 120 ms after the entry")
        expect(s.count(.close) == 0, "a switch is not a close")
        // Back to the open row: nothing pending.
        s.move(.row(mem), at: 1.5)
        expect(s.intent.nextDeadline == nil, "the open row keeps the sidebar")
    }
    do {
        // Pointer returns to the open row before 120 ms: no switch.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.0)
        s.move(.row(cpu), at: 1.1)
        s.wait(until: 3)
        expect(s.count(.switchTo(mem)) == 0 && s.intent.openItem == cpu, "returning to the open row cancels the switch")
    }
    do {
        // Rows crossed while open at normal speed, each for less than 120 ms: only the last that rests switches.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.00)
        s.move(.row(disk), at: 1.08)
        s.wait(until: 3)
        expect(s.count(.switchTo(mem)) == 0 && s.count(.switchTo(disk)) == 1, "a row crossed in less than 120 ms does not switch")
    }

    // MARK: Triangle tolerance: 300 ms toward the sidebar
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        // Diagonal move over the memory row, then into the sidebar after 200 ms.
        s.move(.row(mem), at: 1.00, triangle: true)
        expect(s.intent.nextDeadline == 1.300, "a row in the triangle waits 300 ms")
        s.move(.row(mem), at: 1.10, triangle: true)
        expect(s.intent.nextDeadline == 1.300, "more moves in the triangle keep the 300 ms deadline")
        s.move(.sidebar, at: 1.20)
        s.wait(until: 4)
        expect(s.count(.switchTo(mem)) == 0 && s.intent.openItem == cpu, "reaching the sidebar within 300 ms: no switch, the sidebar stays")
        expect(s.count(.close) == 0, "the sidebar stays open in the sidebar")
    }
    do {
        // The pointer rests in the row inside the triangle: the switch comes after 300 ms.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.00, triangle: true)
        s.wait(until: 1.299)
        expect(s.count(.switchTo(mem)) == 0, "no switch before 300 ms in the triangle")
        s.wait(until: 1.300)
        expect(s.time(of: .switchTo(mem)) == 1.300, "the switch comes after 300 ms")
    }
    do {
        // Leaving the triangle inside the same row shortens the wait to 120 ms after the leave.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.00, triangle: true)
        s.move(.row(mem), at: 1.05, triangle: false)
        expect(s.intent.nextDeadline == 1.170, "leaving the triangle gives the 120 ms delay from that move")
        s.move(.row(mem), at: 1.06, triangle: true)
        expect(s.intent.nextDeadline == 1.170, "entering the triangle again never extends the wait")
    }
    do {
        // Outside the triangle the normal 120 ms delay applies at once.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.row(mem), at: 1.00, triangle: false)
        s.wait(until: 1.2)
        expect(s.time(of: .switchTo(mem)) == 1.120, "a row outside the triangle switches after 120 ms")
    }

    // MARK: Neutral zone: 400 ms
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.neutral, at: 1.0)
        expect(s.intent.nextDeadline == 1.4, "the neutral zone waits 400 ms")
        s.move(.neutral, at: 1.2)
        expect(s.intent.nextDeadline == 1.4, "more moves in the neutral zone keep the deadline")
        s.wait(until: 1.399)
        expect(s.count(.close) == 0, "no close before 400 ms")
        s.wait(until: 1.4)
        expect(s.time(of: .close) == 1.4 && s.intent.openItem == nil, "the sidebar closes 400 ms after the pointer entered the neutral zone")
    }
    do {
        // Back on a row (the open one) before 400 ms.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.neutral, at: 1.0)
        s.move(.row(cpu), at: 1.3)
        s.wait(until: 5)
        expect(s.count(.close) == 0 && s.intent.openItem == cpu, "returning to the open row cancels the close")
    }
    do {
        // Neutral then sidebar before 400 ms.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.neutral, at: 1.0)
        s.move(.sidebar, at: 1.3)
        s.wait(until: 5)
        expect(s.count(.close) == 0, "entering the sidebar cancels the close")
    }
    do {
        // A pending open is cancelled by the neutral zone.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.move(.neutral, at: 0.2)
        s.wait(until: 2)
        expect(s.log.isEmpty && s.intent.nextDeadline == nil, "the neutral zone cancels a pending open")
    }

    // MARK: Leaving the panel: 1.0 s (W06: 1.0 +- 0.1 s)
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.sidebar, at: 2.0)
        s.move(.outside, at: 3.0)
        expect(s.intent.nextDeadline == 4.0, "leaving the panel waits 1.0 s")
        s.wait(until: 3.999)
        expect(s.count(.close) == 0, "no close before 1.0 s")
        s.wait(until: 4.0)
        expect(s.time(of: .close) == 4.0, "the unpinned sidebar closes 1.0 s after the pointer left the panel")
    }
    do {
        // Back inside before 1.0 s.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.outside, at: 2.0)
        s.move(.sidebar, at: 2.9)
        s.wait(until: 6)
        expect(s.count(.close) == 0 && s.intent.openItem == cpu, "returning within 1.0 s keeps the sidebar")
    }
    do {
        // Outside, then the neutral zone: the neutral time (400 ms) replaces the 1.0 s time.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        s.move(.outside, at: 2.0)
        s.move(.neutral, at: 2.2)
        expect(s.intent.nextDeadline == 2.6, "entering the neutral zone after outside waits 400 ms")
        // A pointer that goes from the neutral zone to outside keeps the earlier close.
        var t = HoverSim()
        t.move(.row(cpu), at: 0)
        t.wait(until: 0.4)
        t.move(.neutral, at: 2.0)
        t.move(.outside, at: 2.1)
        expect(t.intent.nextDeadline == 2.4, "leaving from the neutral zone keeps the earlier close time")
    }

    // MARK: Click pins (W06: pinned stays 5 s)
    do {
        var s = HoverSim()
        let c1 = s.send(.clicked(disk), at: 0)
        expect(c1 == [.open(disk), .pin(disk)], "a click on a closed sidebar opens and pins")
        expect(s.intent.pinnedItem == disk && s.intent.openItem == disk, "the click pins and opens")
        expect(s.intent.consumesEscape, "Esc closes a pinned sidebar first")
        s.move(.neutral, at: 0.5)
        s.move(.outside, at: 1.0)
        s.move(.row(mem), at: 2.0)
        s.wait(until: 8)
        expect(s.log.count == 2 && s.intent.openItem == disk && s.intent.pinnedItem == disk,
               "a pinned sidebar ignores the pointer for 5 s and more")
        expect(s.intent.nextDeadline == nil, "no timer runs for a pinned sidebar")
        // Click on another row: switch and pin.
        let c2 = s.send(.clicked(mem), at: 9)
        expect(c2 == [.switchTo(mem), .pin(mem)] && s.intent.pinnedItem == mem, "a click on another row switches and pins")
        // Click on the pinned row: close.
        let c3 = s.send(.clicked(mem), at: 10)
        expect(c3 == [.unpin, .close] && s.intent.openItem == nil && s.intent.pinnedItem == nil, "a click on the pinned row unpins and closes")
    }
    do {
        // A click on the row of an open hover preview pins it without a second open.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        let c = s.send(.clicked(cpu), at: 1.0)
        expect(c == [.pin(cpu)], "a click on the previewed row only pins")
        // A click while a switch is pending cancels the switch.
        var t = HoverSim()
        t.move(.row(cpu), at: 0)
        t.wait(until: 0.4)
        t.move(.row(mem), at: 1.0)
        let d = t.send(.clicked(mem), at: 1.05)
        expect(d == [.switchTo(mem), .pin(mem)] && t.intent.nextDeadline == nil, "a click replaces the pending switch")
    }
    do {
        // A click cancels a pending open and a pending close.
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        let c = s.send(.clicked(cpu), at: 0.1)
        expect(c == [.open(cpu), .pin(cpu)] && s.intent.nextDeadline == nil, "a click replaces the pending open")
    }
    do {
        // The anomaly log is an item like the rows.
        var s = HoverSim()
        s.move(.row(.anomalyLog), at: 0)
        s.wait(until: 0.4)
        expect(s.time(of: .open(.anomalyLog)) == 0.350, "the anomaly bar opens the anomaly log")
    }

    // MARK: Esc and the close button
    do {
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        expect(s.intent.consumesEscape, "Esc closes a hover preview first")
        let e = s.send(.escape, at: 1.0)
        expect(e == [.close] && s.intent.openItem == nil && !s.intent.consumesEscape, "Esc closes the preview")
        let e2 = s.send(.escape, at: 1.1)
        expect(e2.isEmpty, "the second Esc has no sidebar left (the window closes the panel)")
    }
    do {
        var s = HoverSim()
        s.send(.clicked(disk), at: 0)
        let e = s.send(.escape, at: 1.0)
        expect(e == [.unpin, .close] && s.intent.pinnedItem == nil && s.intent.openItem == nil, "Esc unpins and closes a pinned sidebar")
        var t = HoverSim()
        t.send(.clicked(disk), at: 0)
        let b = t.send(.closeButton, at: 1.0)
        expect(b == [.unpin, .close], "the close button unpins and closes")
        var u = HoverSim()
        u.move(.row(cpu), at: 0)
        u.wait(until: 0.4)
        u.move(.neutral, at: 1.0)
        let x = u.send(.escape, at: 1.1)
        expect(x == [.close] && u.intent.nextDeadline == nil, "Esc cancels a pending close")
    }

    // MARK: External pin (notification tap, R-14)
    do {
        var h = HoverIntent()
        expect(h.pinExternally(.thermal) == [.open(.thermal), .pin(.thermal)], "a notification opens and pins")
        expect(h.pinExternally(.thermal).isEmpty, "a second notification for the same item changes nothing (no toggle)")
        expect(h.pinExternally(.disk) == [.switchTo(.disk), .pin(.disk)], "a notification for another item switches and pins")
        expect(h.pinnedItem == .disk, "the new item is pinned")
    }

    // MARK: Reduce Motion changes no delay
    do {
        // The delays belong to the intent. Reduce Motion only removes the animation (WindowMotion).
        expect(WindowMotion.sideDuration(open: true, reduceMotion: true) == 0, "Reduce Motion: sidebar opens without animation")
        expect(WindowMotion.sideDuration(open: false, reduceMotion: true) == 0, "Reduce Motion: sidebar closes without animation")
        expect(WindowMotion.sideDuration(open: true, reduceMotion: false) == 0.220, "sidebar open takes 220 ms")
        expect(WindowMotion.sideDuration(open: false, reduceMotion: false) == 0.180, "sidebar close takes 180 ms")
        var s = HoverSim()
        s.move(.row(cpu), at: 0)
        s.wait(until: 0.4)
        expect(s.time(of: .open(cpu)) == 0.350, "the open delay is the same with Reduce Motion (the machine does not know it)")
    }

    // MARK: 30 s of random pointer movement opens nothing (R-16)
    do {
        let regions: [HoverRegion] = [.row(.cpu), .row(.memory), .row(.disk), .row(.network), .row(.battery), .row(.thermal),
                                      .row(.anomalyLog), .neutral, .outside]
        var rng = HoverLCG(state: 42)
        var s = HoverSim()
        var t = 0.0
        var last = HoverRegion.outside
        var steps = 0
        while t < 30 {
            // A different region each step, never longer than 340 ms in a region, random speed.
            var region = regions[Int(rng.next() * Double(regions.count)) % regions.count]
            if region == last { region = regions[(regions.firstIndex(of: region)! + 1) % regions.count] }
            let speed = rng.next() * 1.2
            s.move(region, at: t, speed: speed)
            // Extra slow moves inside the region, still under the 350 ms limit counted from the entry.
            let dwell = 0.04 + rng.next() * 0.30
            s.move(region, at: t + dwell * 0.5, speed: rng.next() * 0.6)
            t += dwell
            last = region
            steps += 1
        }
        s.wait(until: t)
        expect(steps > 100, "the random walk has more than 100 steps (\(steps))")
        expect(s.log.isEmpty, "30 s of random movement with no rest of 350 ms opens nothing")

        // Control: the same walk with one rest of 400 ms in a row opens exactly once.
        var rng2 = HoverLCG(state: 42)
        var c = HoverSim()
        var t2 = 0.0
        var last2 = HoverRegion.outside
        var rested = false
        while t2 < 30 {
            var region = regions[Int(rng2.next() * Double(regions.count)) % regions.count]
            if region == last2 { region = regions[(regions.firstIndex(of: region)! + 1) % regions.count] }
            let speed = rng2.next() * 1.2
            c.move(region, at: t2, speed: speed)
            var dwell = 0.04 + rng2.next() * 0.30
            _ = rng2.next()
            if !rested, t2 > 10, case .row = region { dwell = 0.40; rested = true; c.move(region, at: t2 + 0.05, speed: 0.1) }
            t2 += dwell
            last2 = region
        }
        c.wait(until: t2)
        expect(c.opens >= 1, "the control walk with a rest of 400 ms in a row opens the sidebar")
    }

    // MARK: Pointer geometry
    do {
        let a = HoverPoint(x: 0, y: 0), b = HoverPoint(x: 100, y: 0)
        expect(abs(HoverGeometry.speed(from: a, to: b, seconds: 0.1) - 1.0) < 1e-9, "100 pt in 100 ms is 1.0 pt/ms")
        expect(abs(HoverGeometry.speed(from: a, to: HoverPoint(x: 3, y: 4), seconds: 0.005) - 1.0) < 1e-9, "5 pt in 5 ms is 1.0 pt/ms")
        expect(HoverGeometry.speed(from: a, to: b, seconds: 0) == 0, "a zero time step gives speed 0")
        expect(HoverGeometry.speed(from: a, to: b, seconds: -1) == 0, "a negative time step gives speed 0")
        expect(HoverGeometry.speed(from: a, to: b, seconds: 0.2) < HoverIntent.fastSpeed, "0.5 pt/ms is slower than the fast limit")

        // Sidebar on the left: the near edge is x = 320 of a window; the apex is at x = 400, y = 100.
        let apex = HoverPoint(x: 400, y: 100)
        func inside(_ x: Double, _ y: Double) -> Bool {
            HoverGeometry.inSidebarTriangle(HoverPoint(x: x, y: y), apex: apex, nearX: 320, minY: 0, maxY: 600)
        }
        expect(inside(360, 100), "a point between the apex and the sidebar on the apex line is inside")
        expect(inside(350, 200), "a point on the diagonal toward the lower sidebar corner side is inside")
        expect(inside(321, 590), "a point near the base is inside")
        expect(!inside(420, 100), "a point behind the apex is outside")
        expect(!inside(390, 400), "a point far below the cone at the apex is outside")
        expect(!inside(360, 400), "a point below the cone is outside")
        expect(inside(400, 100), "the apex is inside")
        // Sidebar on the right: mirrored.
        expect(HoverGeometry.inSidebarTriangle(HoverPoint(x: 700, y: 120), apex: HoverPoint(x: 600, y: 100), nearX: 800, minY: 0, maxY: 600),
               "mirrored triangle contains a point toward the right sidebar")
        expect(!HoverGeometry.inSidebarTriangle(HoverPoint(x: 500, y: 100), apex: HoverPoint(x: 600, y: 100), nearX: 800, minY: 0, maxY: 600),
               "mirrored triangle excludes a point away from the right sidebar")
    }

    runPanelWindowGeometryTests()
    runNotificationTargetTests()
}

// MARK: - Window geometry (docs/DESIGN_V2.md 10.3, 10.4, 10.5)

private func runPanelWindowGeometryTests() {
    section("PanelWindowGeometry")
    // A 1512 x 982 screen (visible frame under a 38 pt menu bar), the item near the right edge.
    let screen = PanelRect(x: 0, y: 0, width: 1512, height: 944)
    let barBottom = 944.0

    let right = PanelWindowGeometry.place(anchorMidX: 1400, anchorMinY: barBottom, visible: screen, height: 524)
    expect(right.collapsed.width == 352, "the main column is 352 pt wide")
    expect(right.collapsed.maxX == 1504, "the main column is clamped 8 pt from the right edge (maxX \(right.collapsed.maxX))")
    expect(right.collapsed.x == 1152, "x is 1152 at the right edge")
    expect(right.collapsed.maxY == 940 && right.collapsed.height == 524 && right.collapsed.y == 416, "the top edge is 4 pt below the menu bar")
    expect(right.top == 940, "top is 940")
    expect(right.edge == .left, "an item at the right edge opens the sidebar to the left (R-18)")
    expect(right.mainShift == 0, "no shift at the right edge")
    expect(right.expanded.width == 672 && right.expanded.x == 832 && right.expanded.maxX == 1504, "left expansion widens the window by 320 pt to the left")
    expect(right.expanded.y == right.collapsed.y && right.expanded.height == right.collapsed.height, "the sidebar does not change the height")
    expect(PanelWindowGeometry.mainColumnX(right, sidebarOpen: false) == 1152, "main column x with the sidebar closed")
    expect(PanelWindowGeometry.mainColumnX(right, sidebarOpen: true) == 1152, "main column x with the sidebar open is the same (W05: change at most 0.5 pt)")
    expect(right.expanded.maxX <= screen.maxX && right.expanded.minX >= screen.minX, "the expanded window stays inside the screen")
    expect(right.expanded.maxY <= barBottom, "the window does not cover the menu bar")

    let leftItem = PanelWindowGeometry.place(anchorMidX: 400, anchorMinY: barBottom, visible: screen, height: 560)
    expect(leftItem.edge == .right, "an item far from the right edge opens the sidebar to the right")
    expect(leftItem.collapsed.x == 224, "centered on the item: x = 400 - 176")
    expect(leftItem.expanded.x == 224 && leftItem.expanded.width == 672, "right expansion keeps x")
    expect(PanelWindowGeometry.mainColumnX(leftItem, sidebarOpen: true) == PanelWindowGeometry.mainColumnX(leftItem, sidebarOpen: false),
           "main column x is the same for the right edge")

    // Left clamp.
    let nearLeft = PanelWindowGeometry.place(anchorMidX: 20, anchorMinY: barBottom, visible: screen, height: 524)
    expect(nearLeft.collapsed.x == 8, "an item near the left edge is clamped to 8 pt")
    expect(nearLeft.edge == .right, "then the sidebar opens to the right")

    // Boundary of rule 2: right room exactly 328 pt opens to the right.
    // mainX + 352 + 328 = 1512 -> mainX = 832.
    let boundary = PanelWindowGeometry.place(anchorMidX: 832 + 176, anchorMinY: barBottom, visible: screen, height: 524)
    expect(boundary.collapsed.x == 832 && boundary.edge == .right, "a right room of exactly 328 pt opens to the right")
    let beyond = PanelWindowGeometry.place(anchorMidX: 833 + 176, anchorMinY: barBottom, visible: screen, height: 524)
    expect(beyond.edge == .left, "a right room of 327 pt opens to the left")

    // Second screen on the left of the main screen: the visible frame starts at a negative x.
    let second = PanelRect(x: -1920, y: 0, width: 1920, height: 1055)
    let onSecond = PanelWindowGeometry.place(anchorMidX: -100, anchorMinY: 1055, visible: second, height: 560)
    expect(onSecond.collapsed.x == -360 && onSecond.collapsed.maxX <= second.maxX - 8, "a second screen with negative x clamps inside its own frame")
    expect(onSecond.edge == .left, "the item at the right edge of the second screen opens the sidebar to the left")
    expect(onSecond.expanded.minX >= second.minX, "the expanded window stays on the second screen")

    // Narrow screen (rule 4): visible width 680 pt (less than 688, at least 672), item in the middle.
    let narrow = PanelRect(x: 0, y: 0, width: 680, height: 700)
    let n = PanelWindowGeometry.place(anchorMidX: 340, anchorMinY: 700, visible: narrow, height: 524)
    expect(n.collapsed.x == 164, "narrow screen: main column centered at 164")
    expect(n.mainShift != 0, "narrow screen: the main column moves when the sidebar opens")
    expect(n.expanded.minX >= narrow.minX && n.expanded.maxX <= narrow.maxX, "narrow screen: the expanded window stays inside (\(n.expanded.minX)...\(n.expanded.maxX))")
    // Right room 164 equals left room 164: tie goes left. Smallest shift that keeps 8 pt on the left: expandedX = 164-320 = -156, deficit 164.
    expect(n.edge == .left && n.mainShift == 164, "narrow screen: smallest shift 164 pt (got \(n.mainShift))")
    expect(n.expanded.x == 8 && PanelWindowGeometry.mainColumnX(n, sidebarOpen: true) == 328, "narrow screen: expanded window and moved column")
    let nr = PanelWindowGeometry.place(anchorMidX: 200, anchorMinY: 700, visible: narrow, height: 524)
    expect(nr.edge == .right && nr.collapsed.x == 24 && nr.mainShift == -24 && nr.expanded.x == 0, "narrow screen with more room on the right moves the column left")

    // Height change: top fixed, bottom moves (docs/DESIGN_V2.md 2.3 rule 3).
    let taller = PanelWindowGeometry.resized(right, height: 648, minY: 0)
    expect(taller.collapsed.maxY == right.collapsed.maxY && taller.collapsed.height == 648, "a taller panel keeps the top edge")
    expect(taller.collapsed.y == 292 && taller.expanded.y == 292 && taller.expanded.height == 648, "the bottom edge moves down by 124 pt")
    expect(taller.collapsed.x == right.collapsed.x && taller.edge == right.edge, "a height change does not move the column or change the edge")
    // The panel never goes below the visible frame.
    let tall = PanelWindowGeometry.place(anchorMidX: 400, anchorMinY: 700, visible: PanelRect(x: 0, y: 100, width: 1200, height: 600), height: 648)
    expect(tall.collapsed.minY >= 100 && tall.collapsed.maxY <= 696, "a panel that is too tall is cut at the visible frame (\(tall.collapsed.minY))")

    // Motion constants (docs/DESIGN_V2.md 3.7, 10.5).
    expect(WindowMotion.sideOpenCurve == [0.2, 0.8, 0.2, 1.0] && WindowMotion.sideCloseCurve == [0.4, 0.0, 1.0, 1.0], "easing curves of 10.5")
    expect(WindowMotion.openDuration == 0.160 && WindowMotion.closeDuration == 0.120, "motion.open 160 ms, motion.close 120 ms")
    expect(WindowMotion.sideContentDelay == 0.060 && WindowMotion.sideContentFade == 0.120, "sidebar content fades in after 60 ms for 120 ms")
    expect(WindowMotion.sideOpenDuration <= 0.250, "the sidebar opens within the 250 ms of W05")

    // Click policy (10.7).
    expect(PanelClickPolicy.local(isPanelWindow: true, isChildOfPanel: false, isMenuWindow: false, isStatusItemWindow: false) == .keepOpen,
           "a click in the panel keeps it open")
    expect(PanelClickPolicy.local(isPanelWindow: false, isChildOfPanel: true, isMenuWindow: false, isStatusItemWindow: false) == .keepOpen,
           "a click in a child window of the panel keeps it open")
    expect(PanelClickPolicy.local(isPanelWindow: false, isChildOfPanel: false, isMenuWindow: true, isStatusItemWindow: false) == .keepOpen,
           "a click in the menu of the ... button keeps the panel open")
    expect(PanelClickPolicy.local(isPanelWindow: false, isChildOfPanel: false, isMenuWindow: false, isStatusItemWindow: true) == .keepOpen,
           "a click on the menu bar item is left to the button action (no close and open)")
    expect(PanelClickPolicy.local(isPanelWindow: false, isChildOfPanel: false, isMenuWindow: false, isStatusItemWindow: false) == .close,
           "a click in another window of this app closes the panel")
    expect(PanelClickPolicy.global() == .close, "a click in another app closes the panel")
}

// MARK: - Notification target (R-14)

private func runNotificationTargetTests() {
    section("NotificationTarget")
    expect(NotificationPlanner.sidebarItem(for: .cpu) == .cpu, "cpu notification pins the CPU sidebar")
    expect(NotificationPlanner.sidebarItem(for: .memory) == .memory, "memory notification pins the memory sidebar")
    expect(NotificationPlanner.sidebarItem(for: .disk) == .disk, "disk notification pins the disk sidebar")
    expect(NotificationPlanner.sidebarItem(for: .thermal) == .thermal, "thermal notification pins the temperature sidebar")
    expect(NotificationPlanner.sidebarItem(for: .power) == .battery, "power notification pins the battery sidebar")
    expect(NotificationPlanner.sidebarItem(for: nil) == nil, "a notification without an item pins nothing")
    expect(HealthItem.allCases.allSatisfy { NotificationPlanner.sidebarItem(for: $0) != nil }, "every health item has a sidebar")
}
