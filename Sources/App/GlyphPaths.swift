// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A health item and a glyph style (docs/DESIGN.md 3.3, 8.4, 8.5).
// Output: The category badge path in a 10 x 10 pt box: `badge` is y up (AppKit), `badgeYDown` is y down.
// Pos: One glyph source for the menu bar badge, the bubble and the card's CategoryGlyph (I3 calls it). Owner I2.
//
// Glyphs come from the fixed art in DogArt.badge. Letters (the fallback) come from SF Pro Rounded Bold,
// cap height 8 pt, centered in the box. The menu bar uses `.glyph`: all 10 pairs pass the 1x XOR gate (badge-matrix.json).

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

    /// Badge path for one health item, inside (0, 0, 10, 10), y up.
    static func badge(_ item: HealthItem, style: GlyphStyle) -> CGPath {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(DogArt.badgeSize))
        let down = badgeYDown(item, style: style)
        return down.copy(using: &flip) ?? down
    }

    /// Badge path for one health item, inside (0, 0, 10, 10), y down (the DogArt coordinate system).
    static func badgeYDown(_ item: HealthItem, style: GlyphStyle) -> CGPath {
        switch style {
        case .glyph:
            let path = CGMutablePath()
            for part in DogArt.badge(item) { path.addPath(cgPath(part.ops)) }
            return path
        case .letter:
            return letterPath(letter(item))
        }
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

    /// SF Pro Rounded Bold letter, cap height 8 pt, centered in the 10 x 10 box, y down.
    private static func letterPath(_ text: String) -> CGPath {
        let probe = roundedBold(10)
        let cap = probe.capHeight > 0 ? probe.capHeight : 7
        let font = roundedBold(10 * 8 / cap) as CTFont
        var chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
            return CGPath(rect: CGRect(x: 1, y: 1, width: 8, height: 8), transform: nil)
        }
        // Raw glyph path: y up, baseline at 0. Flip to y down, then center the ink box in the 10 x 10 box.
        let box = raw.boundingBoxOfPath
        let size = CGFloat(DogArt.badgeSize)
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: size / 2 - box.midX, ty: size / 2 + box.midY)
        return raw.copy(using: &t) ?? raw
    }

    private static func roundedBold(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }
}
