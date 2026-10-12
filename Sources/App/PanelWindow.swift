// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The menu bar item view (for the position), two SwiftUI views (main column, sidebar), PanelWindowGeometry, HoverIntent.
// Output: PanelWindow: the custom NSPanel of the status card (docs/DESIGN_V2.md 10): placement under the menu bar item, open and
//         close motion, click and key handling, event monitors, the sidebar window animation and the hover rules of the sidebar.
// Pos: WP-B window layer. It replaces the NSPopover. It implements PanelChrome and calls PanelPinning. The content (PanelRoot, WP-C)
//      is only hosted here. Two hosting views of fixed width (352 pt main column, 320 pt sidebar) sit in one NSVisualEffectView;
//      the window frame grows and clips them (method A, 10.5), the views never relayout during the animation.
//      The monitors exist only while the panel is shown. No periodic timer in this file: delayed calls are cancellable tasks.

import AppKit
import SwiftUI
import QuartzCore

// MARK: - Geometry bridge

private extension PanelRect {
    var ns: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

extension NSRect {
    /// Used by AppDelegate-side code and the UI checks to feed PanelWindowGeometry.
    var panelRect: PanelRect { PanelRect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height)) }
}

// MARK: - State and sidebar slot

/// State that the SwiftUI sidebar slot reads. The window changes it, the slot only draws.
@MainActor
final class PanelWindowState: ObservableObject {
    let edge: SidebarEdge
    @Published var sidebarOpen = false
    /// The item that the sidebar shows (hover preview or pinned).
    @Published var sidebarItem: SidebarItem?
    @Published var pinned = false
    var reduceMotion = false

    init(edge: SidebarEdge) { self.edge = edge }
}

/// The 320 pt sidebar slot: the content of WP-C when given, a plain placeholder otherwise. It draws the 1 pt separator on the side of
/// the main column and fades the content in 60 ms after the expansion starts (10.5 rule 4). Reduce Motion: fade of 150 ms.
struct PanelSidebarHost: View {
    @ObservedObject var state: PanelWindowState
    let content: AnyView?

    var body: some View {
        ZStack {
            if let content {
                content
            } else {
                PanelSidebarPlaceholder(item: state.sidebarItem)
            }
        }
        .frame(width: PanelWindowMetrics.sidebarWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(state.sidebarOpen ? 1 : 0)
        .animation(fade, value: state.sidebarOpen)
        .overlay(alignment: state.edge == .right ? .leading : .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .accessibilityHidden(!state.sidebarOpen)
        .accessibilityIdentifier("sidebar.root")
    }

    private var fade: Animation {
        if state.reduceMotion { return .easeInOut(duration: WindowMotion.reduceMotionFade) }
        if state.sidebarOpen { return .easeOut(duration: WindowMotion.sideContentFade).delay(WindowMotion.sideContentDelay) }
        return .easeIn(duration: 0.1)
    }
}

/// Stands in for the sidebar content until WP-C provides it.
struct PanelSidebarPlaceholder: View {
    let item: SidebarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.label ?? "")
                .font(.system(size: 17, weight: .semibold))
            Text("明细")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("sidebar.placeholder")
    }
}

// MARK: - Tracking owner

/// Receives the enter and exit of the pointer. It is a separate object so the tracking area does not retain the window.
@MainActor
private final class PanelTrackingOwner: NSObject {
    weak var window: PanelWindow?

    @objc func mouseEntered(_ event: NSEvent) { window?.pointerEntered() }
    @objc func mouseExited(_ event: NSEvent) { window?.pointerExited() }
    @objc func mouseMoved(_ event: NSEvent) {}
}

// MARK: - The window

@MainActor
final class PanelWindow: NSPanel, PanelChrome {
    // MARK: State

