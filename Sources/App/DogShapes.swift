// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: DogArt path data, DogRig layers, a menu icon state (docs/DESIGN.md 3, 4.2, 4.6).
// Output: Core Graphics drawing of the card Bichon and of the menu bar icon (five states, DESIGN_V2.md 9).
// Pos: The one renderer for DogView, StatusIconController and DogGallery. Builds each CGPath once and caches it. Owner WP-E
//      (WP-D's DogView vector fallback calls DogRenderer and does not change it).
// Stage 2: `drawFrame` draws an animated DogView frame (with the art crossfade of a gait switch), and the menu renderer
// draws MenuIconFrame values, so the switch animation and the still icon share one drawing path.
//
// All drawing here uses y-down coordinates: the caller flips the context (or uses a flipped NSImage).

import AppKit
import CoreGraphics
import Foundation

/// CGPath cache: one path per distinct op list, built on first use (DESIGN.md 4.6). Locked, so any thread may draw.
final class DogPathCache {
    static let shared = DogPathCache()
    private var cache = [[DogPathOp]: CGPath]()
    private let lock = NSLock()

    static func path(_ ops: [DogPathOp]) -> CGPath { shared.lookup(ops) }
    static var count: Int { shared.lock.lock(); defer { shared.lock.unlock() }; return shared.cache.count }

    private func lookup(_ ops: [DogPathOp]) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[ops] { return hit }
        let p = GlyphPaths.cgPath(ops)
        cache[ops] = p
        return p
    }
}

/// Color tokens of DESIGN.md 4.2, light and dark. `muted` is the gray dog of collecting and stale (DESIGN.md 4.7):
/// neutral grays without warmth, a light gray outline and mid gray eyes. It stays calmer than the normal dog (no near black
/// ink, no pink) but its outline is far enough from the card surface to read at 72 x 54 pt (I2 stage 2, I3 request 6).
struct DogPalette {
    var dark: Bool
    var muted = false

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var outline: CGColor {
        if muted { return dark ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25) : DogPalette.rgb(0xC2C2C6) }
        return dark ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.2) : DogPalette.rgb(0xD8D2C8)
    }

    func color(_ role: DogPartRole) -> CGColor {
        if muted { return mutedColor(role) }
        switch role {
        case .fur, .bubble: return dark ? DogPalette.rgb(0xF5F2ED) : DogPalette.rgb(0xFFFFFF)
        case .shade: return dark ? DogPalette.rgb(0xD9D4CC) : DogPalette.rgb(0xECE7DF)
        case .ear: return dark ? DogPalette.rgb(0xE6DCCD) : DogPalette.rgb(0xF4ECE2)
        case .ink, .cutout: return DogPalette.rgb(0x1D1D1F)
        case .tongue: return DogPalette.rgb(0xFF7A93)
        case .tongueLine: return DogPalette.rgb(0xE0566F)
        case .blush: return DogPalette.rgb(0xFF9FB2, 0.45)
        case .highlight: return DogPalette.rgb(0xFFFFFF)
        case .shadow: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.35 : 0.10)
        // Round 3: sweat drops, a pale blue that stays lighter than the fur outline.
        case .effect: return dark ? DogPalette.rgb(0x8CC4F2, 0.5) : DogPalette.rgb(0x6EAAE1, 0.55)
        }
    }

    private func mutedColor(_ role: DogPartRole) -> CGColor {
        switch role {
        case .fur, .bubble: return dark ? DogPalette.rgb(0x8A8A8E) : DogPalette.rgb(0xF2F2F3)
        case .shade: return dark ? DogPalette.rgb(0x7A7A7E) : DogPalette.rgb(0xE3E3E6)
        case .ear: return dark ? DogPalette.rgb(0x808084) : DogPalette.rgb(0xE9E9EC)
        case .ink, .cutout: return dark ? DogPalette.rgb(0x2C2C2E) : DogPalette.rgb(0x9A9A9F)
        case .tongue: return dark ? DogPalette.rgb(0x9A9A9E) : DogPalette.rgb(0xC7C7CC)
        case .tongueLine: return dark ? DogPalette.rgb(0x6C6C70) : DogPalette.rgb(0xAEAEB2)
        case .blush: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        case .highlight: return dark ? DogPalette.rgb(0x9C9CA0) : DogPalette.rgb(0xFFFFFF)
        case .shadow: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.25 : 0.06)
        case .effect: return dark ? DogPalette.rgb(0x8E8E93, 0.5) : DogPalette.rgb(0xAEAEB2, 0.55)
        }
    }

    /// Bubble glyph color: the level text token (DESIGN.md 2.6).
    func glyph(_ level: HealthLevel) -> CGColor {
        if muted { return dark ? DogPalette.rgb(0x2C2C2E) : DogPalette.rgb(0x9A9A9F) }
        if level == .red { return dark ? DogPalette.rgb(0xFF7A72) : DogPalette.rgb(0xB3261E) }
        return dark ? DogPalette.rgb(0xFFB340) : DogPalette.rgb(0x8F4D00)
    }
}

