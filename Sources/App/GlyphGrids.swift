// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A HealthItem or MenuMark and a GlyphStyle (GlyphPaths.swift, DogArt.swift sizes).
// Output: 1x alpha grids of the badge, data mark and alarm glyphs of the menu bar icon (y down, row 0 at the top), measured on the
//         real Core Graphics raster. The UITEST icon gates (UITestIconChecks.swift) read them as XOR matrices.
// Pos: Kept from DogGallery.swift when the dog gallery was deleted (U10, 2026-10-18). Only the grid helpers survive. The menu bar
//      icon belongs to the menu bar work package; this file only measures it. Offline, no network.

import CoreGraphics
import Foundation

enum GlyphGrids {
    static let alarmSize = CGSize(width: DogArt.alarmSize, height: DogArt.alarmSize)

    /// An sRGB bitmap of `size` pt at `scale`, y down, 1 unit = 1 pt. The background stays transparent.
    static func draw(_ size: CGSize, scale: Int, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((size.width * CGFloat(scale)).rounded())
        let h = Int((size.height * CGFloat(scale)).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        body(ctx)
        return ctx.makeImage()
    }

    /// The alarm badge alone in its 9 x 9 pt box: the disc, then the glyph cleared out (as MenuIconRenderer does).
    static func drawAlarm(_ item: HealthItem, style: GlyphStyle, ink: CGColor, in ctx: CGContext) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(ink)
        for part in DogArt.alarmDisc { ctx.addPath(GlyphPaths.cgPath(part.ops)) }
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        ctx.addPath(GlyphPaths.alarmKnockout(item, style: style))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()
    }

    static func alarmGrid(_ item: HealthItem, style: GlyphStyle) -> [[Double]] {
        alphaGrid(alarmSize) { ctx in drawAlarm(item, style: style, ink: CGColor(gray: 0, alpha: 1), in: ctx) }
    }

    /// Alpha grid of a 1x render on a transparent background, y down, row 0 at the top.
    static func alphaGrid(_ size: CGSize, _ body: (CGContext) -> Void) -> [[Double]] {
        let w = Int(size.width), h = Int(size.height)
        guard let image = draw(size, scale: 1, body),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return Array(repeating: Array(repeating: 0, count: w), count: h)
        }
        let row = image.bytesPerRow
        var grid = [[Double]]()
        for y in 0..<h {
            var line = [Double]()
            for x in 0..<w {
                line.append(Double(bytes[y * row + x * 4 + 3]) / 255)
            }
            grid.append(line)
        }
        return grid
    }

    /// The data mark (collecting or stale) alone in the 8 x 8 pt box at 1x.
    static func markGrid(_ mark: MenuMark) -> [[Double]] {
        alphaGrid(CGSize(width: DogArt.badgeSize, height: DogArt.badgeSize)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(GlyphPaths.markYDown(mark))
            ctx.fillPath()
        }
    }

    static func badgeGrid(_ item: HealthItem, style: GlyphStyle) -> [[Double]] {
        alphaGrid(CGSize(width: DogArt.badgeSize, height: DogArt.badgeSize)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(GlyphPaths.badgeYDown(item, style: style))
            ctx.fillPath()
        }
    }
}