    let state: PanelWindowState
    private(set) var placement: PanelPlacement
    private(set) var sidebarOpen = false
    /// True from the first close request until the content is released.
    private(set) var isClosing = false
    private(set) var isFinished = false
    /// What the panel gives to the sidebar: set by the owner (the model of WP-C).
    weak var pinning: PanelPinning?
    /// The window of the menu bar item. A click on it is left to the button action (10.7 rule 2).
    weak var statusItemWindow: NSWindow?
    /// Called once, when the window has closed and released its content.
    var onClosed: (() -> Void)?

    /// The hosting view of the main column. Its origin is the origin of the main column.
    let mainHost: NSHostingView<AnyView>
    let sidebarHost: NSHostingView<PanelSidebarHost>
    private let effect: NSVisualEffectView
    private let trackingOwner = PanelTrackingOwner()
    private let visibleMinY: Double

    // Event monitors and observers, installed on present and removed on close (10.7 rule 1).
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var closeFallback: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?

    // Hover.
    private var intent = HoverIntent()
    private var hoverTask: Task<Void, Never>?
    private var scheduledDeadline: TimeInterval?
    private var lastPointer: (point: HoverPoint, time: TimeInterval)?
    private var lastSpeed = 0.0
    private var contentRegion = HoverRegion.neutral
    private var pointerInside = false
    private var apex: HoverPoint?

    // MARK: Creation

