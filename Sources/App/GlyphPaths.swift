// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A health item and a glyph style (docs/DESIGN.md 3.3, 8.4, 8.5).
// Output: The category badge path: `badge` is y up in a 10 x 10 pt box (fixed contract, the card's CategoryGlyph),
// `badgeYDown` is y down in a box of any size, by default the 8 x 8 pt menu bar box (DogArt.badgeSize).
// `alarmKnockout` is the glyph cut out of the 9 x 9 pt alarm disc (red level, round 3).
// `markYDown` is the data mark of collecting (three dots) and stale (clock), y down in the 8 x 8 pt box (DESIGN_V2.md 9.2).
// Pos: One glyph source for the menu bar badge, the bubble and the card's CategoryGlyph (I3 calls it). Owner WP-E.
//
// Glyphs come from the fixed art in DogArt.badge (8 x 8 pt art), scaled to the box. Letters (the fallback) come from
// SF Pro Rounded Bold, cap height 0.8 x the box, centered in the box. The menu bar uses `.glyph`: all 10 pairs pass the 1x XOR gate (badge-matrix.json).

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Which badge design to draw. `glyph` is the default and the final choice (DESIGN.md 3.3). `letter` is the fallback.
enum GlyphStyle: String, CaseIterable {
    case glyph, letter
}

enum GlyphPaths {
    /// The style the menu bar and the card use. The gallery checks both and records the choice.
    static let chosen: GlyphStyle = .glyph

    /// The letter of each item in the fallback style.
    static func letter(_ item: HealthItem) -> String {
        switch item {
        case .cpu: return "C"
        case .memory: return "M"
        case .thermal: return "T"
        case .disk: return "D"
        case .power: return "P"
        }
    }

    /// Badge path for one health item, inside (0, 0, 10, 10), y up. The signature and the box are fixed by the skeleton.
    static func badge(_ item: HealthItem, style: GlyphStyle) -> CGPath {
        let box: CGFloat = 10
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box)
        let down = badgeYDown(item, style: style, box: box)
        return down.copy(using: &flip) ?? down
    }

    /// Badge path for one health item, inside (0, 0, box, box), y down (the DogArt coordinate system).
    static func badgeYDown(_ item: HealthItem, style: GlyphStyle, box: CGFloat = CGFloat(DogArt.badgeSize)) -> CGPath {
        switch style {
        case .glyph:
            let path = CGMutablePath()
            let k = box / CGFloat(DogArt.badgeSize)
            let t = CGAffineTransform(scaleX: k, y: k)
            for part in DogArt.badge(item) { path.addPath(cgPath(part.ops), transform: t) }
            return path
        case .letter:
            return letterPath(letter(item), box: box)
        }
    }

    /// Knockout of the alarm badge (red level), inside (0, 0, 9, 9), y down: the part the renderer clears out of the
    /// 9 x 9 pt disc (DogArt.alarmDisc). Glyph style: pixel-aligned art (DogArt.alarmBadge). Letter style: the letter,
    /// cap height 0.6 x the box, so a ring of the disc stays around it.
    static func alarmKnockout(_ item: HealthItem, style: GlyphStyle) -> CGPath {
        let box = CGFloat(DogArt.alarmSize)
        switch style {
        case .glyph:
            let path = CGMutablePath()
            for part in DogArt.alarmBadge(item) { path.addPath(cgPath(part.ops)) }
            return path
        case .letter:
            let inner = box * 0.75
            var t = CGAffineTransform(translationX: (box - inner) / 2, y: (box - inner) / 2)
            let p = letterPath(letter(item), box: inner)
            return p.copy(using: &t) ?? p
        }
    }

    /// Data mark path (collecting or stale), inside (0, 0, box, box), y down. Fill with the nonzero rule.
    static func markYDown(_ mark: MenuMark, box: CGFloat = CGFloat(DogArt.badgeSize)) -> CGPath {
        let path = CGMutablePath()
        let k = box / CGFloat(DogArt.badgeSize)
        let t = CGAffineTransform(scaleX: k, y: k)
        for part in DogArt.mark(mark) { path.addPath(cgPath(part.ops), transform: t) }
        return path
    }

    /// One CGPath from DogArt ops, no cache.
    static func cgPath(_ ops: [DogPathOp]) -> CGPath {
        let p = CGMutablePath()
        for op in ops {
            switch op {
            case let .move(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .cubic(x1, y1, x2, y2, x, y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// SF Pro Rounded Bold letter, cap height 0.8 x `box`, centered in the box, y down.
    private static func letterPath(_ text: String, box: CGFloat) -> CGPath {
        let probe = roundedBold(10)
        let cap = probe.capHeight > 0 ? probe.capHeight : 7
        let font = roundedBold(10 * 0.8 * box / cap) as CTFont
        var chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
            return CGPath(rect: CGRect(x: box * 0.1, y: box * 0.1, width: box * 0.8, height: box * 0.8), transform: nil)
        }
        // Raw glyph path: y up, baseline at 0. Flip to y down, then center the ink box in the box.
        let ink = raw.boundingBoxOfPath
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: box / 2 - ink.midX, ty: box / 2 + ink.midY)
        return raw.copy(using: &t) ?? raw
    }

    private static func roundedBold(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }
}
