// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The runner silhouette of a pose (Core MenuRunnerArt), the icon kind, the inks of a light or dark menu bar.
// Output: Core Graphics drawing of the v3 menu bar icon (docs/DESIGN_V3.md 4.2): the side-view Bichon in the button ink
//         (`labelColor`), solid (eye and drooping-ear gap cleared) or hollow (outer contour only, no ear gap), with the health mark (yellow triangle, red square) or the stale ring bottom right
//         (collecting has no mark, R3); frame bitmaps cached by pose, kind, light or dark and scale; the NSImage of a frame.
// Pos: The one renderer of the menu bar icon. StatusIconController shows its images; UITestIconChecks (W29) draws the
//      contact sheet from it. Vector paths only, no bitmap assets. Owner P-icon (v3, U10). Q4 moved `MenuIconInk` here
//      from the deleted DogShapes.swift.
//
// All drawing here uses y-down coordinates (the bitmap context is flipped before drawing).

import AppKit
import CoreGraphics
import Foundation

enum MenuRunnerRenderer {
    static let size = CGSize(width: MenuRunnerArt.width, height: MenuRunnerArt.height)
    /// Width of the hollow ring inside the outline (collecting, stale).
    static let hollowLine: CGFloat = 1.2

    static func path(_ s: MenuRunnerShape) -> CGPath {
        switch s {
        case let .circle(x, y, r):
            return CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
        case let .ellipse(x, y, rx, ry):
            return CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case let .capsule(x0, y0, x1, y1, r):
            let line = CGMutablePath()
            line.move(to: CGPoint(x: x0, y: y0))
            line.addLine(to: CGPoint(x: x1, y: y1))
            return line.copy(strokingWithWidth: CGFloat(2 * r), lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
    }

    /// The outer contour of a pose (union of its shapes, holes dropped), built once per pose. Small gaps between the
    /// belly bumps and the legs make holes in the union; the hollow icon strokes the outer contour only.
    private static let lock = NSLock()
    private static var outlines = [MenuRunPose: CGPath]()
    static func outline(_ pose: MenuRunPose) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let hit = outlines[pose] { return hit }
        let shapes = MenuRunnerArt.figure(pose).fill.map(path)
        var u = shapes[0]
        for p in shapes.dropFirst() { u = u.union(p) }
        let outer = largestSubpath(u)
        outlines[pose] = outer
        return outer
    }

    /// The subpath with the largest bounding box (the outer contour of one connected shape).
    static func largestSubpath(_ path: CGPath) -> CGPath {
        var parts = [CGMutablePath]()
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                let p = CGMutablePath()
                p.move(to: e.points[0])
                parts.append(p)
            case .addLineToPoint:
                parts.last?.addLine(to: e.points[0])
            case .addQuadCurveToPoint:
                parts.last?.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint:
                parts.last?.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath:
                parts.last?.closeSubpath()
            @unknown default:
                break
            }
        }
        func area(_ p: CGPath) -> CGFloat {
            let b = p.boundingBoxOfPath
            return b.width * b.height
        }
        return parts.max(by: { area($0) < area($1) }) ?? path
    }

    /// The health or data mark of a kind, nil for normal.
    static func markPath(_ kind: MenuIconKind) -> CGPath? {
        let o = MenuRunnerArt.markOrigin, s = MenuRunnerArt.markSize
        switch kind {
        case .normal:
            return nil
        case .caution:
            // Triangle pointing up, full box width, joins rounded by the caller's stroke.
            let p = CGMutablePath()
            let inset = 0.45
            p.move(to: CGPoint(x: o.x + s / 2, y: o.y + inset))
            p.addLine(to: CGPoint(x: o.x + s - inset, y: o.y + s - inset))
            p.addLine(to: CGPoint(x: o.x + inset, y: o.y + s - inset))
            p.closeSubpath()
            return p
        case .alert:
            // Square, a little smaller than the box so it weighs like the triangle.
            let side = s - 1.2
            let r = CGRect(x: o.x + (s - side) / 2, y: o.y + (s - side) / 2, width: side, height: side)
            return CGPath(roundedRect: r, cornerWidth: 1, cornerHeight: 1, transform: nil)
        case .collecting:
            // R3: the hollow dog alone; the v2 three dots were 3 single pixels at 1x.
            return nil
        case .stale:
            // R3: a hollow small circle (no clock hands), the stale-row circle of the panel. Filled ring, nonzero rule.
            let ring = MenuRunnerArt.staleRing
            let mid = ring.outer - ring.line / 2
            let circle = CGPath(ellipseIn: CGRect(x: ring.x - mid, y: ring.y - mid, width: 2 * mid, height: 2 * mid), transform: nil)
            return circle.copy(strokingWithWidth: CGFloat(ring.line), lineCap: .butt, lineJoin: .round, miterLimit: 1)
        }
    }

    /// Draws one frame in a y-down context, 1 unit = 1 pt. Collecting and stale draw the hollow outline.
    static func draw(_ pose: MenuRunPose, kind: MenuIconKind, ink: MenuIconInk, in ctx: CGContext) {
        let figure = MenuRunnerArt.figure(pose)
        let hollow = kind == .collecting || kind == .stale
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // The dog and a data mark are one layer in the opaque ink, composited at the ink alpha (labelColor has alpha
        // 0.85), so overlapping shapes do not add up to a darker seam.
        ctx.saveGState()
        ctx.setAlpha(ink.head.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let opaque = ink.head.copy(alpha: 1) ?? ink.head
        ctx.setFillColor(opaque)
        ctx.setStrokeColor(opaque)
        if hollow {
            let contour = outline(pose)
            ctx.saveGState()
            ctx.addPath(contour)
            ctx.clip()
            ctx.setLineWidth(hollowLine * 2)
            ctx.setLineJoin(.round)
            ctx.addPath(contour)
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            for s in figure.fill {
                ctx.addPath(path(s))
                ctx.fillPath()
            }
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            for s in figure.cut {
                ctx.addPath(path(s))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        if hollow, let mark = markPath(kind) {
            ctx.addPath(mark)
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        if let mark = markPath(kind), kind == .caution || kind == .alert {
            // A clear ring first, so the mark never touches the dog, then the mark in its level color.
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(CGFloat(MenuRunnerArt.markGap * 2))
            ctx.setLineJoin(.round)
            ctx.addPath(mark)
            ctx.strokePath()
            ctx.restoreGState()
            let color = kind == .caution ? ink.warning : ink.danger
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(0.8)
            ctx.addPath(mark)
            ctx.drawPath(using: .fillStroke)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// A bitmap of one frame: `scale` px per pt, sRGB, premultiplied, row 0 at the top.
    static func bitmap(_ pose: MenuRunPose, kind: MenuIconKind, ink: MenuIconInk, scale: Int) -> CGImage? {
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(pose, kind: kind, ink: ink, in: ctx)
        return ctx.makeImage()
    }
}

/// Frame bitmaps keyed by pose, kind, light or dark and scale, made on first use (DESIGN_V3.md 4.2). At most
/// 5 poses x 5 kinds x 2 appearances x 3 scales; in practice a few, about 7 KB each at 2x.
final class MenuRunnerFrameCache {
    static let shared = MenuRunnerFrameCache()

    private struct Key: Hashable {
        var pose: MenuRunPose
        var kind: MenuIconKind
        var dark: Bool
        var scale: Int
    }

    private var bitmaps = [Key: CGImage]()
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return bitmaps.count
    }

    func bitmap(_ pose: MenuRunPose, kind: MenuIconKind, appearance: NSAppearance, scale: Int) -> CGImage? {
        let key = Key(pose: pose, kind: kind, dark: MenuIconInk.isDark(appearance), scale: scale)
        lock.lock()
        if let hit = bitmaps[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let made = MenuRunnerRenderer.bitmap(pose, kind: kind, ink: .resolved(appearance), scale: scale) else { return nil }
        lock.lock()
        bitmaps[key] = made
        lock.unlock()
        return made
    }

    /// The NSImage of a frame: 24 x 18 pt, not a template. Its drawing handler picks the cached bitmap for the
    /// appearance and the backing scale AppKit draws with, so a light or dark menu bar change needs no new image, and
    /// a run frame costs one bitmap copy. `cacheMode = .never` makes AppKit run the handler again after a change.
    func image(_ pose: MenuRunPose, kind: MenuIconKind) -> NSImage {
        let image = NSImage(size: NSSize(width: MenuRunnerRenderer.size.width, height: MenuRunnerRenderer.size.height),
                            flipped: false) { [weak self] rect in
            guard let self, let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let device = abs(ctx.userSpaceToDeviceSpaceTransform.a)
            let scale = min(max(Int(device.rounded(.up)), 1), 3)
            guard let cg = self.bitmap(pose, kind: kind, appearance: NSAppearance.currentDrawing(), scale: scale) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: rect)
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }
}

/// Inks of one menu bar icon (DESIGN_V2.md 9.2 rule 2): `head` draws the head and the data mark (the menu bar text color,
/// or black in a template image, where only alpha counts); `warning` and `danger` draw the yellow glyph and the red disc
/// (tokens `dot.warning` and `dot.danger` of DESIGN_V2.md 3.3, light or dark by the menu bar appearance).
struct MenuIconInk {
    var head: CGColor
    var warning: CGColor
    var danger: CGColor

    /// One color for everything (a template image, or a gallery cell in one ink).
    static func mono(_ c: CGColor) -> MenuIconInk { MenuIconInk(head: c, warning: c, danger: c) }
    static let template = mono(CGColor(gray: 0, alpha: 1))

    static func hex(_ h: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                blue: CGFloat(h & 0xFF) / 255, alpha: alpha)
    }

    /// The badge colors of a light or dark menu bar, with the given head ink.
    static func colored(dark: Bool, head: CGColor) -> MenuIconInk {
        MenuIconInk(head: head, warning: hex(MenuIconPalette.hex(.warning, dark: dark)),
                    danger: hex(MenuIconPalette.hex(.danger, dark: dark)))
    }

    /// Dark when the appearance is a dark one (dark aqua, vibrant dark, and their high contrast variants).
    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
        return match == .darkAqua || match == .vibrantDark || match == .accessibilityHighContrastDarkAqua
            || match == .accessibilityHighContrastVibrantDark
    }

    /// `labelColor` resolved for an appearance, in sRGB.
    static func labelColor(_ appearance: NSAppearance) -> CGColor {
        var c = CGColor(gray: isDark(appearance) ? 1 : 0, alpha: 0.85)
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = NSColor.labelColor.usingColorSpace(.sRGB) { c = srgb.cgColor }
        }
        return c
    }

    /// The inks for an appearance: head in `labelColor`, badges in the tokens of that appearance.
    static func resolved(_ appearance: NSAppearance) -> MenuIconInk {
        colored(dark: isDark(appearance), head: labelColor(appearance))
    }

    /// The inks for the appearance AppKit draws with now (inside an NSImage drawing handler: the menu bar button's).
    // UNVERIFIED-ON-MAC: the status bar button draws its image with its own effective appearance (light or dark menu
    // bar, which follows the wallpaper on macOS 14). CI checks the drawing under forced aqua and darkAqua only.
    static func current() -> MenuIconInk { resolved(NSAppearance.currentDrawing()) }
}
