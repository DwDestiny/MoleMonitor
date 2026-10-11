// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: DogArt path data, DogRig layers, a menu icon state (docs/DESIGN.md 3, 4.2, 4.6).
// Output: Core Graphics drawing of the card Bichon and of the menu bar template icon.
// Pos: The one renderer for DogView, StatusIconController and DogGallery. Builds each CGPath once and caches it. Owner I2.
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
        ctx.saveGState()
        ctx.setAlpha(CGFloat(opacity))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
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
        ctx.endTransparencyLayer()
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
    /// the old art is drawn first and fades out in the second half, the new art fades in on top in the first half,
    /// so the dog never turns see-through. Both use the same blended pose.
    static func drawFrame(_ frame: DogFrame, input: DogInput, dark: Bool, in rect: CGRect, ctx: CGContext) {
        let glyph = (frame.pose.bubble > 0) ? input.worstProblem.map { DogArt.badge($0) } : nil
        let palette = DogPalette(dark: dark, muted: input.isStatic)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / CGFloat(DogArt.designSize.w), y: rect.height / CGFloat(DogArt.designSize.h))
        if let old = frame.fadeFrom {
            let k = min(max(frame.fade, 0), 1)
            draw(DogRig.layers(gait: old, pose: frame.pose, glyph: glyph), opacity: frame.pose.opacity * min(1, 2 * (1 - k)),
                 palette: palette, level: input.worstLevel, in: ctx)
            draw(DogRig.layers(gait: frame.gait, pose: frame.pose, glyph: glyph), opacity: frame.pose.opacity * min(1, 2 * k),
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

/// The menu bar template icon: Bichon head on the left, badge on the right (DESIGN.md 3.1 to 3.4). Alpha is all that matters.
/// Round 2 (I2): the head (x 0 to 15) and the badge (x 16 to 24) never overlap, so there is no badge gap and the head
/// is never cut. The ears are part of one head silhouette, so there is no ear gap either.
/// Round 3 (I2): the red level (pant head) gets the alarm badge, a 9 x 9 pt solid disc at x 15 to 24 with the glyph
/// knocked out (alpha 0). The yellow level keeps the 8 x 8 pt glyph. The tongue is drawn at 55 % alpha.
enum MenuIconRenderer {
    static let size = CGSize(width: DogArt.menuSize.w, height: DogArt.menuSize.h)
    /// Clear stroke around the tongue: half of it (0.75 pt) separates the tongue from the chin.
    static let knockout: CGFloat = 1.5
    /// Width of the hollow ring, inside the silhouette (1.5 pt, so that it covers whole pixels at 2x and most of a pixel at 1x).
    static let hollowLine: CGFloat = 1.5

    /// Draws the icon at `origin` (top left) in a y-down context, 1 unit = 1 pt. `ink` is the template ink.
    static func draw(_ state: MenuIconState, style: GlyphStyle, ink: CGColor, at origin: CGPoint = .zero, in ctx: CGContext) {
        draw(MenuMotion.still(state), style: style, ink: ink, at: origin, cached: true, in: ctx)
    }

    /// Draws one frame (a still state or a frame of the switch animation, DESIGN.md 3.5). `cached` false builds the
    /// paths of morphed frames without the shared cache, so the cache keeps only the still art.
    static func draw(_ frame: MenuIconFrame, style: GlyphStyle, ink: CGColor, at origin: CGPoint = .zero,
                     cached: Bool, in ctx: CGContext) {
        func path(_ part: DogPart) -> CGPath { cached ? DogPathCache.path(part.ops) : GlyphPaths.cgPath(part.ops) }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
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
        if let badge = frame.badge, frame.badgeScale > 0.001 {
            let side = frame.alarm ? DogArt.alarmSize : DogArt.badgeSize
            let o = frame.alarm ? DogArt.alarmOrigin : DogArt.menuBadgeOrigin
            ctx.translateBy(x: o.x, y: o.y)
            if frame.badgeScale != 1 {
                let k = CGFloat(frame.badgeScale), c = CGFloat(side / 2)
                ctx.translateBy(x: c, y: c)
                ctx.scaleBy(x: k, y: k)
                ctx.translateBy(x: -c, y: -c)
            }
            if frame.alarm {
                for part in DogArt.alarmDisc { fill(DogPathCache.path(part.ops), clear: false, in: ctx) }
                fill(GlyphPaths.alarmKnockout(badge.item, style: style), clear: true, in: ctx)
            } else {
                ctx.addPath(GlyphPaths.badgeYDown(badge.item, style: style))
                ctx.fillPath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func fill(_ path: CGPath, clear: Bool, in ctx: CGContext) {
        ctx.saveGState()
        if clear { ctx.setBlendMode(.clear) }
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// A template NSImage of the icon: 24 x 18 pt, vector, drawn again for each backing scale.
    static func image(_ state: MenuIconState, style: GlyphStyle = GlyphPaths.chosen) -> NSImage {
        image(MenuMotion.still(state), style: style, cached: true)
    }

    /// A template NSImage of one frame. Frames of the switch animation are bitmaps (1x and 2x reps), made once per
    /// switch and kept by StatusIconController, so playing them never draws paths again.
    static func image(_ frame: MenuIconFrame, style: GlyphStyle = GlyphPaths.chosen, cached: Bool) -> NSImage {
        let pt = NSSize(width: size.width, height: size.height)
        if cached {
            let image = NSImage(size: pt, flipped: true) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                MenuIconRenderer.draw(frame, style: style, ink: CGColor(gray: 0, alpha: 1), cached: true, in: ctx)
                return true
            }
            image.isTemplate = true
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
            MenuIconRenderer.draw(frame, style: style, ink: CGColor(gray: 0, alpha: 1), cached: false, in: ctx)
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = pt
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
}
