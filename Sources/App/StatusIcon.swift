// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The menu bar icon state from MenuIconModel and its text; the CPU percent of each engine tick; the system state
//        that forbids motion (Reduce Motion, locked screen, sleeping display, hidden icon, Low Power Mode).
// Output: The status item image (stand frame, or the 4-frame run loop while the CPU is busy), the tooltip and the
//         VoiceOver label (plus "，CPU 占用高" while busy). At most one run timer, only while the runner runs.
// Pos: StatusIconController, the only owner of the status item image. Drawing is MenuRunnerRenderer
//      (MenuRunnerShapes.swift); the run rules are MenuRunLogic (Core/MenuRunner.swift). Owner P-icon.
//      v3 (U10, docs/DESIGN_V3.md 4.2): the v2 head postures and the switch animation (<= 8 frames, 490 ms) are removed.

import AppKit
import Foundation

/// The menu bar runner (DESIGN_V3.md 4.2). The icon stands still, or runs a 4-frame loop while the CPU is busy
/// (>= 35 % starts, 2 ticks < 25 % stop; 4, 6 or 8 fps by CPU). The health mark (yellow triangle, red square) stays
/// where it is in every frame. Collecting and stale draw the hollow standing dog with their mark and never run.
/// Timer rule (AGENTS.md): while the runner stands there is no icon timer; while it runs there is exactly one repeating
/// Timer at the frame interval with a 20 % tolerance, invalidated as soon as the runner stops or motion is forbidden.
/// Every frame is a cached image of the same 24 x 18 pt, so the status item width never changes.
@MainActor
final class StatusIconController {
    private weak var statusItem: NSStatusItem?
    /// A button to draw into when there is no status item (the icon checks). The status item button wins.
    weak var fallbackButton: NSButton?
    private var current: (state: MenuIconState, text: String)?
    private var run = MenuRunState()
    private var timer: Timer?
    private var timerSpeed: MenuRunSpeed?
    private var frame = 0
    private var shown: (pose: MenuRunPose, kind: MenuIconKind)?
    private var images = [ImageKey: NSImage]()
    private var observers = [(NotificationCenter, NSObjectProtocol)]()

    /// Replaces the system motion conditions (the icon checks). Nil reads the system.
    var conditionsOverride: (() -> MenuMotionConditions)?
    /// Called after each image the controller puts on the button: run frame number (1 to 4) or 0 for the still frame.
    var onImage: ((Int) -> Void)?

    private struct ImageKey: Hashable {
        var pose: MenuRunPose
        var kind: MenuIconKind
    }