    /// - placement: frames from `PanelWindowGeometry.place`.
    /// - visibleMinY: lower limit of the visible frame, for height changes.
    /// - main: the root view of the main column (352 pt wide).
    /// - sidebar: the sidebar content of WP-C. Nil shows a placeholder.
    init(placement: PanelPlacement, visibleMinY: Double, main: AnyView, sidebar: AnyView?) {
        self.placement = placement
        self.visibleMinY = visibleMinY
        let windowState = PanelWindowState(edge: placement.edge)
        self.state = windowState
        let height = placement.collapsed.height
        let mainSize = NSSize(width: PanelWindowMetrics.mainWidth, height: height)
        let sideSize = NSSize(width: PanelWindowMetrics.sidebarWidth, height: height)
        let mainView = NSHostingView(rootView: main)
        let sideView = NSHostingView(rootView: PanelSidebarHost(state: windowState, content: sidebar))
        mainHost = mainView
        sidebarHost = sideView
        effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: mainSize))
        super.init(contentRect: placement.collapsed.ns, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        // Window (10.2).
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isMovable = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        setAccessibilityLabel("MoleMonitor")
        setAccessibilityIdentifier("panel.window")
        windowState.reduceMotion = isReduceMotion

        // Content: one material view, two fixed-width hosting views. The autoresizing masks keep the views at the right
        // place while the window frame animates: the window origin and the width change, the views keep their size.
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = PanelWindow.roundedMask(radius: PanelWindowMetrics.cornerRadius)
        mainView.sizingOptions = []
        sideView.sizingOptions = []
        mainView.frame = NSRect(origin: .zero, size: mainSize)
        switch placement.edge {
        case .right:
            sideView.frame = NSRect(origin: NSPoint(x: PanelWindowMetrics.mainWidth, y: 0), size: sideSize)
            mainView.autoresizingMask = [.maxXMargin, .minYMargin]
            sideView.autoresizingMask = [.maxXMargin, .minYMargin]
        case .left:
            sideView.frame = NSRect(origin: NSPoint(x: -PanelWindowMetrics.sidebarWidth, y: 0), size: sideSize)
            mainView.autoresizingMask = [.minXMargin, .minYMargin]
            sideView.autoresizingMask = [.minXMargin, .minYMargin]
        }
        effect.addSubview(mainView)
        effect.addSubview(sideView)
        trackingOwner.window = self
        effect.addTrackingArea(NSTrackingArea(rect: .zero,
                                              options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                              owner: trackingOwner, userInfo: nil))
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Rounded corners of the material (12 pt). A stretchable mask image is the supported way to shape the material.
    private static func roundedMask(radius: Double) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Placement

    /// Placement under a menu bar item. `anchor` is the button of the status item. Without a window the panel stands in the
    /// upper right corner of the main screen.
    static func makePlacement(anchor: NSView?, height: Double) -> (placement: PanelPlacement, visibleMinY: Double) {
        let screen = anchor?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 860)).panelRect
        var midX = visible.maxX - 120
        var minY = visible.maxY
        if let anchor, let window = anchor.window {
            let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            midX = Double(onScreen.midX)
            minY = Double(onScreen.minY)
        }
        let placement = PanelWindowGeometry.place(anchorMidX: midX, anchorMinY: minY, visible: visible, height: height)
        return (placement, visible.minY)
    }

    // MARK: PanelChrome

    var sidebarEdge: SidebarEdge { placement.edge }

    var isReduceMotion: Bool {
#if UITEST
        if let forced = PanelWindow.testReduceMotion { return forced }
#endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The content (or the owner) opens or closes the sidebar frame. Closing also resets the hover rules.
    func setSidebar(open: Bool, animated: Bool) {
        if !open, intent.openItem != nil {
            send(.closeButton, at: PanelWindow.clock())
            return
        }
        applySidebar(open: open, animated: animated)
    }

    func closePanel() {
        guard !isClosing, !isFinished else { return }
        isClosing = true
        removeMonitors()
        removeObservers()
        hoverTask?.cancel()
        hoverTask = nil
        scheduledDeadline = nil
        if !isVisible || isReduceMotion {
            motionTask?.cancel()
            finishClose()
            return
        }
        // motion.close: the window fades out in 120 ms.
        runMotion(duration: WindowMotion.closeDuration, curve: WindowMotion.closeCurve, to: frame, alpha: 0) { [weak self] in
            self?.finishClose()
        }
        // The motion can end without a completion call (for example when the window is off screen).
        closeFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.finishClose()
        }
    }

    // MARK: Hover reports from the content

    func reportHover(_ region: HoverRegion) {
        contentRegion = region
        dispatchHover(at: nil, time: PanelWindow.clock())
    }

    func reportClick(_ item: SidebarItem) {
        send(.clicked(item), at: PanelWindow.clock())
    }

    func reportCloseButton() {
        send(.closeButton, at: PanelWindow.clock())
    }

    /// Opens the sidebar and pins an item without a pointer (a tap on a notification, R-14). The content gets `pinSidebar`.
    func openAndPin(_ item: SidebarItem) {
        run(intent.pinExternally(item))
        reschedule()
    }

    /// The item that the sidebar shows now. Nil when it is closed.
    var shownSidebarItem: SidebarItem? { intent.openItem }
    var pinnedSidebarItem: SidebarItem? { intent.pinnedItem }

    // MARK: Present

    /// Shows the panel (10.8). The caller has built the views. The window is hidden (alpha 0) until the layout is done, so the
    /// user never sees an empty or white window. The next run loop turn starts `motion.open`.
    func present() {
        guard !isFinished, !isClosing else { return }
        let reduce = isReduceMotion
        state.reduceMotion = reduce
        effect.layoutSubtreeIfNeeded()
        mainHost.layoutSubtreeIfNeeded()
        let final = placement.collapsed.ns
        alphaValue = 0
        setFrame(reduce ? final : final.offsetBy(dx: 0, dy: -WindowMotion.openRise), display: false)
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(nil)
        // Draw the content while the window is still invisible, so the first visible frame is never blank or black.
        displayIfNeeded()
        CATransaction.flush()
        installMonitors()
        installObservers()
        if reduce {
            alphaValue = 1
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing, !self.isFinished else { return }
            // A sidebar motion that started in the same turn (a tap on a notification) already fades the window in. Keep it.
            guard self.motionTask == nil else { return }
            let target = PanelWindowGeometry.frame(self.placement, sidebarOpen: self.sidebarOpen).ns
            self.runMotion(duration: WindowMotion.openDuration, curve: WindowMotion.openCurve, to: target, alpha: 1, done: nil)
        }
    }

    // MARK: Height

    /// The anomaly count changed the content height. The top edge stays, the bottom edge moves (2.3 rule 3).
    func setContentHeight(_ height: Double, animated: Bool) {
        guard !isClosing, !isFinished else { return }
        let next = PanelWindowGeometry.resized(placement, height: height, minY: visibleMinY)
        guard next.collapsed.height != placement.collapsed.height else { return }
        let oldBounds = Double(effect.bounds.height)
        placement = next
        let h = next.collapsed.height
        // Give the views their final height now. The autoresizing of the window animation moves them to the final place.
        for view in [mainHost as NSView, sidebarHost as NSView] {
            var f = view.frame
            f.origin.y = CGFloat(oldBounds - h)
            f.size.height = CGFloat(h)
            view.frame = f
        }
        let duration = (animated && !isReduceMotion) ? WindowMotion.sideOpenDuration : 0
        moveWindow(to: PanelWindowGeometry.frame(next, sidebarOpen: sidebarOpen), duration: duration, curve: WindowMotion.sideOpenCurve)
    }

    // MARK: Sidebar frame

    private func applySidebar(open: Bool, animated: Bool) {
        guard open != sidebarOpen, !isClosing, !isFinished else { return }
        sidebarOpen = open
        state.reduceMotion = isReduceMotion
        state.sidebarOpen = open
        let target = PanelWindowGeometry.frame(placement, sidebarOpen: open)
        let duration = animated ? WindowMotion.sideDuration(open: open, reduceMotion: isReduceMotion) : 0
        moveWindow(to: target, duration: duration, curve: open ? WindowMotion.sideOpenCurve : WindowMotion.sideCloseCurve)
    }

    private func moveWindow(to target: PanelRect, duration: Double, curve: [Double]) {
        // The window ends fully visible, also when the sidebar motion starts while the open fade still runs.
        runMotion(duration: duration, curve: curve, to: target.ns, alpha: isClosing ? alphaValue : 1, done: nil)
    }

    /// Moves the window frame and the alpha to the targets in `duration` seconds, in steps of about 6 ms on the main actor.
    /// The frame animation of AppKit (`animator().setFrame`) did not play in the CI run, so the window steps by itself. The task
    /// exists only while the motion runs (at most 220 ms), it is cancelled by a new motion and by the close. The views have a
    /// fixed size, so a step only moves the window edges and the autoresizing masks place the views.
    private func runMotion(duration: Double, curve: [Double], to target: NSRect, alpha targetAlpha: CGFloat, done: (() -> Void)?) {
        motionTask?.cancel()
        motionTask = nil
        let from = frame
        let fromAlpha = alphaValue
        if duration <= 0 {
            setFrame(target, display: true)
            alphaValue = targetAlpha
            invalidateShadow()
            done?()
            return
        }
        let start = PanelWindow.clock()
        motionTask = Task { @MainActor [weak self] in
            var step = 0
            while true {
                guard let self, !Task.isCancelled, !self.isFinished else { return }
                let t = (PanelWindow.clock() - start) / duration
                if t >= 1 { break }
                let p = CGFloat(WindowMotion.ease(t, curve: curve))
                let rect = NSRect(x: from.minX + (target.minX - from.minX) * p, y: from.minY + (target.minY - from.minY) * p,
                                  width: from.width + (target.width - from.width) * p, height: from.height + (target.height - from.height) * p)
                if rect != self.frame { self.setFrame(rect, display: true) }
                self.alphaValue = fromAlpha + (targetAlpha - fromAlpha) * p
                step += 1
                if step % 4 == 0 { self.invalidateShadow() }
                try? await Task.sleep(nanoseconds: 6_000_000)
            }
            guard let self, !Task.isCancelled, !self.isFinished else { return }
            if target != self.frame { self.setFrame(target, display: true) }
            self.alphaValue = targetAlpha
            self.invalidateShadow()
            self.motionTask = nil
            done?()
        }
    }

    // MARK: Events

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty {
                escapePressed()
                return
            }
            if flags == .command, event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return
            }
        case .mouseMoved:
            super.sendEvent(event)
            pointerMoved(event.locationInWindow, at: event.timestamp)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Esc closes the sidebar first. With the sidebar closed, it closes the panel (10.7).
    private func escapePressed() {
        if intent.consumesEscape {
            send(.escape, at: PanelWindow.clock())
        } else {
            closePanel()
        }
    }

    // MARK: Click monitors (10.7)

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if globalMonitor == nil && localMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleGlobalClick() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handleLocalClick(event) }
                // The monitor never swallows a click (10.7 rule 3).
                return event
            }