enum DogRenderer {
    static let outlineWidth: CGFloat = 2.2
    private static let outlined: Set<DogPartRole> = [.fur, .shade, .ear, .bubble]

    /// Draws one frame. `ctx` is y-down and already scaled so that 1 u is one design unit.
    static func draw(_ layers: [DogLayer], opacity: Double, palette: DogPalette, level: HealthLevel, in ctx: CGContext) {
        guard opacity > 0 else { return }
        // A group layer is needed only to fade the whole dog; at full opacity it would draw the same pixels slower.
        let grouped = opacity < 1
        ctx.saveGState()
        if grouped {
            ctx.setAlpha(CGFloat(opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        var i = 0
        while i < layers.count {
            var j = i
            if outlined.contains(layers[i].part.role) {
                while j + 1 < layers.count, outlined.contains(layers[j + 1].part.role), layers[j + 1].part.layer == layers[i].part.layer {
                    j += 1
                }
                ctx.setLineJoin(.round)
                ctx.setLineWidth(outlineWidth)
                for k in i...j {
                    let path = transformed(layers[k])
                    ctx.setStrokeColor(faded(palette.outline, layers[k].alpha))
                    ctx.setFillColor(faded(palette.outline, layers[k].alpha))
                    ctx.addPath(path)
                    ctx.drawPath(using: .fillStroke)
                }
            }
            for k in i...j {
                let layer = layers[k]
                let path = transformed(layer)
                let base = layer.part.name.hasPrefix("glyph.") ? palette.glyph(level) : palette.color(layer.part.role)
                ctx.setFillColor(faded(base, layer.alpha))
                ctx.addPath(path)
                ctx.fillPath()
                if layer.part.name == "body" { shadeBelly(path, palette: palette, in: ctx) }
            }
            i = j + 1
        }
        if grouped { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// The only gradient: black 6 % to 0 on the lower body, radius 24 u (DESIGN.md 4.2 step 4).
    private static func shadeBelly(_ body: CGPath, palette: DogPalette, in ctx: CGContext) {
        let box = body.boundingBoxOfPath
        let center = CGPoint(x: box.midX, y: box.maxY - 2)
        let colors = [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: palette.dark ? 0.08 : 0.06),
                      CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 24, options: [])
        ctx.restoreGState()
    }

    static func transformed(_ layer: DogLayer) -> CGPath {
        let t = layer.transform
        var cg = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        let base = DogPathCache.path(layer.part.ops)
        return base.copy(using: &cg) ?? base
    }

    private static func faded(_ c: CGColor, _ alpha: Double) -> CGColor {
        alpha >= 1 ? c : (c.copy(alpha: c.alpha * CGFloat(max(0, alpha))) ?? c)
    }

    /// Draws one animated frame of DogView into `rect` (y-down context). During a gait switch that changes the art,
    /// the old art is drawn first, the new art on top, both with the same blended pose. The new art fades in while the
    /// blend goes from 35 % to 50 %, the old art fades out from 50 % to 65 %, so the two dogs overlap for about 3 frames
    /// only (the first CI timeline showed a long double image) and the dog never turns see-through.
    static func newArtAlpha(_ k: Double) -> Double { min(max((k - 0.35) / 0.15, 0), 1) }
    static func oldArtAlpha(_ k: Double) -> Double { min(max((0.65 - k) / 0.15, 0), 1) }

    static func drawFrame(_ frame: DogFrame, input: DogInput, dark: Bool, in rect: CGRect, ctx: CGContext) {
        let glyph = (frame.pose.bubble > 0) ? input.worstProblem.map { DogArt.badge($0) } : nil
        let palette = DogPalette(dark: dark, muted: input.isStatic)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / CGFloat(DogArt.designSize.w), y: rect.height / CGFloat(DogArt.designSize.h))
        if let old = frame.fadeFrom {
            let k = min(max(frame.fade, 0), 1)
            draw(DogRig.layers(gait: old, pose: frame.pose, glyph: glyph), opacity: frame.pose.opacity * DogRenderer.oldArtAlpha(k),
                 palette: palette, level: input.worstLevel, in: ctx)
            draw(DogRig.layers(gait: frame.gait, pose: frame.pose, glyph: glyph), opacity: frame.pose.opacity * DogRenderer.newArtAlpha(k),
                 palette: palette, level: input.worstLevel, in: ctx)
        } else {
            draw(DogRig.layers(gait: frame.gait, pose: frame.pose, glyph: glyph), opacity: frame.pose.opacity,
                 palette: palette, level: input.worstLevel, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Draws the static frame of an input into `rect` (y-down context).
    /// `phase` picks a stride frame; the default pi / 2 is the key frame (the gallery also draws frames A and B).
    static func drawStatic(_ input: DogInput, gait: DogGait? = nil, phase: Double = Double.pi / 2, dark: Bool,
                           in rect: CGRect, ctx: CGContext) {
        let g = gait ?? DogMotor.staticGait(for: input)
        let pose = DogMotor.staticPose(gait: g, input: input, phase: phase)
        let glyph = (pose.bubble > 0) ? input.worstProblem.map { DogArt.badge($0) } : nil
        let layers = DogRig.layers(gait: g, pose: pose, glyph: glyph)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / CGFloat(DogArt.designSize.w), y: rect.height / CGFloat(DogArt.designSize.h))
        draw(layers, opacity: pose.opacity, palette: DogPalette(dark: dark, muted: input.isStatic), level: input.worstLevel, in: ctx)
        ctx.restoreGState()
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

/// The menu bar icon: Bichon head on the left, badge or data mark on the right (DESIGN.md 3.1 to 3.4, DESIGN_V2.md 9).
/// Round 2 (I2): the head (x 0 to 15) and the badge (x 16 to 24) never overlap, so there is no badge gap and the head
/// is never cut. The ears are part of one head silhouette, so there is no ear gap either.
/// Round 3 (I2): the red level (pant head) gets the alarm badge, a 9 x 9 pt solid disc at x 15 to 24 with the glyph
/// knocked out (alpha 0). The yellow level keeps the 8 x 8 pt glyph. The tongue is drawn at 55 % alpha.
/// v2 (WP-E, DESIGN_V2.md 9.2): five states. The yellow glyph and the red disc are colored, so their images are not
/// templates: the head is drawn in the menu bar text color at draw time. Normal, collecting and stale stay template images.
/// Collecting and stale draw the hollow head with a data mark (three dots, clock) in the 8 x 8 pt badge box.
enum MenuIconRenderer {
    static let size = CGSize(width: DogArt.menuSize.w, height: DogArt.menuSize.h)
    /// Clear stroke around the tongue: half of it (0.75 pt) separates the tongue from the chin.
    static let knockout: CGFloat = 1.5
    /// Width of the hollow ring, inside the silhouette (1.5 pt, so that it covers whole pixels at 2x and most of a pixel at 1x).
    static let hollowLine: CGFloat = 1.5

    /// Draws a still state at `origin` (top left) in a y-down context, 1 unit = 1 pt.
    static func draw(_ state: MenuIconState, style: GlyphStyle, ink: MenuIconInk, at origin: CGPoint = .zero, in ctx: CGContext) {
        draw(MenuMotion.still(state), style: style, ink: ink, mark: state.mark, at: origin, cached: true, in: ctx)
    }

    /// The same in one ink (alpha studies, template look).
    static func draw(_ state: MenuIconState, style: GlyphStyle, ink: CGColor, at origin: CGPoint = .zero, in ctx: CGContext) {
        draw(state, style: style, ink: .mono(ink), at: origin, in: ctx)
    }

    /// Draws one frame in one ink (the switch animation of the dog checks and the gallery).
    static func draw(_ frame: MenuIconFrame, style: GlyphStyle, ink: CGColor, at origin: CGPoint = .zero,
                     cached: Bool, in ctx: CGContext) {
        draw(frame, style: style, ink: .mono(ink), mark: nil, at: origin, cached: cached, in: ctx)
    }

    /// Draws one frame (a still state or a frame of the switch animation, DESIGN.md 3.5). `cached` false builds the
    /// paths of morphed frames without the shared cache, so the cache keeps only the still art. `mark` adds the data
    /// mark of collecting or stale in the badge box.
    static func draw(_ frame: MenuIconFrame, style: GlyphStyle, ink: MenuIconInk, mark: MenuMark?, at origin: CGPoint = .zero,
                     cached: Bool, in ctx: CGContext) {
        func path(_ part: DogPart) -> CGPath { cached ? DogPathCache.path(part.ops) : GlyphPaths.cgPath(part.ops) }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // The head and the mark are one layer in the opaque head color, composited at the ink alpha (labelColor has
        // alpha 0.85), so overlapping parts do not add up to a darker seam.
        ctx.saveGState()
        ctx.setAlpha(ink.head.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let headOpaque = ink.head.copy(alpha: 1) ?? ink.head
        ctx.setFillColor(headOpaque)
        ctx.setStrokeColor(headOpaque)
        let parts = frame.head
        if frame.hollow {
            // Inner ring of the silhouette: clip to the head, stroke twice the ring width, so the ring lies
            // fully inside the outline and the outer edge stays where the solid icon has it. Then the face, solid.
            for part in parts where part.role == .fur {
                let p = path(part)
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                ctx.setLineWidth(hollowLine * 2)
                ctx.setLineJoin(.round)
                ctx.addPath(p)
                ctx.strokePath()
                ctx.restoreGState()
            }
            for part in parts where part.role == .cutout { fill(path(part), clear: false, in: ctx) }
        } else {
            for part in parts {
                let p = path(part)
                if part.role == .tongue {
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    ctx.setLineWidth(knockout)
                    ctx.setLineJoin(.round)
                    ctx.addPath(p)
                    ctx.strokePath()
                    ctx.restoreGState()
                    // Lighter than the face: the tongue reads as a tongue, not as a beard.
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(DogArt.menuTongueAlpha))
                    fill(p, clear: false, in: ctx)
                    ctx.restoreGState()
                    continue
                }
                fill(p, clear: part.role == .cutout, in: ctx)
            }
        }
        if let mark {
            ctx.saveGState()
            ctx.translateBy(x: DogArt.menuBadgeOrigin.x, y: DogArt.menuBadgeOrigin.y)
            ctx.addPath(cached ? markPath(mark) : GlyphPaths.markYDown(mark))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        if let badge = frame.badge, frame.badgeScale > 0.001 {
            let side = frame.alarm ? DogArt.alarmSize : DogArt.badgeSize
            let o = frame.alarm ? DogArt.alarmOrigin : DogArt.menuBadgeOrigin
            ctx.saveGState()
            ctx.translateBy(x: o.x, y: o.y)
            if frame.badgeScale != 1 {
                let k = CGFloat(frame.badgeScale), c = CGFloat(side / 2)
                ctx.translateBy(x: c, y: c)
                ctx.scaleBy(x: k, y: k)
                ctx.translateBy(x: -c, y: -c)
            }
            if frame.alarm {
                ctx.setFillColor(ink.danger)
                for part in DogArt.alarmDisc { fill(DogPathCache.path(part.ops), clear: false, in: ctx) }
                fill(GlyphPaths.alarmKnockout(badge.item, style: style), clear: true, in: ctx)
            } else {
                ctx.setFillColor(ink.warning)
                ctx.addPath(GlyphPaths.badgeYDown(badge.item, style: style))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The two mark paths, built once.
    private static let markPaths: [MenuMark: CGPath] = Dictionary(uniqueKeysWithValues: MenuMark.allCases.map { ($0, GlyphPaths.markYDown($0)) })
    private static func markPath(_ m: MenuMark) -> CGPath { markPaths[m] ?? GlyphPaths.markYDown(m) }

    private static func fill(_ path: CGPath, clear: Bool, in ctx: CGContext) {
        ctx.saveGState()
        if clear { ctx.setBlendMode(.clear) }
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The still NSImage of a state: 24 x 18 pt, vector, drawn again for each backing scale. Normal, collecting and
    /// stale: a template image. Caution and alert: not a template; the drawing handler resolves the head ink
    /// (`labelColor`) and the badge color for the appearance AppKit draws with, and `cacheMode = .never` makes AppKit
    /// run the handler again after an appearance change (DESIGN_V2.md 9.2 rule 2).
    static func image(_ state: MenuIconState, style: GlyphStyle = GlyphPaths.chosen) -> NSImage {
        let frame = MenuMotion.still(state)
        let template = state.kind.isTemplate
        let mark = state.mark
        let image = NSImage(size: NSSize(width: size.width, height: size.height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink: MenuIconInk = template ? .template : .current()
            MenuIconRenderer.draw(frame, style: style, ink: ink, mark: mark, cached: true, in: ctx)
            return true
        }
        image.isTemplate = template
        if !template { image.cacheMode = .never }
        return image
    }

    /// An NSImage of one frame. Frames of the switch animation are bitmaps (1x and 2x reps), made once per
    /// switch and kept by StatusIconController, so playing them never draws paths again. `appearance` nil gives a
    /// template image in black (the stage 2 behavior). With an appearance, the frame is drawn in the inks of that
    /// appearance and the image is not a template, so the colored badge stays colored during the play.
    static func image(_ frame: MenuIconFrame, style: GlyphStyle = GlyphPaths.chosen, cached: Bool,
                      appearance: NSAppearance? = nil) -> NSImage {
        let pt = NSSize(width: size.width, height: size.height)
        let ink: MenuIconInk = appearance.map { MenuIconInk.resolved($0) } ?? .template
        let template = appearance == nil
        if cached {
            let image = NSImage(size: pt, flipped: true) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                MenuIconRenderer.draw(frame, style: style, ink: ink, mark: nil, cached: true, in: ctx)
                return true
            }
            image.isTemplate = template
            return image
        }
        let image = NSImage(size: pt)
        for scale in [1, 2] {
            let w = Int(size.width) * scale, h = Int(size.height) * scale
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            MenuIconRenderer.draw(frame, style: style, ink: ink, mark: nil, cached: false, in: ctx)
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = pt
            image.addRepresentation(rep)
        }
        image.isTemplate = template
        return image
    }
}
