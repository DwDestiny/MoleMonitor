// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk health level and the latest StatusFile.
// Output: Menu bar icon images (dog symbol, two gray dots, optional corner badge) and Chinese accessibility text.
// Pos: Stage 1 icon drawing and cache (docs/PROJECT.md 4.1); no timers, no animation.

import AppKit
import Foundation

/// Corner badge kind. `none` means a template image that follows the menu bar color.
enum IconBadge: Hashable {
    case none, yellow, red
}

/// What the status item shows. The app assigns the image only when this value changes.
struct IconState: Equatable {
    var badge: IconBadge
    var description: String
}

enum StatusIcon {
    static let size = NSSize(width: 34, height: 18)
    static let badgeDiameter: CGFloat = 5

    /// Only a red disk level gets a badge (docs/PROJECT.md 4.1). Yellow, green, unknown and stale get none;
    /// the yellow state is shown in the tooltip and the status card.
    static func badge(for level: HealthLevel) -> IconBadge {
        switch level {
        case .red: return .red
        default: return .none
        }
    }

    /// No badge: template image. With badge: non-template image, ink drawn with labelColor at draw time.
    static func makeImage(badge: IconBadge) -> NSImage {
        let template = (badge == .none)
        let image = NSImage(size: size, flipped: false) { rect in
            drawGroup(in: rect, template: template, badge: badge)
            return true
        }
        image.isTemplate = template
        return image
    }

    // MARK: Drawing

