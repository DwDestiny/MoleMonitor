// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The menu bar icon state from MenuIconModel (docs/DESIGN_V2.md 9) and its text.
// Output: The status item image (five states), tooltip and VoiceOver label; the switch animation between health states.
// Pos: StatusIconController, the only owner of the status item image. Drawing is MenuIconRenderer (DogShapes.swift). Owner WP-E.
//      v2 (WP-E): the stage 1 code (StatusIcon.makeImage, StatusIconCache, IconBadge, IconState, IconText: a dog.fill
//      symbol with a 5 pt red dot) had no caller and is removed (DESIGN_V2.md 9.1).

import AppKit
import Foundation
import QuartzCore

/// The redesigned menu bar icon (docs/DESIGN.md 3, 8.3). I3 owns the status item and calls `apply` on each change.
/// Still states: one NSImage per state (Bichon head from `DogArt.menuHead`, badge or data mark from `GlyphPaths`), cached,
/// assigned only when the state changes. Normal, collecting and stale are template images; caution and alert are not
/// (colored badge, DESIGN_V2.md 9.2 rule 2) and resolve their inks when AppKit draws them. Stage 2 (I2): a change of posture or badge plays one switch animation
/// (DESIGN.md 3.5): at most 8 frames, 70 ms apart (490 ms), from one Timer made for this play and invalidated after
/// the last frame. The frames come from MenuMotion (DogRig) and the same MenuIconRenderer, made once per switch and
/// cached. Reduce Motion, a locked screen, a sleeping display, a hidden icon or the 5 minute throttle switch directly.
/// No timer exists between plays; the icon never moves on its own.
/// The button shows the image only (`imagePosition = .imageOnly`, no title text, DESIGN.md 3). Every frame of a play has
/// the same 24 x 18 pt size as the still images, so the item width never changes during a play. v2 (DESIGN_V2.md 9.2):
/// the frames are drawn in the inks of the button's appearance (head in labelColor, colored badge) and are not templates,
/// so the yellow or red badge keeps its color during a play; the frame cache is keyed by light or dark.
/// The tooltip and the VoiceOver text change at once, not per frame.
@MainActor
final class StatusIconController {
    private weak var statusItem: NSStatusItem?
    /// A button to draw into when there is no status item (the dog checks). The status item button wins.
    weak var fallbackButton: NSButton?
    private var images = [MenuIconState: NSImage]()
    private var transitions = [Transition: [NSImage]]()
    private var transitionOrder = [Transition]()
    private var current: (state: MenuIconState, text: String)?
    private var lastPlayed = [HealthItem: Date]()
    private var timer: Timer?
    private var playing = [NSImage]()
    private var playIndex = 0
    private var playStart: CFTimeInterval = 0
    private var activity: NSObjectProtocol?

    /// Replaces the motion conditions read at the moment of a switch (the dog checks). Nil reads the system.
    var conditionsOverride: (() -> MenuMotionConditions)?
    var clock: () -> Date = { Date() }
    /// Called after each image the controller puts on the button: frame number (1 to 8) or 0 for a direct switch.
    var onImage: ((Int) -> Void)?

    private struct Transition: Hashable {
        var from: MenuIconState
        var to: MenuIconState
        var dark: Bool
    }