    /// `statusItem` is nil in a headless run.
    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
    }

    /// The state last given to `apply`.
    var currentState: MenuIconState? { current?.state }
    /// The run state after the last CPU tick.
    var runState: MenuRunState { run }
    /// Icon timers the controller owns now: 1 while the runner runs, else 0.
    var timerCount: Int { timer == nil ? 0 : 1 }
    var isRunning: Bool { timer != nil }
    /// Seconds between two run frames now, nil while standing.
    var frameInterval: TimeInterval? { timer?.timeInterval }
    var timerTolerance: TimeInterval? { timer?.tolerance }

    private var button: NSButton? { statusItem?.button ?? fallbackButton }

    /// The cached image of a frame. At most 5 poses x 5 kinds.
    func image(_ pose: MenuRunPose, kind: MenuIconKind) -> NSImage {
        let key = ImageKey(pose: pose, kind: kind)
        if let hit = images[key] { return hit }
        let made = MenuRunnerFrameCache.shared.image(pose, kind: kind)
        images[key] = made
        return made
    }

    /// The still image of a state (the stand frame).
    func image(for state: MenuIconState) -> NSImage { image(.stand, kind: state.kind) }

    func apply(_ state: MenuIconState, text: String) {
        if let current, current.state == state, current.text == text { return }
        current = (state, text)
        startObserving()
        refresh()
    }

    /// One engine tick (every 30 s, plus the warm-up tick): the whole-machine CPU percent, or nil when the tick has none.
    func cpuTick(_ percent: Double?) {
        run = MenuRunLogic.next(run, cpu: percent)
        refresh()
    }

    /// Reads the conditions again and shows the right image; starts, retimes or stops the run timer.
    func refresh() {
        guard let button, let current else {
            stopTimer()
            return
        }
        button.imagePosition = .imageOnly
        let busy = run.running && current.state.mark == nil
        let text = MenuRunLogic.text(current.text, running: busy)
        if button.toolTip != text {
            button.toolTip = text
            button.setAccessibilityLabel(text)
        }
        let kind = current.state.kind
        if MenuRunLogic.animates(run, state: current.state, conditions: motionConditions()), let speed = run.speed {
            if timer == nil || timerSpeed != speed { startTimer(speed) }
            show(.run(frame), kind: kind, on: button)
        } else {
            stopTimer()
            frame = 0
            show(.stand, kind: kind, on: button)
        }
    }

    private func show(_ pose: MenuRunPose, kind: MenuIconKind, on button: NSButton) {
        if let shown, shown.pose == pose, shown.kind == kind, button.image != nil { return }
        shown = (pose, kind)
        button.image = image(pose, kind: kind)
        if case .run(let i) = pose { onImage?(i + 1) } else { onImage?(0) }
    }

    private func startTimer(_ speed: MenuRunSpeed) {
        timer?.invalidate()
        let t = Timer(timeInterval: speed.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        t.tolerance = speed.tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerSpeed = speed
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerSpeed = nil
    }

    /// Next run frame. The conditions are not read here (they come from notifications and ticks), so a frame costs
    /// one image assignment.
    private func step() {
        guard let button, let current else {
            stopTimer()
            return
        }
        frame = (frame + 1) % MenuRunPose.runFrameCount
        show(.run(frame), kind: current.state.kind, on: button)
    }

    // MARK: Conditions

    /// The system state that forbids motion: Reduce Motion, a locked screen, a sleeping main display, Low Power Mode.
    static func systemConditions() -> MenuMotionConditions {
        var c = MenuMotionConditions()
        c.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            c.screenLocked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
        c.displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return c
    }

    /// The conditions of this controller's button (adds the visibility of the icon).
    func currentConditions() -> MenuMotionConditions {
        var c = StatusIconController.systemConditions()
        if let window = button?.window {
            c.iconVisible = window.isVisible && window.occlusionState.contains(.visible)
        } else {
            c.iconVisible = false
        }
        return c
    }

    /// The conditions read at each refresh. In the UITEST build, the app's own icon (no `conditionsOverride`) never
    /// runs unless `uiTestMotion` is true, so the UI regression reads still images and counts no icon timer.
    private func motionConditions() -> MenuMotionConditions {
        var c = conditionsOverride?() ?? currentConditions()
#if UITEST
        if conditionsOverride == nil, !StatusIconController.uiTestMotion { c.reduceMotion = true }
#endif
        return c
    }

#if UITEST
    /// Test only: true lets the app's own icon run in the UI test build (see `motionConditions`).
    static var uiTestMotion = false
#endif

    /// Refreshes on the events that change a condition. The observers cost nothing between events; no polling.
    private func startObserving() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.screensDidSleepNotification), (ws, NSWorkspace.screensDidWakeNotification),
            (ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
            (ws, NSWorkspace.sessionDidResignActiveNotification), (ws, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
            (NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange),
            (NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let windowID = (note.object as? NSWindow).map { ObjectIdentifier($0) }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Occlusion changes of other windows (the panel) do not concern the icon.
                    if let windowID, windowID != self.button?.window.map({ ObjectIdentifier($0) }) { return }
                    self.refresh()
                }
            }
            observers.append((center, token))
        }
    }
}