#if UITEST
            PanelWindow.testMonitorCount += 2
#endif
        }
    }

    private func removeMonitors() {
#if UITEST
        if globalMonitor != nil { PanelWindow.testMonitorCount -= 1 }
        if localMonitor != nil { PanelWindow.testMonitorCount -= 1 }
#endif
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// A click that goes to another app. It always closes the panel.
    func handleGlobalClick() {
        if PanelClickPolicy.global() == .close { closePanel() }
    }

    /// What the local monitor does with a click in a window of this app (10.7 table).
    func localClickDecision(_ event: NSEvent) -> PanelClickPolicy.Decision {
        // A click without a window (menu tracking) is not outside.
        guard let target = event.window else { return .keepOpen }
        let isChild = childWindows?.contains(target) ?? false
        let isMenu = String(describing: type(of: target)).contains("Menu")
        let isStatus = statusItemWindow != nil && target === statusItemWindow
        return PanelClickPolicy.local(isPanelWindow: target === self, isChildOfPanel: isChild, isMenuWindow: isMenu, isStatusItemWindow: isStatus)
    }

    func handleLocalClick(_ event: NSEvent) {
        if localClickDecision(event) == .close { closePanel() }
    }

    // MARK: Close conditions (10.7: app switch, space change, lock, sleep, screen change)

    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let own = ProcessInfo.processInfo.processIdentifier
        watch(workspace, NSWorkspace.didActivateApplicationNotification) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            return app?.processIdentifier != own
        }
        watch(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        watch(workspace, NSWorkspace.willSleepNotification)
        watch(workspace, NSWorkspace.screensDidSleepNotification)
        watch(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        watch(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, filter: (@Sendable (Notification) -> Bool)? = nil) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            if let filter, !filter(note) { return }
            MainActor.assumeIsolated { self?.closePanel() }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
    }

    // MARK: Finish

    private func finishClose() {
        guard !isFinished else { return }
        isFinished = true
        closeFallback?.cancel()
        closeFallback = nil
        motionTask?.cancel()
        motionTask = nil
        removeMonitors()
        removeObservers()
        hoverTask?.cancel()
        hoverTask = nil
        orderOut(nil)
        // Release the content: both SwiftUI trees, the views and the tracking area (10.7 last paragraph).
        mainHost.rootView = AnyView(EmptyView())
        sidebarHost.rootView = PanelSidebarHost(state: state, content: nil)
        mainHost.removeFromSuperview()
        sidebarHost.removeFromSuperview()
        for area in effect.trackingAreas { effect.removeTrackingArea(area) }
        trackingOwner.window = nil
        contentView = NSView(frame: .zero)
        pinning = nil
        let done = onClosed
        onClosed = nil
        done?()
    }

    // MARK: Pointer and hover rules (10.6)

    static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    fileprivate func pointerEntered() {
        pointerInside = true
    }

    fileprivate func pointerExited() {
        pointerInside = false
        lastPointer = nil
        lastSpeed = 0
        send(.moved(.outside, speed: 0, inTriangle: false), at: PanelWindow.clock())
    }

    private func pointerMoved(_ location: NSPoint, at time: TimeInterval) {
        let point = HoverPoint(x: Double(location.x), y: Double(location.y))
        if let last = lastPointer {
            lastSpeed = HoverGeometry.speed(from: last.point, to: point, seconds: time - last.time)
        } else {
            lastSpeed = 0
        }
        lastPointer = (point, time)
        pointerInside = true
        dispatchHover(at: point, time: time)
    }

    /// Sends the current region to the rules. `point` is nil when only the region of the content changed.
    private func dispatchHover(at point: HoverPoint?, time: TimeInterval) {
        guard !isClosing, !isFinished else { return }
        let at = point ?? lastPointer?.point
        var region = contentRegion
        if !pointerInside {
            region = .outside
        } else if sidebarOpen, let at, sidebarRangeX.contains(at.x) {
            region = .sidebar
        }
        if case let .row(item) = region, let at, item == intent.openItem { apex = at }
        var inTriangle = false
        if case let .row(item) = region, sidebarOpen, item != intent.openItem, let at, let from = apex {
            let nearX = placement.edge == .right ? PanelWindowMetrics.mainWidth : PanelWindowMetrics.sidebarWidth
            inTriangle = HoverGeometry.inSidebarTriangle(at, apex: from, nearX: nearX, minY: 0, maxY: placement.collapsed.height)
        }
        send(.moved(region, speed: lastSpeed, inTriangle: inTriangle), at: time)
    }

    /// x range of the sidebar in window coordinates, with the sidebar open.
    private var sidebarRangeX: ClosedRange<Double> {
        switch placement.edge {
        case .right: return PanelWindowMetrics.mainWidth...PanelWindowMetrics.expandedWidth
        case .left: return 0...PanelWindowMetrics.sidebarWidth
        }
    }

    private func send(_ event: HoverEvent, at time: TimeInterval) {
        run(intent.handle(event, at: time))
        reschedule()
    }

    private func run(_ commands: [HoverCommand]) {
        for command in commands {
            switch command {
            case let .open(item):
                state.sidebarItem = item
                pinning?.previewSidebar(item)
                applySidebar(open: true, animated: true)
            case let .switchTo(item):
                state.sidebarItem = item
                pinning?.previewSidebar(item)
            case .close:
                applySidebar(open: false, animated: true)
                pinning?.previewSidebar(nil)
                apex = nil
            case let .pin(item):
                state.pinned = true
                pinning?.pinSidebar(item)
            case .unpin:
                state.pinned = false
                pinning?.unpinSidebar()
            }
        }
    }

    /// Keeps exactly one cancellable delayed call for the next deadline of the rules. A new deadline replaces the old call.
    private func reschedule() {
        let deadline = intent.nextDeadline
        if deadline == scheduledDeadline { return }
        hoverTask?.cancel()
        hoverTask = nil
        scheduledDeadline = deadline
        guard let deadline, !isClosing else { return }
        let delay = max(0, deadline - PanelWindow.clock())
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hoverDeadlineReached()
        }
    }

    private func hoverDeadlineReached() {
        hoverTask = nil
        scheduledDeadline = nil
        guard !isClosing, !isFinished else { return }
        run(intent.fire(at: PanelWindow.clock()))
        reschedule()
    }

#if UITEST
    // MARK: Test hooks (UITEST build only)

    /// Test only: forces the Reduce Motion answer. Nil follows the system setting.
    static var testReduceMotion: Bool?
    /// Test only: number of installed event monitors (global plus local) of the live window. 0 when no panel is shown.
    private(set) static var testMonitorCount = 0
    /// Test only: number of installed close observers.
    var testObserverCount: Int { observers.count }
    /// Test only: the delayed hover call exists.
    var testHoverTaskPending: Bool { hoverTask != nil }
    /// Test only: the pointer is at `location` (window coordinates) over `region`. Same path as a real mouse move.
    func testPointer(_ region: HoverRegion, at location: NSPoint) {
        contentRegion = region
        pointerMoved(location, at: PanelWindow.clock())
    }
    /// Test only: the pointer leaves the window.
    func testPointerLeave() { pointerExited() }
    /// Test only: the pointer enters the window without a move.
    func testPointerEnter() { pointerEntered() }

#endif
}