    private static func drawGroup(in rect: NSRect, template: Bool, badge: IconBadge) {
        // Template images use alpha only, so black is the neutral ink. Non-template images resolve
        // labelColor here, at draw time, so the color follows light and dark menu bars.
        // UNVERIFIED-ON-MAC: labelColor follows the system appearance, which may differ from a wallpaper-tinted menu bar.
        // Alternative: read statusItem.button?.effectiveAppearance in the app and pass an explicit color.
        let ink: NSColor = template ? NSColor.black : NSColor.labelColor

        drawDog(ink: ink, template: template)

        let dotInk = ink.withAlphaComponent(0.55)
        dotInk.setStroke()

        // Memory dot (square, hollow): stage 1 has no memory data.
        let square = NSBezierPath(rect: NSRect(x: 22.5, y: 7, width: 4, height: 4))
        square.lineWidth = 1
        square.stroke()

        // Temperature dot (drop, hollow): stage 1 has no temperature data.
        let cx: CGFloat = 31
        let top: CGFloat = 12.2
        let bottom: CGFloat = 5.8
        let half: CGFloat = 2.4
        let height = top - bottom
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: cx, y: top))
        drop.curve(to: NSPoint(x: cx, y: bottom),
                   controlPoint1: NSPoint(x: cx + half * 0.4, y: top - height * 0.45),
                   controlPoint2: NSPoint(x: cx + half * 1.3, y: bottom))
        drop.curve(to: NSPoint(x: cx, y: top),
                   controlPoint1: NSPoint(x: cx - half * 1.3, y: bottom),
                   controlPoint2: NSPoint(x: cx - half * 0.4, y: top - height * 0.45))
        drop.close()
        drop.lineWidth = 1
        drop.stroke()

        // Corner badge on the top-right of the whole group, not on the dog.
        if badge != .none {
            let color: NSColor = (badge == .red) ? NSColor.systemRed : NSColor.systemYellow
            color.setFill()
            let d = badgeDiameter
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
        }
    }

    private static func drawDog(ink: NSColor, template: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        // UNVERIFIED-ON-MAC: "dog.fill" needs SF Symbols 4 (macOS 13+). Falls back to a paw print.
        let base = NSImage(systemSymbolName: "dog.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
        guard let symbol = base?.withSymbolConfiguration(config) else { return }
        let box = NSRect(x: 0, y: 1, width: 20, height: 16)
        let target = aspectFit(symbol.size, in: box)
        if template {
            symbol.draw(in: target)
        } else {
            tinted(symbol, color: ink).draw(in: target)
        }
    }

    private static func aspectFit(_ source: NSSize, in box: NSRect) -> NSRect {
        guard source.width > 0, source.height > 0 else { return box }
        let scale = min(box.width / source.width, box.height / source.height)
        let w = source.width * scale
        let h = source.height * scale
        return NSRect(x: box.minX + (box.width - w) / 2, y: box.minY + (box.height - h) / 2, width: w, height: h)
    }

    /// Returns a copy of a symbol image painted in one color (keeps the alpha shape).
    private static func tinted(_ symbol: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            // UNVERIFIED-ON-MAC: NSRect.fill(using:) spelling. Alternative: NSGraphicsContext.current?.compositingOperation = .sourceAtop, then NSBezierPath.fill(r).
            r.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}

/// Keeps at most three images (one per badge kind). Redraw happens only for a badge not seen before.
final class StatusIconCache {
    private var images = [IconBadge: NSImage]()

    func image(for badge: IconBadge) -> NSImage {
        if let cached = images[badge] { return cached }
        let made = StatusIcon.makeImage(badge: badge)
        images[badge] = made
        return made
    }
}

/// Chinese text for the tooltip and the VoiceOver label.
enum IconText {
    static func description(status: StatusFile?, level: HealthLevel) -> String {
        guard let status else { return "磁盘状态统计中" }
        let disk = status.items.disk
        switch level {
        case .green:
            return "磁盘正常"
        case .yellow, .red:
            switch disk.reasonCode {
            case "growth_1d", "growth_5d":
                let key = (disk.reasonCode == "growth_1d") ? "1d" : "5d"
                let days = (key == "1d") ? 1 : 5
                if let bytes = disk.growth[key]?.bytes {
                    return "磁盘 \(days) 天多占用了 \(ByteText.gb(bytes))"
                }
                return "磁盘增长异常（\(level.label)）"
            case "low_space":
                if let avail = disk.availableImportant.value {
                    return "磁盘剩余空间只有 \(ByteText.gb(avail))"
                }
                return "磁盘剩余空间不足（\(level.label)）"
            case "hold", "recovering":
                return "磁盘回落观察中（\(level.label)）"
            default:
                return "磁盘异常（\(level.label)）"
            }
        case .stale:
            return "磁盘数据已过期"
        case .unknown, .notApplicable:
            return "磁盘状态统计中"
        }
    }
}

/// The redesigned menu bar icon (docs/DESIGN.md 3, 8.3). I3 owns the status item and calls `apply` on each change.
/// Still states: one template NSImage per state (Bichon head from `DogArt.menuHead`, badge from `GlyphPaths`), cached,
/// assigned only when the state changes. Stage 2 (I2): a change of posture or badge plays one switch animation
/// (DESIGN.md 3.5): at most 8 frames, 75 ms apart (525 ms), from one Timer made for this play and invalidated after
/// the last frame. The frames come from MenuMotion (DogRig) and the same MenuIconRenderer, made once per switch and
/// cached. Reduce Motion, a locked screen, a sleeping display, a hidden icon or the 5 minute throttle switch directly.
/// No timer exists between plays; the icon never moves on its own.
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

    /// Replaces the motion conditions read at the moment of a switch (the dog checks). Nil reads the system.
    var conditionsOverride: (() -> MenuMotionConditions)?
    var clock: () -> Date = { Date() }
    /// Called after each image the controller puts on the button: frame number (1 to 8) or 0 for a direct switch.
    var onImage: ((Int) -> Void)?

    private struct Transition: Hashable {
        var from: MenuIconState
        var to: MenuIconState
    }

    /// `statusItem` is nil in a headless run. Not listed in DESIGN.md 8.3 at skeleton time.
    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
    }

    /// Timers the controller owns now: 1 while a switch plays, else 0.
    var timerCount: Int { timer == nil ? 0 : 1 }
    var isPlaying: Bool { timer != nil }

    private var button: NSButton? { statusItem?.button ?? fallbackButton }

    /// At most 16 states exist (3 postures x 5 badges + hollow), so the cache stays small.
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
                                         conditions: conditionsOverride?() ?? currentConditions()),
              let previous else {
            button.image = image(for: state)
            onImage?(0)
            return
        }
        lastPlayed[item] = now
        playing = frames(from: previous, to: state)
        playIndex = 0
        button.image = playing[0]
        onImage?(1)
        let t = Timer(timeInterval: MenuMotion.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        playIndex += 1
        guard playIndex < playing.count, let button = self.button else {
            stopPlay()
            return
        }
        button.image = playing[playIndex]
        onImage?(playIndex + 1)
        if playIndex == playing.count - 1 { stopPlay() }
    }

    private func stopPlay() {
        timer?.invalidate()
        timer = nil
        playing = []
    }

    /// The images of one switch. The last one is the cached still image of the target. At most 8 switches are kept.
    private func frames(from a: MenuIconState, to b: MenuIconState) -> [NSImage] {
        let key = Transition(from: a, to: b)
        if let hit = transitions[key] { return hit }
        var made = MenuMotion.frames(from: a, to: b).dropLast().map { MenuIconRenderer.image($0, cached: false) }
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