    /// `statusItem` is nil in a headless run. Not listed in DESIGN.md 8.3 at skeleton time.
    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
    }

    /// The state last given to `apply` (the target of a play that is still running). Read only (I3 request 3).
    var currentState: MenuIconState? { current?.state }

    /// Timers the controller owns now: 1 while a switch plays, else 0.
    var timerCount: Int { timer == nil ? 0 : 1 }
    var isPlaying: Bool { timer != nil }

    private var button: NSButton? { statusItem?.button ?? fallbackButton }

    /// At most 13 states exist (relaxed, 2 postures x 5 badges, 2 data marks), so the cache stays small.
    func image(for state: MenuIconState) -> NSImage {
        if let hit = images[state] { return hit }
        let made = MenuIconRenderer.image(state)
        images[state] = made
        return made
    }

    func apply(_ state: MenuIconState, text: String) {
        if let current, current.state == state, current.text == text { return }
        let previous = current?.state
        current = (state, text)
        guard let button = self.button else { return }
        button.imagePosition = .imageOnly
        button.toolTip = text
        button.setAccessibilityLabel(text)
        if previous == state, button.image != nil { return }
        show(from: previous, to: state, on: button)
    }

    private func show(from previous: MenuIconState?, to state: MenuIconState, on button: NSButton) {
        // A switch during a play starts from the state the old play was heading to.
        stopPlay()
        let now = clock()
        guard let item = MenuMotion.play(from: previous, to: state, lastPlayed: lastPlayed, now: now,
                                         conditions: motionConditions()),
              let previous else {
            button.image = image(for: state)
            onImage?(0)
            return
        }
        lastPlayed[item] = now
        playing = frames(from: previous, to: state)
        playIndex = 0
        playStart = CACurrentMediaTime()
        // A menu bar app has no visible window, so App Nap may coalesce its timers. The activity keeps the 70 ms
        // ticks on time for the 490 ms of the play only; stopPlay ends it.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Menu bar icon switch animation")
        button.image = playing[0]
        onImage?(1)
        let t = Timer(timeInterval: MenuMotion.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Shows the frame that is due now (frame k is due at k x 70 ms). A late tick skips the frames it missed, so a
    /// slow main thread shortens the play instead of stretching it past 600 ms.
    private func tick() {
        let due = Int(((CACurrentMediaTime() - playStart) / MenuMotion.frameInterval).rounded())
        let next = min(max(due, playIndex + 1), playing.count - 1)
        guard next > playIndex, let button = self.button else {
            stopPlay()
            return
        }
        playIndex = next
        button.image = playing[playIndex]
        onImage?(playIndex + 1)
        if playIndex == playing.count - 1 { stopPlay() }
    }

    private func stopPlay() {
        timer?.invalidate()
        timer = nil
        playing = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// The images of one switch. The last one is the cached still image of the target. At most 8 switches are kept.
    private func frames(from a: MenuIconState, to b: MenuIconState) -> [NSImage] {
        let appearance = button?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
        let key = Transition(from: a, to: b, dark: MenuIconInk.isDark(appearance))
        if let hit = transitions[key] { return hit }
        var made = MenuMotion.frames(from: a, to: b).dropLast().map {
            MenuIconRenderer.image($0, cached: false, appearance: appearance)
        }
        made.append(image(for: b))
        transitions[key] = made
        transitionOrder.append(key)
        if transitionOrder.count > 8 { transitions[transitionOrder.removeFirst()] = nil }
        return made
    }

    /// The system state that forbids motion: Reduce Motion, a locked screen, a sleeping main display, an icon that
    /// is not on screen.
    static func systemConditions() -> MenuMotionConditions {
        var c = MenuMotionConditions()
        c.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            c.screenLocked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
        c.displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return c
    }

    /// The conditions read at a switch. In the UITEST build, `DogFrameProbe.forceReduceMotion` (or the environment
    /// variable MOLEMONITOR_REDUCE_MOTION) replaces Reduce Motion. A controller without `conditionsOverride` (the app's
    /// own icon) switches directly there unless `uiTestMotion` is true, so the UI regression (A, M14) reads the still
    /// image of each state at once. The dog checks set `conditionsOverride` and test the motion.
    private func motionConditions() -> MenuMotionConditions {
        var c = conditionsOverride?() ?? currentConditions()
#if UITEST
        if let forced = DogFrameProbe.forceReduceMotion {
            c.reduceMotion = forced
        } else if conditionsOverride == nil, !StatusIconController.uiTestMotion {
            c.reduceMotion = true
        }
#endif
        return c
    }

#if UITEST
    /// Test only: true lets the app's own icon play switches in the UI test build (see `motionConditions`).
    static var uiTestMotion = false
#endif

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
}
