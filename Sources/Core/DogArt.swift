// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (hand-written art data, docs/DESIGN.md 4.2, 8.1).
// Output: Bezier path data for the dog parts and the corner badge, data mark and alarm glyphs (the menu bar head art
//         was deleted by Q4, 2026-10-18: MenuRunner.swift draws the menu bar icon).
// Pos: Art assets: numbers, names and enums. No drawing code. Foundation only. Owner WP-E (menu bar art; the card art is
//      shared with WP-D's vector fallback). DogRig never changes the shapes.
//
// Coordinates: the card dog uses a 120 x 90 u box, origin top left, y down, the dog faces right, ground y = 82.
// Attention (yellow): the 8 x 8 pt outline glyph sits at x 16 to 24, y 9 to 17.
// Alarm (red): a 9 x 9 pt solid disc at x 15 to 24, y 9 to 18, the glyph knocked out of it (round 3).
// Data marks (v2, DESIGN_V2.md 9.2): collecting (three dots) and stale (clock) use the same 8 x 8 pt box as the yellow glyph.
// The head and the badge never overlap, so no cutout gap is needed.
// GlyphPaths and the menu renderer flip y for AppKit.
//
// Each shape is SVG-style path data (M, L, C, Z, absolute). The numbers were placed by hand on an authoring
// sheet: anchors around the silhouette, one cubic "lock of fur" per edge. Edit the numbers to change the art.

import Foundation

enum DogPathOp: Hashable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)   // Control point 1, control point 2, end point
    case close
}

/// Paint role of a part. The renderer maps a role to a color token (docs/DESIGN.md 4.2).
/// fur, shade, ear and bubble get the soft outline. cutout clears pixels (menu head eyes, nose, mouth).
/// Added after the skeleton: tongueLine, highlight, shadow, bubble, effect, cutout (DESIGN.md 8.1).
/// Round 3 (I2): bundle, bundleDot and strap are gone with the bundle.
enum DogPartRole: String, CaseIterable {
    case fur, shade, ear, ink, tongue, blush
    case tongueLine, highlight, shadow, bubble, effect, cutout
}

struct DogPart: Equatable {
    var name: String                 // For example "body", "head.ear", "leg.farFore". The prefix picks the rig transform.
    var ops: [DogPathOp]             // Part-local coordinates, unit u (card) or pt (menu, badge)
    var pivot: (x: Double, y: Double)   // Rotation center of the part transform
    var role: DogPartRole
    /// Outline group. Adjacent outlined parts with the same layer share one outline: the renderer strokes all of them
    /// first, then fills all of them, so overlapping locks merge into one silhouette. Added after the skeleton (DESIGN.md 8.1).
    var layer: Int = 0

    /// A tuple cannot get a synthesized Equatable, so the comparison is written by hand.
    static func == (a: DogPart, b: DogPart) -> Bool {
        if a.name != b.name || a.ops != b.ops || a.role != b.role || a.layer != b.layer { return false }
        return a.pivot.x == b.pivot.x && a.pivot.y == b.pivot.y
    }
}

enum DogBasePose: String, CaseIterable { case lie, stand, trot, pant }

/// Head art variants. `smile` for lie and stand, `open` for trot and sprint, `pant` when the thermal state is red.
enum DogHeadVariant: String, CaseIterable { case smile, open, pant }

/// Overlay art drawn on top of a base pose.
/// Round 2 (I2): the speed lines are gone. Sprint reads from the body lean and the blown-back ears.
/// Round 3 (I2): the bundle is gone; the heat lines became two short sweat drops.
enum DogOverlay: String, CaseIterable { case bubble, sweat }

enum DogArt {
    static let designSize: (w: Double, h: Double) = (120, 90)
    static let groundY = 82.0
    /// Half width of a paw bottom (u). The rig uses it to put a swung paw corner back on the ground.
    static let pawHalfWidth = 4.5
    /// The lie pose moves the whole head down by this offset (u). The head art itself is the same.
    static let lieHeadOffset: (x: Double, y: Double) = (3, 16)
    /// Where the badge glyph sits in the thought bubble (u): a 16 x 16 box centered in the 24.4 u bubble
    /// (round 3: 16 px with its outline at the 72 pt card). The glyph is the same art as the menu bar badge (DogArt.badge).
    static let bubbleGlyphFrame: (x: Double, y: Double, size: Double) = (98.7, 5.3, 16)
    /// The thought bubble circle (u), top right corner; with its 1.1 u outline it touches x 120 and y 0.
    static let bubbleCircle: (x: Double, y: Double, r: Double) = (106.7, 13.3, 12.2)
    /// While the bubble shows, the dog shrinks to this scale about `bubbleShrinkAnchor` (a point on the ground
    /// at the tail side), so the bubble keeps at least 2 px (72 pt card) off the fur (round 3).
    static let bubbleShrink = 0.86
    static let bubbleShrinkAnchor: (x: Double, y: Double) = (20, 84)

    static let badgeSize = 8.0
    static let alarmSize = 9.0

    /// The 4 key poses of the card version: lie, stand, one trot frame, pant.
    static func parts(for base: DogBasePose) -> [DogPart] {
        switch base {
        case .lie: return parts(body: .lie, head: .smile)
        case .stand: return parts(body: .stand, head: .smile)
        case .trot: return parts(body: .trot, head: .open)
        case .pant: return parts(body: .stand, head: .pant)
        }
    }

    /// One body (lie, stand or trot; pant uses the stand body) with one head variant, in drawing order.
    static func parts(body: DogBasePose, head: DogHeadVariant) -> [DogPart] {
        let bodyParts: [DogPart]
        switch body {
        case .lie: bodyParts = lieBody
        case .trot: bodyParts = trotBody
        case .stand, .pant: bodyParts = standBody
        }
        var headParts: [DogPart]
        switch head {
        case .smile: headParts = headSmile
        case .open: headParts = headOpen
        case .pant: headParts = headPant
        }
        if body == .lie {
            headParts = headParts.map { translated($0, dx: lieHeadOffset.x, dy: lieHeadOffset.y) }
        }
        return bodyParts + headParts
    }

    static func overlay(_ o: DogOverlay) -> [DogPart] {
        switch o {
        case .bubble: return bubble
        case .sweat: return sweat
        }
    }

    /// Corner badge glyph in an 8 x 8 pt box, y down. At most 2 features, all solid (docs/DESIGN.md 3.3).
    static func badge(_ item: HealthItem) -> [DogPart] {
        switch item {
        case .cpu: return badgeCpu
        case .memory: return badgeMemory
        case .thermal: return badgeThermal
        case .disk: return badgeDisk
        case .power: return badgePower
        }
    }

    /// Data mark in the 8 x 8 pt badge box, y down (DESIGN_V2.md 9.2): three dots for collecting, a clock for stale.
    /// One fill per mark (nonzero winding): the clock ring is an outer circle and a reversed inner circle, the hands
    /// one L-shaped polygon inside the hole.
    static func mark(_ m: MenuMark) -> [DogPart] {
        switch m {
        case .collecting: return markCollecting
        case .stale: return markStale
        }
    }

