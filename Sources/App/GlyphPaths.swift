// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A health item and a glyph style (docs/DESIGN.md 3.3, 8.4, 8.5).
// Output: The category badge path in a 10 x 10 pt box, y up.
// Pos: One glyph source for the menu bar badge and the card's CategoryGlyph (I3 calls it). Owner I2.
// SKELETON: every glyph is a 10 x 10 pt square. I2 draws the real glyphs and letters.

import CoreGraphics
import Foundation

/// Which badge design to draw. `glyph` is the default (DESIGN.md 3.3). `letter` is the fallback.
/// Not listed in DESIGN.md 8.1 at skeleton time: `GlyphPaths.badge(_:style:)` needs it.
enum GlyphStyle: String, CaseIterable {
    case glyph, letter
}

enum GlyphPaths {
    /// Badge path for one health item, inside (0, 0, 10, 10).
    static func badge(_ item: HealthItem, style: GlyphStyle) -> CGPath {
        CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil) // SKELETON
    }
}
