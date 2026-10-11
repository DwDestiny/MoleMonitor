// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (hand-written art data, docs/DESIGN.md 4.2, 8.1).
// Output: Bezier path data for the dog parts, the menu bar head and the corner badge glyphs.
// Pos: Art assets only: numbers and enums, no drawing code. Foundation only. Owner I2. DogRig never changes the shapes.
// SKELETON: every function returns an empty part list. I2 writes the real paths.

import Foundation

enum DogPathOp: Equatable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)   // Control point 1, control point 2, end point
    case close
}

enum DogPartRole: String { case fur, shade, ear, ink, tongue, blush }

struct DogPart: Equatable {
    var name: String                 // For example "body", "earNear", "legFarFront"
    var ops: [DogPathOp]             // Part-local coordinates, unit u
    var pivot: (x: Double, y: Double)   // Rotation center of the part transform
    var role: DogPartRole            // fur, shade, ear, ink, tongue, blush

    /// A tuple cannot get a synthesized Equatable, so the comparison is written by hand.
    static func == (a: DogPart, b: DogPart) -> Bool {
        if a.name != b.name || a.ops != b.ops || a.role != b.role { return false }
        return a.pivot.x == b.pivot.x && a.pivot.y == b.pivot.y
    }
}

enum DogBasePose: String, CaseIterable { case lie, stand, trot, pant }

enum DogArt {
    static let designSize: (w: Double, h: Double) = (120, 90)

    /// The 4 key poses of the card version: lie, stand, one trot frame, pant.
    static func parts(for base: DogBasePose) -> [DogPart] {
        [] // SKELETON
    }

    /// The menu bar head: relaxed, raised ears, tongue out. Design box 24 x 18 pt.
    static func menuHead(_ posture: MenuPosture) -> [DogPart] {
        [] // SKELETON
    }

    /// Corner badge glyph in a 10 x 10 pt box.
    static func badge(_ item: HealthItem) -> [DogPart] {
        [] // SKELETON
    }
}