    /// Alarm badge knockouts in the 9 x 9 pt disc box, y down (role cutout). The disc itself is `alarmDisc`.
    static func alarmBadge(_ item: HealthItem) -> [DogPart] {
        switch item {
        case .cpu: return alarmCpu
        case .memory: return alarmMemory
        case .thermal: return alarmThermal
        case .disk: return alarmDisk
        case .power: return alarmPower
        }
    }

    // MARK: Data helpers (not drawing)

    /// Decodes absolute SVG-style path data with the commands M, L, C and Z.
    static func ops(_ path: String) -> [DogPathOp] {
        var result = [DogPathOp]()
        var numbers = [Double]()
        var command: Character = " "
        for token in path.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if let value = Double(token) {
                numbers.append(value)
                if command == "C", numbers.count == 6 {
                    result.append(.cubic(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]))
                    numbers.removeAll(keepingCapacity: true)
                } else if command == "M", numbers.count == 2 {
                    result.append(.move(numbers[0], numbers[1]))
                    numbers.removeAll(keepingCapacity: true)
                } else if command == "L", numbers.count == 2 {
                    result.append(.line(numbers[0], numbers[1]))
                    numbers.removeAll(keepingCapacity: true)
                }
            } else if let c = token.first {
                if c == "Z" { result.append(.close) }
                command = c
                numbers.removeAll(keepingCapacity: true)
            }
        }
        return result
    }

    /// The same part moved by (dx, dy). Used for the fixed lie head position.
    static func translated(_ part: DogPart, dx: Double, dy: Double) -> DogPart {
        var p = part
        p.ops = part.ops.map { op in
            switch op {
            case let .move(x, y): return .move(x + dx, y + dy)
            case let .line(x, y): return .line(x + dx, y + dy)
            case let .cubic(a, b, c, d, e, f): return .cubic(a + dx, b + dy, c + dx, d + dy, e + dx, f + dy)
            case .close: return .close
            }
        }
        p.pivot = (part.pivot.x + dx, part.pivot.y + dy)
        return p
    }

    // MARK: Art data

    // ART-BEGIN (generated from the hand-placed anchors of the authoring sheet; edit the numbers, not the code)
    /// Stand body: shadow, legs, tail, body. Legs hang from the hips, the body skirt covers their tops.
    static let standBody: [DogPart] = [
        DogPart(name: "shadow", ops: ops("M 89 83 C 89 84.93 72.88 86.5 53 86.5 C 33.12 86.5 17 84.93 17 83 C 17 81.07 33.12 79.5 53 79.5 C 72.88 79.5 89 81.07 89 83 Z"), pivot: (53, 83), role: .shadow, layer: 0),
        DogPart(name: "leg.farHind", ops: ops("M 24.25 56 C 24.25 55.37 33.75 55.37 33.75 56 C 36.67 55.93 36.97 68.43 34.05 68.5 C 36.15 68.39 36.6 77.39 34.5 77.5 C 35.55 77.95 34.05 81.45 33 81 C 33.08 81.8 29.08 82.2 29 81.4 C 28.92 82.2 24.92 81.8 25 81 C 23.95 81.45 22.45 77.95 23.5 77.5 C 21.4 77.39 21.85 68.39 23.95 68.5 C 21.03 68.43 21.33 55.93 24.25 56 Z"), pivot: (29, 60), role: .shade, layer: 10),
        DogPart(name: "leg.farFore", ops: ops("M 58.25 56 C 58.25 55.37 67.75 55.37 67.75 56 C 70.67 55.93 70.97 68.43 68.05 68.5 C 70.15 68.39 70.6 77.39 68.5 77.5 C 69.55 77.95 68.05 81.45 67 81 C 67.08 81.8 63.08 82.2 63 81.4 C 62.92 82.2 58.92 81.8 59 81 C 57.95 81.45 56.45 77.95 57.5 77.5 C 55.4 77.39 55.85 68.39 57.95 68.5 C 55.03 68.43 55.33 55.93 58.25 56 Z"), pivot: (63, 60), role: .shade, layer: 10),
        DogPart(name: "tail", ops: ops("M 23 47 C 20.33 49.5 12.83 41.5 15.5 39 C 12.2 39.92 9.7 30.92 13 30 C 9.88 28.9 12.88 20.4 16 21.5 C 13.98 19.12 20.48 13.62 22.5 16 C 21.77 13.07 29.77 11.07 30.5 14 C 31.6 11.43 38.6 14.43 37.5 17 C 39.33 15.67 43.33 21.17 41.5 22.5 C 43.3 22.65 42.8 28.65 41 28.5 C 41.35 29.43 37.35 30.93 37 30 C 36.84 30.19 33.34 27.19 33.5 27 C 33.6 27.27 29.6 28.77 29.5 28.5 C 29.79 28.55 28.79 34.05 28.5 34 C 28.82 33.87 31.32 39.87 31 40 C 31.93 41.07 23.93 48.07 23 47 Z"), pivot: (27, 44), role: .fur, layer: 20),
        DogPart(name: "leg.nearHind", ops: ops("M 31.75 57 C 31.75 56.3 42.25 56.3 42.25 57 C 45.17 56.93 45.47 69.43 42.55 69.5 C 44.65 69.39 45.1 78.39 43 78.5 C 44.05 78.95 42.55 82.45 41.5 82 C 41.58 82.9 37.08 83.3 37 82.4 C 36.92 83.3 32.42 82.9 32.5 82 C 31.45 82.45 29.95 78.95 31 78.5 C 28.9 78.39 29.35 69.39 31.45 69.5 C 28.53 69.43 28.83 56.93 31.75 57 Z"), pivot: (37, 61), role: .fur, layer: 30),
        DogPart(name: "leg.nearFore", ops: ops("M 65.75 57 C 65.75 56.3 76.25 56.3 76.25 57 C 79.17 56.93 79.47 69.43 76.55 69.5 C 78.65 69.39 79.1 78.39 77 78.5 C 78.05 78.95 76.55 82.45 75.5 82 C 75.58 82.9 71.08 83.3 71 82.4 C 70.92 83.3 66.42 82.9 66.5 82 C 65.45 82.45 63.95 78.95 65 78.5 C 62.9 78.39 63.35 69.39 65.45 69.5 C 62.53 69.43 62.83 56.93 65.75 57 Z"), pivot: (71, 61), role: .fur, layer: 30),
        DogPart(name: "body", ops: ops("M 27 41 C 25.35 38.07 33.35 33.57 35 36.5 C 34.33 33.5 43.33 31.5 44 34.5 C 43.85 31.8 52.85 31.3 53 34 C 53.3 31.3 62.3 32.3 62 35 C 62.83 32.33 70.83 34.83 70 37.5 C 71.83 35.12 78.33 40.12 76.5 42.5 C 78.83 41.33 82.33 48.33 80 49.5 C 82.5 49.67 82 57.17 79.5 57 C 81.67 58.17 78.17 64.67 76 63.5 C 77.47 65.7 71.47 69.7 70 67.5 C 70.7 71 63.2 72.5 62.5 69 C 62.75 72.75 55.25 73.25 55 69.5 C 55 73 47.5 73 47.5 69.5 C 47.25 73.25 39.75 72.75 40 69 C 39.3 72.5 31.8 71 32.5 67.5 C 30.63 70.53 24.13 66.53 26 63.5 C 23.62 65.15 19.12 58.65 21.5 57 C 19 57.33 18 49.83 20.5 49.5 C 18.67 48.83 20.67 43.33 22.5 44 C 21.5 42.5 26 39.5 27 41 Z"), pivot: (50, 68), role: .fur, layer: 40),
    ]

    /// Trot body: a little longer and lower in front than the stand body.
    static let trotBody: [DogPart] = [
        DogPart(name: "shadow", ops: ops("M 89 83 C 89 84.93 72.88 86.5 53 86.5 C 33.12 86.5 17 84.93 17 83 C 17 81.07 33.12 79.5 53 79.5 C 72.88 79.5 89 81.07 89 83 Z"), pivot: (53, 83), role: .shadow, layer: 0),
        DogPart(name: "leg.farHind", ops: ops("M 24.25 56 C 24.25 55.37 33.75 55.37 33.75 56 C 36.67 55.93 36.97 68.43 34.05 68.5 C 36.15 68.39 36.6 77.39 34.5 77.5 C 35.55 77.95 34.05 81.45 33 81 C 33.08 81.8 29.08 82.2 29 81.4 C 28.92 82.2 24.92 81.8 25 81 C 23.95 81.45 22.45 77.95 23.5 77.5 C 21.4 77.39 21.85 68.39 23.95 68.5 C 21.03 68.43 21.33 55.93 24.25 56 Z"), pivot: (29, 60), role: .shade, layer: 10),
        DogPart(name: "leg.farFore", ops: ops("M 58.25 56 C 58.25 55.37 67.75 55.37 67.75 56 C 70.67 55.93 70.97 68.43 68.05 68.5 C 70.15 68.39 70.6 77.39 68.5 77.5 C 69.55 77.95 68.05 81.45 67 81 C 67.08 81.8 63.08 82.2 63 81.4 C 62.92 82.2 58.92 81.8 59 81 C 57.95 81.45 56.45 77.95 57.5 77.5 C 55.4 77.39 55.85 68.39 57.95 68.5 C 55.03 68.43 55.33 55.93 58.25 56 Z"), pivot: (63, 60), role: .shade, layer: 10),
        DogPart(name: "tail", ops: ops("M 23 47 C 20.33 49.5 12.83 41.5 15.5 39 C 12.2 39.92 9.7 30.92 13 30 C 9.88 28.9 12.88 20.4 16 21.5 C 13.98 19.12 20.48 13.62 22.5 16 C 21.77 13.07 29.77 11.07 30.5 14 C 31.6 11.43 38.6 14.43 37.5 17 C 39.33 15.67 43.33 21.17 41.5 22.5 C 43.3 22.65 42.8 28.65 41 28.5 C 41.35 29.43 37.35 30.93 37 30 C 36.84 30.19 33.34 27.19 33.5 27 C 33.6 27.27 29.6 28.77 29.5 28.5 C 29.79 28.55 28.79 34.05 28.5 34 C 28.82 33.87 31.32 39.87 31 40 C 31.93 41.07 23.93 48.07 23 47 Z"), pivot: (27, 44), role: .fur, layer: 20),
        DogPart(name: "leg.nearHind", ops: ops("M 31.75 57 C 31.75 56.3 42.25 56.3 42.25 57 C 45.17 56.93 45.47 69.43 42.55 69.5 C 44.65 69.39 45.1 78.39 43 78.5 C 44.05 78.95 42.55 82.45 41.5 82 C 41.58 82.9 37.08 83.3 37 82.4 C 36.92 83.3 32.42 82.9 32.5 82 C 31.45 82.45 29.95 78.95 31 78.5 C 28.9 78.39 29.35 69.39 31.45 69.5 C 28.53 69.43 28.83 56.93 31.75 57 Z"), pivot: (37, 61), role: .fur, layer: 30),
        DogPart(name: "leg.nearFore", ops: ops("M 65.75 57 C 65.75 56.3 76.25 56.3 76.25 57 C 79.17 56.93 79.47 69.43 76.55 69.5 C 78.65 69.39 79.1 78.39 77 78.5 C 78.05 78.95 76.55 82.45 75.5 82 C 75.58 82.9 71.08 83.3 71 82.4 C 70.92 83.3 66.42 82.9 66.5 82 C 65.45 82.45 63.95 78.95 65 78.5 C 62.9 78.39 63.35 69.39 65.45 69.5 C 62.53 69.43 62.83 56.93 65.75 57 Z"), pivot: (71, 61), role: .fur, layer: 30),
        DogPart(name: "body", ops: ops("M 26 41.5 C 24.17 38.38 32.67 33.38 34.5 36.5 C 33.67 33.33 43.17 30.83 44 34 C 43.85 31.3 52.85 30.8 53 33.5 C 53.3 30.65 62.8 31.65 62.5 34.5 C 63.33 31.67 71.83 34.17 71 37 C 72.83 34.62 79.33 39.62 77.5 42 C 79.83 40.83 83.33 47.83 81 49 C 83.5 49.17 83 56.67 80.5 56.5 C 82.67 57.67 79.17 64.17 77 63 C 78.28 65.38 71.78 68.88 70.5 66.5 C 71.25 70.25 63.75 71.75 63 68 C 63.27 72 55.77 72.5 55.5 68.5 C 55.5 72.25 48 72.25 48 68.5 C 47.73 72.5 40.23 72 40.5 68 C 39.75 71.75 32.25 70.25 33 66.5 C 31 70 24 66 26 62.5 C 23.62 64.33 18.62 57.83 21 56 C 18.5 56.5 17 49 19.5 48.5 C 17.83 47.83 19.83 42.83 21.5 43.5 C 20.83 42 25.33 40 26 41.5 Z"), pivot: (50, 68), role: .fur, layer: 40),
    ]

    /// Lie body: loaf on the ground, front paws forward, hind leg tucked, tail curled on the hip.
    static let lieBody: [DogPart] = [
        DogPart(name: "shadow", ops: ops("M 94 83 C 94 84.77 76.99 86.2 56 86.2 C 35.01 86.2 18 84.77 18 83 C 18 81.23 35.01 79.8 56 79.8 C 76.99 79.8 94 81.23 94 83 Z"), pivot: (56, 83), role: .shadow, layer: 0),
        DogPart(name: "leg.farFore", ops: ops("M 86 73.5 C 85.8 71.85 92.3 71.05 92.5 72.7 C 92.55 70.8 100.05 71 100 72.9 C 101.03 71.4 106.03 74.85 105 76.35 C 106.01 76.93 104.21 80.08 103.2 79.5 C 103.34 80.68 99.14 81.18 99 80 C 99 82.17 86 82.17 86 80 C 85.57 80 85.57 73.5 86 73.5 Z"), pivot: (86, 77), role: .shade, layer: 10),
        DogPart(name: "tail", ops: ops("M 26 66 C 24.83 68.17 18.33 64.67 19.5 62.5 C 17.12 63.6 14.12 57.1 16.5 56 C 14.12 55.27 16.12 48.77 18.5 49.5 C 17.22 47.3 23.22 43.8 24.5 46 C 24.67 43.67 31.67 44.17 31.5 46.5 C 32.83 44.83 37.83 48.83 36.5 50.5 C 38 50.35 38.5 55.35 37 55.5 C 37.5 56.2 34 58.7 33.5 58 C 33.48 58.12 29.98 57.62 30 57.5 C 30.07 57.58 27.57 59.58 27.5 59.5 C 27.6 59.48 28.1 62.48 28 62.5 C 28.35 62.7 26.35 66.2 26 66 Z"), pivot: (26, 64), role: .fur, layer: 20),
        DogPart(name: "leg.nearFore", ops: ops("M 80 75.2 C 79.8 73.55 86.3 72.75 86.5 74.4 C 86.55 72.25 95.05 72.45 95 74.6 C 96.11 73.1 101.11 76.8 100 78.3 C 101.09 78.88 99.29 82.28 98.2 81.7 C 98.34 82.88 94.14 83.38 94 82.2 C 94 84.53 80 84.53 80 82.2 C 79.53 82.2 79.53 75.2 80 75.2 Z"), pivot: (80, 78), role: .fur, layer: 30),
        DogPart(name: "body", ops: ops("M 23 64 C 21 61.67 28 55.67 30 58 C 29 55 38 52 39 55 C 38.7 52.15 48.2 51.15 48.5 54 C 48.5 51.15 58 51.15 58 54 C 58.45 51.3 67.45 52.8 67 55.5 C 68.17 52.83 76.17 56.33 75 59 C 77 57.17 82.5 63.17 80.5 65 C 83 64.5 84.5 72 82 72.5 C 84.17 73.5 81.17 80 79 79 C 79.75 81.4 71.75 83.9 71 81.5 C 71.1 83.5 61.1 84 61 82 C 61 83.67 51 83.67 51 82 C 51 83.67 41 83.67 41 82 C 40.83 83.58 31.33 82.58 31.5 81 C 30.8 82.5 23.3 79 24 77.5 C 22.05 78.55 18.55 72.05 20.5 71 C 18.17 70.17 20.67 63.17 23 64 Z"), pivot: (50, 81), role: .fur, layer: 40),
        DogPart(name: "leg.nearHind", ops: ops("M 29 66 C 28.3 64.37 35.3 61.37 36 63 C 36.58 61.48 43.08 63.98 42.5 65.5 C 43.78 64.57 47.78 70.07 46.5 71 C 47.9 70.18 51.4 76.18 50 77 C 50.98 77.23 49.98 81.43 49 81.2 C 49.22 82.8 41.22 83.9 41 82.3 C 40.91 83.43 32.41 82.73 32.5 81.6 C 31.82 82.52 26.32 78.42 27 77.5 C 25.4 77.77 24.4 71.77 26 71.5 C 24.53 70.7 27.53 65.2 29 66 Z"), pivot: (37, 72), role: .fur, layer: 45),
    ]

    /// Head with the closed smile (stand, lie). Stand position; lie adds lieHeadOffset.
    static let headSmile: [DogPart] = [
        DogPart(name: "head", ops: ops("M 105.2 26.61 C 108.29 26.99 107.16 36.25 104.07 35.87 C 106.7 37.77 101 45.65 98.38 43.75 C 99.83 46.59 91.3 50.94 89.85 48.1 C 89.68 51.28 80.12 50.78 80.28 47.59 C 78.66 50.4 70.25 45.51 71.88 42.71 C 69.32 44.29 64.61 36.62 67.16 35.05 C 64.1 35.29 63.37 26.08 66.44 25.84 C 63.62 24.71 67.02 16.24 69.85 17.38 C 67.82 15.17 74.44 9.08 76.47 11.29 C 75.71 8.36 84.51 6.08 85.27 9.01 C 86.02 5.99 95.09 8.25 94.34 11.27 C 96.3 8.94 103.28 14.82 101.32 17.14 C 104.48 15.85 108.36 25.32 105.2 26.61 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.muzzle", ops: ops("M 94 31.5 C 93.65 29.87 100.65 28.37 101 30 C 101.58 28.48 108.08 30.98 107.5 32.5 C 108.97 31.83 111.47 37.33 110 38 C 111.65 38.75 109.15 44.25 107.5 43.5 C 108.42 45.33 103.42 47.83 102.5 46 C 102.32 48.02 96.82 47.52 97 45.5 C 95.53 46.97 91.53 42.97 93 41.5 C 91.53 41.77 90.53 36.27 92 36 C 90.95 35.53 92.95 31.03 94 31.5 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.ear", ops: ops("M 73 24 C 73.1 23.6 77.1 24.6 77 25 C 77.83 24.58 80.33 29.58 79.5 30 C 80.9 29.8 81.9 36.8 80.5 37 C 81.89 37.11 81.39 43.61 80 43.5 C 81.5 44.1 79.5 49.1 78 48.5 C 78.92 49.78 75.42 52.28 74.5 51 C 74.3 52.6 70.3 52.1 70.5 50.5 C 69.4 51.6 66.4 48.6 67.5 47.5 C 65.85 47.65 65.35 42.15 67 42 C 65.61 41.79 66.61 35.29 68 35.5 C 66.7 35.1 68.7 28.6 70 29 C 69.17 28.5 72.17 23.5 73 24 Z"), pivot: (74, 25), role: .ear, layer: 60),
        DogPart(name: "head.blush", ops: ops("M 95.1 37 C 95.1 38.22 93.49 39.2 91.5 39.2 C 89.51 39.2 87.9 38.22 87.9 37 C 87.9 35.78 89.51 34.8 91.5 34.8 C 93.49 34.8 95.1 35.78 95.1 37 Z"), pivot: (91.5, 37), role: .blush, layer: 70),
        DogPart(name: "head.eyeNear", ops: ops("M 96.9 28 C 96.9 29.77 95.6 31.2 94 31.2 C 92.4 31.2 91.1 29.77 91.1 28 C 91.1 26.23 92.4 24.8 94 24.8 C 95.6 24.8 96.9 26.23 96.9 28 Z"), pivot: (94, 28), role: .ink, layer: 70),
        DogPart(name: "head.eyeNear.hi", ops: ops("M 94.1 26.9 C 94.1 27.45 93.65 27.9 93.1 27.9 C 92.55 27.9 92.1 27.45 92.1 26.9 C 92.1 26.35 92.55 25.9 93.1 25.9 C 93.65 25.9 94.1 26.35 94.1 26.9 Z"), pivot: (94, 28), role: .highlight, layer: 70),
        DogPart(name: "head.eyeFar", ops: ops("M 105.9 27.2 C 105.9 28.8 104.83 30.1 103.5 30.1 C 102.17 30.1 101.1 28.8 101.1 27.2 C 101.1 25.6 102.17 24.3 103.5 24.3 C 104.83 24.3 105.9 25.6 105.9 27.2 Z"), pivot: (103.5, 27.2), role: .ink, layer: 70),
        DogPart(name: "head.eyeFar.hi", ops: ops("M 103.6 26.2 C 103.6 26.64 103.24 27 102.8 27 C 102.36 27 102 26.64 102 26.2 C 102 25.76 102.36 25.4 102.8 25.4 C 103.24 25.4 103.6 25.76 103.6 26.2 Z"), pivot: (103.5, 27.2), role: .highlight, layer: 70),
        DogPart(name: "head.nose", ops: ops("M 104 32.5 C 104.48 31.83 106.43 31.55 107.5 31.6 C 108.57 31.65 110.05 32.13 110.4 32.8 C 110.75 33.47 110.17 34.9 109.6 35.6 C 109.03 36.3 107.83 37 107 37 C 106.17 37 105.1 36.35 104.6 35.6 C 104.1 34.85 103.52 33.17 104 32.5 Z"), pivot: (107, 34.5), role: .ink, layer: 70),
        DogPart(name: "head.nose.hi", ops: ops("M 107.6 33 C 107.6 33.33 107.15 33.6 106.6 33.6 C 106.05 33.6 105.6 33.33 105.6 33 C 105.6 32.67 106.05 32.4 106.6 32.4 C 107.15 32.4 107.6 32.67 107.6 33 Z"), pivot: (107, 34.5), role: .highlight, layer: 70),
        DogPart(name: "head.mouth", ops: ops("M 106.45 36.94 L 106.44 37.11 L 106.43 37.32 L 106.42 37.56 L 106.41 37.81 L 106.39 38.08 L 106.37 38.34 L 106.33 38.59 L 106.28 38.81 L 106.22 38.98 L 106.16 39.11 L 106.06 39.22 L 105.93 39.35 L 105.78 39.48 L 105.6 39.61 L 105.41 39.73 L 105.21 39.83 L 105 39.92 L 104.8 40 L 104.6 40.05 L 104.44 40.09 L 104.29 40.1 L 104.11 40.08 L 103.9 40.04 L 103.67 39.97 L 103.44 39.9 L 103.21 39.81 L 102.99 39.72 L 102.79 39.64 L 102.6 39.57 L 102.46 39.53 C 101.84 39.33 101.53 40.26 102.14 40.47 L 102.26 40.51 L 102.41 40.58 L 102.61 40.66 L 102.84 40.76 L 103.1 40.85 L 103.37 40.95 L 103.66 41.03 L 103.95 41.09 L 104.26 41.12 L 104.56 41.11 L 104.84 41.06 L 105.11 40.99 L 105.38 40.9 L 105.65 40.78 L 105.92 40.65 L 106.17 40.49 L 106.42 40.33 L 106.65 40.14 L 106.86 39.93 L 107.04 39.69 L 107.2 39.41 L 107.31 39.11 L 107.39 38.8 L 107.44 38.48 L 107.47 38.17 L 107.49 37.88 L 107.51 37.61 L 107.52 37.37 L 107.53 37.19 L 107.55 37.06 C 107.63 36.35 106.52 36.23 106.45 36.94 Z"), pivot: (104.5, 40), role: .ink, layer: 70),
    ]

    /// Head with a happy open mouth (trot, sprint). Stand position; lie adds lieHeadOffset.
    static let headOpen: [DogPart] = [
        DogPart(name: "head", ops: ops("M 105.2 26.61 C 108.29 26.99 107.16 36.25 104.07 35.87 C 106.7 37.77 101 45.65 98.38 43.75 C 99.83 46.59 91.3 50.94 89.85 48.1 C 89.68 51.28 80.12 50.78 80.28 47.59 C 78.66 50.4 70.25 45.51 71.88 42.71 C 69.32 44.29 64.61 36.62 67.16 35.05 C 64.1 35.29 63.37 26.08 66.44 25.84 C 63.62 24.71 67.02 16.24 69.85 17.38 C 67.82 15.17 74.44 9.08 76.47 11.29 C 75.71 8.36 84.51 6.08 85.27 9.01 C 86.02 5.99 95.09 8.25 94.34 11.27 C 96.3 8.94 103.28 14.82 101.32 17.14 C 104.48 15.85 108.36 25.32 105.2 26.61 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.muzzle", ops: ops("M 94 31.5 C 93.65 29.87 100.65 28.37 101 30 C 101.58 28.48 108.08 30.98 107.5 32.5 C 108.97 31.83 111.47 37.33 110 38 C 111.65 38.75 109.15 44.25 107.5 43.5 C 108.42 45.33 103.42 47.83 102.5 46 C 102.32 48.02 96.82 47.52 97 45.5 C 95.53 46.97 91.53 42.97 93 41.5 C 91.53 41.77 90.53 36.27 92 36 C 90.95 35.53 92.95 31.03 94 31.5 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.ear", ops: ops("M 73 24 C 73.1 23.6 77.1 24.6 77 25 C 77.83 24.58 80.33 29.58 79.5 30 C 80.9 29.8 81.9 36.8 80.5 37 C 81.89 37.11 81.39 43.61 80 43.5 C 81.5 44.1 79.5 49.1 78 48.5 C 78.92 49.78 75.42 52.28 74.5 51 C 74.3 52.6 70.3 52.1 70.5 50.5 C 69.4 51.6 66.4 48.6 67.5 47.5 C 65.85 47.65 65.35 42.15 67 42 C 65.61 41.79 66.61 35.29 68 35.5 C 66.7 35.1 68.7 28.6 70 29 C 69.17 28.5 72.17 23.5 73 24 Z"), pivot: (74, 25), role: .ear, layer: 60),
        DogPart(name: "head.blush", ops: ops("M 95.1 37 C 95.1 38.22 93.49 39.2 91.5 39.2 C 89.51 39.2 87.9 38.22 87.9 37 C 87.9 35.78 89.51 34.8 91.5 34.8 C 93.49 34.8 95.1 35.78 95.1 37 Z"), pivot: (91.5, 37), role: .blush, layer: 70),
        DogPart(name: "head.eyeNear", ops: ops("M 96.9 28 C 96.9 29.77 95.6 31.2 94 31.2 C 92.4 31.2 91.1 29.77 91.1 28 C 91.1 26.23 92.4 24.8 94 24.8 C 95.6 24.8 96.9 26.23 96.9 28 Z"), pivot: (94, 28), role: .ink, layer: 70),
        DogPart(name: "head.eyeNear.hi", ops: ops("M 94.1 26.9 C 94.1 27.45 93.65 27.9 93.1 27.9 C 92.55 27.9 92.1 27.45 92.1 26.9 C 92.1 26.35 92.55 25.9 93.1 25.9 C 93.65 25.9 94.1 26.35 94.1 26.9 Z"), pivot: (94, 28), role: .highlight, layer: 70),
        DogPart(name: "head.eyeFar", ops: ops("M 105.9 27.2 C 105.9 28.8 104.83 30.1 103.5 30.1 C 102.17 30.1 101.1 28.8 101.1 27.2 C 101.1 25.6 102.17 24.3 103.5 24.3 C 104.83 24.3 105.9 25.6 105.9 27.2 Z"), pivot: (103.5, 27.2), role: .ink, layer: 70),
        DogPart(name: "head.eyeFar.hi", ops: ops("M 103.6 26.2 C 103.6 26.64 103.24 27 102.8 27 C 102.36 27 102 26.64 102 26.2 C 102 25.76 102.36 25.4 102.8 25.4 C 103.24 25.4 103.6 25.76 103.6 26.2 Z"), pivot: (103.5, 27.2), role: .highlight, layer: 70),
        DogPart(name: "head.nose", ops: ops("M 104 32.5 C 104.48 31.83 106.43 31.55 107.5 31.6 C 108.57 31.65 110.05 32.13 110.4 32.8 C 110.75 33.47 110.17 34.9 109.6 35.6 C 109.03 36.3 107.83 37 107 37 C 106.17 37 105.1 36.35 104.6 35.6 C 104.1 34.85 103.52 33.17 104 32.5 Z"), pivot: (107, 34.5), role: .ink, layer: 70),
        DogPart(name: "head.nose.hi", ops: ops("M 107.6 33 C 107.6 33.33 107.15 33.6 106.6 33.6 C 106.05 33.6 105.6 33.33 105.6 33 C 105.6 32.67 106.05 32.4 106.6 32.4 C 107.15 32.4 107.6 32.67 107.6 33 Z"), pivot: (107, 34.5), role: .highlight, layer: 70),
        DogPart(name: "head.mouth", ops: ops("M 101.8 39.6 C 102.15 39.23 103.53 40.57 104.5 40.4 C 105.47 40.23 107.15 38.3 107.6 38.6 C 108.05 38.9 107.7 41.27 107.2 42.2 C 106.7 43.13 105.4 44.13 104.6 44.2 C 103.8 44.27 102.87 43.37 102.4 42.6 C 101.93 41.83 101.45 39.97 101.8 39.6 Z"), pivot: (104.5, 40), role: .ink, layer: 70),
        DogPart(name: "head.tongue", ops: ops("M 103.2 42.4 C 103.4 41.97 104.63 41.6 105.2 41.6 C 105.77 41.6 106.53 42 106.6 42.4 C 106.67 42.8 106.03 43.7 105.6 44 C 105.17 44.3 104.4 44.47 104 44.2 C 103.6 43.93 103 42.83 103.2 42.4 Z"), pivot: (104.5, 42.6), role: .tongue, layer: 70),
    ]

    /// Head with the open mouth and the tongue out (pant). Stand position; lie adds lieHeadOffset.
    static let headPant: [DogPart] = [
        DogPart(name: "head", ops: ops("M 105.2 26.61 C 108.29 26.99 107.16 36.25 104.07 35.87 C 106.7 37.77 101 45.65 98.38 43.75 C 99.83 46.59 91.3 50.94 89.85 48.1 C 89.68 51.28 80.12 50.78 80.28 47.59 C 78.66 50.4 70.25 45.51 71.88 42.71 C 69.32 44.29 64.61 36.62 67.16 35.05 C 64.1 35.29 63.37 26.08 66.44 25.84 C 63.62 24.71 67.02 16.24 69.85 17.38 C 67.82 15.17 74.44 9.08 76.47 11.29 C 75.71 8.36 84.51 6.08 85.27 9.01 C 86.02 5.99 95.09 8.25 94.34 11.27 C 96.3 8.94 103.28 14.82 101.32 17.14 C 104.48 15.85 108.36 25.32 105.2 26.61 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.muzzle", ops: ops("M 94 31.5 C 93.65 29.87 100.65 28.37 101 30 C 101.58 28.48 108.08 30.98 107.5 32.5 C 108.97 31.83 111.47 37.33 110 38 C 111.65 38.75 109.15 44.25 107.5 43.5 C 108.42 45.33 103.42 47.83 102.5 46 C 102.32 48.02 96.82 47.52 97 45.5 C 95.53 46.97 91.53 42.97 93 41.5 C 91.53 41.77 90.53 36.27 92 36 C 90.95 35.53 92.95 31.03 94 31.5 Z"), pivot: (80, 45), role: .fur, layer: 50),
        DogPart(name: "head.ear", ops: ops("M 73 24 C 73.1 23.6 77.1 24.6 77 25 C 77.83 24.58 80.33 29.58 79.5 30 C 80.9 29.8 81.9 36.8 80.5 37 C 81.89 37.11 81.39 43.61 80 43.5 C 81.5 44.1 79.5 49.1 78 48.5 C 78.92 49.78 75.42 52.28 74.5 51 C 74.3 52.6 70.3 52.1 70.5 50.5 C 69.4 51.6 66.4 48.6 67.5 47.5 C 65.85 47.65 65.35 42.15 67 42 C 65.61 41.79 66.61 35.29 68 35.5 C 66.7 35.1 68.7 28.6 70 29 C 69.17 28.5 72.17 23.5 73 24 Z"), pivot: (74, 25), role: .ear, layer: 60),
        DogPart(name: "head.blush", ops: ops("M 95.1 37 C 95.1 38.22 93.49 39.2 91.5 39.2 C 89.51 39.2 87.9 38.22 87.9 37 C 87.9 35.78 89.51 34.8 91.5 34.8 C 93.49 34.8 95.1 35.78 95.1 37 Z"), pivot: (91.5, 37), role: .blush, layer: 70),
        DogPart(name: "head.eyeNear", ops: ops("M 96.9 28 C 96.9 29.77 95.6 31.2 94 31.2 C 92.4 31.2 91.1 29.77 91.1 28 C 91.1 26.23 92.4 24.8 94 24.8 C 95.6 24.8 96.9 26.23 96.9 28 Z"), pivot: (94, 28), role: .ink, layer: 70),
        DogPart(name: "head.eyeNear.hi", ops: ops("M 94.1 26.9 C 94.1 27.45 93.65 27.9 93.1 27.9 C 92.55 27.9 92.1 27.45 92.1 26.9 C 92.1 26.35 92.55 25.9 93.1 25.9 C 93.65 25.9 94.1 26.35 94.1 26.9 Z"), pivot: (94, 28), role: .highlight, layer: 70),
        DogPart(name: "head.eyeFar", ops: ops("M 105.9 27.2 C 105.9 28.8 104.83 30.1 103.5 30.1 C 102.17 30.1 101.1 28.8 101.1 27.2 C 101.1 25.6 102.17 24.3 103.5 24.3 C 104.83 24.3 105.9 25.6 105.9 27.2 Z"), pivot: (103.5, 27.2), role: .ink, layer: 70),
        DogPart(name: "head.eyeFar.hi", ops: ops("M 103.6 26.2 C 103.6 26.64 103.24 27 102.8 27 C 102.36 27 102 26.64 102 26.2 C 102 25.76 102.36 25.4 102.8 25.4 C 103.24 25.4 103.6 25.76 103.6 26.2 Z"), pivot: (103.5, 27.2), role: .highlight, layer: 70),
        DogPart(name: "head.nose", ops: ops("M 104 32.5 C 104.48 31.83 106.43 31.55 107.5 31.6 C 108.57 31.65 110.05 32.13 110.4 32.8 C 110.75 33.47 110.17 34.9 109.6 35.6 C 109.03 36.3 107.83 37 107 37 C 106.17 37 105.1 36.35 104.6 35.6 C 104.1 34.85 103.52 33.17 104 32.5 Z"), pivot: (107, 34.5), role: .ink, layer: 70),
        DogPart(name: "head.nose.hi", ops: ops("M 107.6 33 C 107.6 33.33 107.15 33.6 106.6 33.6 C 106.05 33.6 105.6 33.33 105.6 33 C 105.6 32.67 106.05 32.4 106.6 32.4 C 107.15 32.4 107.6 32.67 107.6 33 Z"), pivot: (107, 34.5), role: .highlight, layer: 70),
        DogPart(name: "head.mouth", ops: ops("M 101 39.4 C 101.4 38.83 103.17 40.77 104.4 40.6 C 105.63 40.43 107.7 38.07 108.4 38.4 C 109.1 38.73 109.1 41.4 108.6 42.6 C 108.1 43.8 106.5 45.37 105.4 45.6 C 104.3 45.83 102.73 45.03 102 44 C 101.27 42.97 100.6 39.97 101 39.4 Z"), pivot: (104.5, 40), role: .ink, layer: 70),
        DogPart(name: "head.tongue", ops: ops("M 102.4 42.6 C 103.17 41.87 105.53 41.63 106.4 42.2 C 107.27 42.77 107.47 44.6 107.6 46 C 107.73 47.4 107.67 49.5 107.2 50.6 C 106.73 51.7 105.57 52.53 104.8 52.6 C 104.03 52.67 103.1 52 102.6 51 C 102.1 50 101.83 48 101.8 46.6 C 101.77 45.2 101.63 43.33 102.4 42.6 Z"), pivot: (104.5, 42.6), role: .tongue, layer: 80),
        DogPart(name: "head.tongue.line", ops: ops("M 104.45 43.61 L 104.46 43.84 L 104.48 44.16 L 104.49 44.53 L 104.51 44.94 L 104.53 45.38 L 104.55 45.84 L 104.57 46.28 L 104.58 46.7 L 104.59 47.08 L 104.6 47.4 L 104.6 47.68 L 104.6 47.94 L 104.6 48.18 L 104.59 48.41 L 104.58 48.62 L 104.57 48.81 L 104.56 48.98 L 104.56 49.14 L 104.55 49.27 L 104.55 49.38 C 104.54 49.71 105.01 49.74 105.05 49.42 L 105.06 49.31 L 105.08 49.18 L 105.09 49.02 L 105.11 48.85 L 105.13 48.66 L 105.15 48.44 L 105.17 48.21 L 105.18 47.96 L 105.19 47.69 L 105.2 47.4 L 105.2 47.07 L 105.2 46.69 L 105.2 46.26 L 105.19 45.82 L 105.18 45.37 L 105.17 44.92 L 105.16 44.51 L 105.16 44.13 L 105.15 43.82 L 105.15 43.59 C 105.15 43.13 104.43 43.16 104.45 43.61 Z"), pivot: (104.5, 42.6), role: .tongueLine, layer: 80),
    ]

    /// Thought bubble (any problem), 24.4 u in the top right corner, a tail dot to its left. The glyph goes in bubbleGlyphFrame.
    static let bubble: [DogPart] = [
        DogPart(name: "bubble.tail1", ops: ops("M 93.2 13.3 C 93.2 14.13 92.53 14.8 91.7 14.8 C 90.87 14.8 90.2 14.13 90.2 13.3 C 90.2 12.47 90.87 11.8 91.7 11.8 C 92.53 11.8 93.2 12.47 93.2 13.3 Z"), pivot: (106.7, 13.3), role: .bubble, layer: 120),
        DogPart(name: "bubble.main", ops: ops("M 118.9 13.3 C 118.9 16.18 117.36 19.89 115.33 21.93 C 113.29 23.96 109.58 25.5 106.7 25.5 C 103.82 25.5 100.11 23.96 98.07 21.93 C 96.04 19.89 94.5 16.18 94.5 13.3 C 94.5 10.42 96.04 6.71 98.07 4.67 C 100.11 2.64 103.82 1.1 106.7 1.1 C 109.58 1.1 113.29 2.64 115.33 4.67 C 117.36 6.71 118.9 10.42 118.9 13.3 Z"), pivot: (106.7, 13.3), role: .bubble, layer: 120),
    ]

    /// Two short sweat drops beside the back of the head (pant).
    static let sweat: [DogPart] = [
        DogPart(name: "fx.sweat1", ops: ops("M 62.5 16.13 C 63.16 17.46 64.4 18.79 64.4 20.5 C 64.4 21.55 63.55 22.4 62.5 22.4 C 61.45 22.4 60.6 21.55 60.6 20.5 C 60.6 18.79 61.84 17.46 62.5 16.13 Z"), pivot: (62.5, 20.5), role: .effect, layer: 130),
        DogPart(name: "fx.sweat2", ops: ops("M 58 24.78 C 58.49 25.76 59.4 26.74 59.4 28 C 59.4 28.77 58.77 29.4 58 29.4 C 57.23 29.4 56.6 28.77 56.6 28 C 56.6 26.74 57.51 25.76 58 24.78 Z"), pivot: (58, 28), role: .effect, layer: 130),
    ]

    /// Badge glyph: cpu. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeCpu: [DogPart] = [
        DogPart(name: "cpu.core", ops: ops("M 2.6 2 L 5.4 2 C 5.73 2 6 2.27 6 2.6 L 6 5.4 C 6 5.73 5.73 6 5.4 6 L 2.6 6 C 2.27 6 2 5.73 2 5.4 L 2 2.6 C 2 2.27 2.27 2 2.6 2 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "cpu.ring", ops: ops("M 5 0 L 6.0 0 C 7.1 0 8 0.9 8 2.0 L 8 6.0 C 8 7.1 7.1 8 6.0 8 L 2.0 8 C 0.9 8 0 7.1 0 6.0 L 0 2.0 C 0 0.9 0.9 0 2.0 0 L 3 0 L 3 1 L 2 1 C 1.45 1 1 1.45 1 2 L 1 6 C 1 6.55 1.45 7 2 7 L 6 7 C 6.55 7 7 6.55 7 6 L 7 2 C 7 1.45 6.55 1 6 1 L 5 1 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: memory. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeMemory: [DogPart] = [
        DogPart(name: "memory.stick", ops: ops("M 0.8 1 L 7.2 1 C 7.64 1 8 1.36 8 1.8 L 8 4.2 C 8 4.64 7.64 5 7.2 5 L 0.8 5 C 0.36 5 0 4.64 0 4.2 L 0 1.8 C 0 1.36 0.36 1 0.8 1 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "memory.pins", ops: ops("M 0 5 L 1 5 L 1 7 L 0 7 Z M 2 5 L 3 5 L 3 7 L 2 7 Z M 5 5 L 6 5 L 6 7 L 5 7 Z M 7 5 L 8 5 L 8 7 L 7 7 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: thermal. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeThermal: [DogPart] = [
        DogPart(name: "thermal.stem", ops: ops("M 4 0 L 4 0 C 4.55 0 5 0.45 5 1 L 5 4 C 5 4.55 4.55 5 4 5 L 4 5 C 3.45 5 3 4.55 3 4 L 3 1 C 3 0.45 3.45 0 4 0 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "thermal.bulb", ops: ops("M 6.5 5.5 C 6.5 6.88 5.38 8 4 8 C 2.62 8 1.5 6.88 1.5 5.5 C 1.5 4.12 2.62 3 4 3 C 5.38 3 6.5 4.12 6.5 5.5 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: disk. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeDisk: [DogPart] = [
        DogPart(name: "disk.lid", ops: ops("M 1 2 C 1 0.8 2.34 0 4 0 C 5.66 0 7 0.8 7 2 L 1 2 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "disk.body", ops: ops("M 1 3 L 7 3 L 7 6.8 C 7 7.6 5.66 8 4 8 C 2.34 8 1 7.6 1 6.8 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: power. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgePower: [DogPart] = [
        DogPart(name: "power.bolt", ops: ops("M 4 0 L 7.5 0 L 6 3 L 8 3 L 4 8 L 2 8 L 3 5 L 0.5 5 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Alarm badge knockouts: cpu. Cut out of the 9 x 9 pt disc, y down, on the 1x pixel grid.
    static let alarmCpu: [DogPart] = [
        DogPart(name: "cpu.chip", ops: ops("M 3 3 L 6 3 L 6 6 L 3 6 Z M 3 1 L 4 1 L 4 2 L 3 2 Z M 5 1 L 6 1 L 6 2 L 5 2 Z M 3 7 L 4 7 L 4 8 L 3 8 Z M 5 7 L 6 7 L 6 8 L 5 8 Z M 1 3 L 2 3 L 2 4 L 1 4 Z M 1 5 L 2 5 L 2 6 L 1 6 Z M 7 3 L 8 3 L 8 4 L 7 4 Z M 7 5 L 8 5 L 8 6 L 7 6 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
    ]

    /// Alarm badge knockouts: memory. Cut out of the 9 x 9 pt disc, y down, on the 1x pixel grid.
    static let alarmMemory: [DogPart] = [
        DogPart(name: "memory.stick", ops: ops("M 1 2 L 8 2 L 8 5 L 1 5 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
        DogPart(name: "memory.pins", ops: ops("M 2 5 L 3 5 L 3 7 L 2 7 Z M 4 5 L 5 5 L 5 7 L 4 7 Z M 6 5 L 7 5 L 7 7 L 6 7 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
    ]

    /// Alarm badge knockouts: thermal. Cut out of the 9 x 9 pt disc, y down, on the 1x pixel grid.
    static let alarmThermal: [DogPart] = [
        DogPart(name: "thermal.stem", ops: ops("M 3 1 L 5 1 L 5 5 L 3 5 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
        DogPart(name: "thermal.bulb", ops: ops("M 2 5 L 6 5 L 6 6 L 2 6 Z M 2 6 L 6 6 L 6 7 L 2 7 Z M 2 7 L 6 7 L 6 8 L 2 8 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
    ]

    /// Alarm badge knockouts: disk. Cut out of the 9 x 9 pt disc, y down, on the 1x pixel grid.
    static let alarmDisk: [DogPart] = [
        DogPart(name: "disk.lid", ops: ops("M 3 1 L 6 1 L 6 2 L 3 2 Z M 2 2 L 7 2 L 7 3 L 2 3 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
        DogPart(name: "disk.body", ops: ops("M 1 4 L 8 4 L 8 7 L 1 7 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
    ]

    /// Alarm badge knockouts: power. Cut out of the 9 x 9 pt disc, y down, on the 1x pixel grid.
    static let alarmPower: [DogPart] = [
        DogPart(name: "power.bolt", ops: ops("M 5 0 L 7 0 L 7 1 L 5 1 Z M 4 1 L 7 1 L 7 2 L 4 2 Z M 3 2 L 6 2 L 6 3 L 3 3 Z M 2 3 L 7 3 L 7 4 L 2 4 Z M 4 4 L 6 4 L 6 5 L 4 5 Z M 3 5 L 5 5 L 5 6 L 3 6 Z M 3 6 L 5 6 L 5 7 L 3 7 Z M 2 7 L 4 7 L 4 8 L 2 8 Z"), pivot: (4.5, 4.5), role: .cutout, layer: 0),
    ]

    /// Data mark: collecting. Three 2 x 2 pt dots with 1 pt gaps on the bottom line of the box (like a typed ellipsis),
    /// whole pixels at 1x. 8 x 8 pt box, y down.
    static let markCollecting: [DogPart] = [
        DogPart(name: "collecting.dots", ops: ops("M 0.6 6 L 1.4 6 C 1.73 6 2 6.27 2 6.6 L 2 7.4 C 2 7.73 1.73 8 1.4 8 L 0.6 8 C 0.27 8 0 7.73 0 7.4 L 0 6.6 C 0 6.27 0.27 6 0.6 6 Z M 3.6 6 L 4.4 6 C 4.73 6 5 6.27 5 6.6 L 5 7.4 C 5 7.73 4.73 8 4.4 8 L 3.6 8 C 3.27 8 3 7.73 3 7.4 L 3 6.6 C 3 6.27 3.27 6 3.6 6 Z M 6.6 6 L 7.4 6 C 7.73 6 8 6.27 8 6.6 L 8 7.4 C 8 7.73 7.73 8 7.4 8 L 6.6 8 C 6.27 8 6 7.73 6 7.4 L 6 6.6 C 6 6.27 6.27 6 6.6 6 Z"), pivot: (4, 7), role: .ink, layer: 0),
    ]

    /// Data mark: stale. A 7 pt clock face (x 1 to 8, y 1 to 8, ring 1.3 pt) with the hands at ten past twelve on the
    /// pixel column x 4 to 5, so the hands are crisp at 1x. 8 x 8 pt box, y down.
    static let markStale: [DogPart] = [
        DogPart(name: "stale.ring", ops: ops("M 8 4.5 C 8 6.43 6.43 8 4.5 8 C 2.57 8 1 6.43 1 4.5 C 1 2.57 2.57 1 4.5 1 C 6.43 1 8 2.57 8 4.5 Z M 6.7 4.5 C 6.7 3.29 5.71 2.3 4.5 2.3 C 3.29 2.3 2.3 3.29 2.3 4.5 C 2.3 5.71 3.29 6.7 4.5 6.7 C 5.71 6.7 6.7 5.71 6.7 4.5 Z"), pivot: (4.5, 4.5), role: .ink, layer: 0),
        DogPart(name: "stale.hands", ops: ops("M 4 3 L 5 3 L 5 4 L 6 4 L 6 5 L 4 5 Z"), pivot: (4.5, 4.5), role: .ink, layer: 0),
    ]

    /// Alarm badge disc: 9 x 9 pt, y down. The glyph is knocked out of it.
    static let alarmDisc: [DogPart] = [
        DogPart(name: "alarm.disc", ops: ops("M 9 4.5 C 9 6.99 6.99 9 4.5 9 C 2.01 9 0 6.99 0 4.5 C 0 2.01 2.01 0 4.5 0 C 6.99 0 9 2.01 9 4.5 Z"), pivot: (4.5, 4.5), role: .ink, layer: 0),
    ]
    // ART-END
}
