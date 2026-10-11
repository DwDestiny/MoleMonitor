// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (hand-written art data, docs/DESIGN.md 4.2, 8.1).
// Output: Bezier path data for the dog parts, the menu bar head and the corner badge glyphs.
// Pos: Art assets: numbers, names and enums. No drawing code. Foundation only. Owner I2. DogRig never changes the shapes.
//
// Coordinates: the card dog uses a 120 x 90 u box, origin top left, y down, the dog faces right, ground y = 82.
// The menu bar head uses a 24 x 18 pt box, y down: the head fills x 0 to 15, the badge sits at x 16 to 24, y 9 to 17.
// A badge uses an 8 x 8 pt box, y down. The head and the badge never overlap, so no cutout gap is needed.
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
/// Added after the skeleton: tongueLine, highlight, shadow, bundle, bundleDot, strap, bubble, effect, cutout (DESIGN.md 8.1).
enum DogPartRole: String, CaseIterable {
    case fur, shade, ear, ink, tongue, blush
    case tongueLine, highlight, shadow, bundle, bundleDot, strap, bubble, effect, cutout
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
enum DogOverlay: String, CaseIterable { case bundle, bubble, heat }

enum DogArt {
    static let designSize: (w: Double, h: Double) = (120, 90)
    static let groundY = 82.0
    /// The lie pose moves the whole head down by this offset (u). The head art itself is the same.
    static let lieHeadOffset: (x: Double, y: Double) = (3, 16)
    /// Where the badge glyph sits in the thought bubble (u): a 15 x 15 box centered in the 22 u bubble,
    /// about 40 % of the head diameter. The glyph is the same art as the menu bar badge (DogArt.badge).
    static let bubbleGlyphFrame: (x: Double, y: Double, size: Double) = (101, 4, 15)

    static let menuSize: (w: Double, h: Double) = (24, 18)
    /// Right edge of the menu head (pt). The head stays inside x 0 to 15 with and without a badge.
    static let menuHeadWidth = 15.0
    /// Top-left corner of the 8 x 8 pt badge box in the menu head box (y down): x 16 to 24, y 9 to 17.
    static let menuBadgeOrigin: (x: Double, y: Double) = (16, 9)
    static let badgeSize = 8.0

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
        case .bundle: return bundle
        case .bubble: return bubble
        case .heat: return heat
        }
    }

    /// The menu bar head: relaxed, raised ears, tongue out. Design box 24 x 18 pt, y down.
    /// `hollow` uses the relaxed art; the renderer draws it as a 1.5 pt inner ring of the silhouette.
    static func menuHead(_ posture: MenuPosture) -> [DogPart] {
        switch posture {
        case .relaxed, .hollow: return menuRelaxed
        case .raised: return menuRaised
        case .pant: return menuPant
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

    /// Furoshiki bundle on the back (memory red): round pack, dots, two folds, a knot with two pointed corners.
    static let bundle: [DogPart] = [
        DogPart(name: "bundle.sack", ops: ops("M 37 39 C 35.92 37.62 36.67 33.58 37.5 31.5 C 38.33 29.42 40.17 27.72 42 26.5 C 43.83 25.28 46.25 24.58 48.5 24.2 C 50.75 23.82 53.33 23.82 55.5 24.2 C 57.67 24.58 59.83 25.23 61.5 26.5 C 63.17 27.77 64.75 29.78 65.5 31.8 C 66.25 33.82 67.08 37.27 66 38.6 C 64.92 39.93 61.42 39.67 59 39.8 C 56.58 39.93 54 39.4 51.5 39.4 C 49 39.4 46.42 39.87 44 39.8 C 41.58 39.73 38.08 40.38 37 39 Z"), pivot: (51, 38), role: .bundle, layer: 100),
        DogPart(name: "bundle.dot0", ops: ops("M 45.35 34.5 C 45.35 35.14 44.84 35.65 44.2 35.65 C 43.56 35.65 43.05 35.14 43.05 34.5 C 43.05 33.86 43.56 33.35 44.2 33.35 C 44.84 33.35 45.35 33.86 45.35 34.5 Z"), pivot: (51, 38), role: .bundleDot, layer: 105),
        DogPart(name: "bundle.dot1", ops: ops("M 52.65 33.4 C 52.65 34.04 52.14 34.55 51.5 34.55 C 50.86 34.55 50.35 34.04 50.35 33.4 C 50.35 32.76 50.86 32.25 51.5 32.25 C 52.14 32.25 52.65 32.76 52.65 33.4 Z"), pivot: (51, 38), role: .bundleDot, layer: 105),
        DogPart(name: "bundle.dot2", ops: ops("M 59.95 34.5 C 59.95 35.14 59.44 35.65 58.8 35.65 C 58.16 35.65 57.65 35.14 57.65 34.5 C 57.65 33.86 58.16 33.35 58.8 33.35 C 59.44 33.35 59.95 33.86 59.95 34.5 Z"), pivot: (51, 38), role: .bundleDot, layer: 105),
        DogPart(name: "bundle.dot3", ops: ops("M 49 29.4 C 49 29.95 48.55 30.4 48 30.4 C 47.45 30.4 47 29.95 47 29.4 C 47 28.85 47.45 28.4 48 28.4 C 48.55 28.4 49 28.85 49 29.4 Z"), pivot: (51, 38), role: .bundleDot, layer: 105),
        DogPart(name: "bundle.dot4", ops: ops("M 56 29.4 C 56 29.95 55.55 30.4 55 30.4 C 54.45 30.4 54 29.95 54 29.4 C 54 28.85 54.45 28.4 55 28.4 C 55.55 28.4 56 28.85 56 29.4 Z"), pivot: (51, 38), role: .bundleDot, layer: 105),
        DogPart(name: "bundle.foldL", ops: ops("M 49.09 26.07 L 48.83 26.33 L 48.48 26.65 L 48.07 27.03 L 47.6 27.46 L 47.09 27.94 L 46.57 28.45 L 46.04 28.99 L 45.52 29.55 L 45.04 30.12 L 44.6 30.71 L 44.18 31.33 L 43.77 32.03 L 43.35 32.78 L 42.95 33.55 L 42.57 34.33 L 42.21 35.08 L 41.87 35.78 L 41.58 36.4 L 41.34 36.92 L 41.14 37.32 C 40.92 37.78 41.61 38.14 41.86 37.68 L 42.07 37.29 L 42.34 36.77 L 42.65 36.15 L 42.99 35.47 L 43.37 34.73 L 43.77 33.98 L 44.18 33.23 L 44.59 32.52 L 45.01 31.86 L 45.4 31.29 L 45.82 30.77 L 46.29 30.25 L 46.8 29.73 L 47.32 29.23 L 47.84 28.75 L 48.35 28.3 L 48.83 27.88 L 49.26 27.51 L 49.63 27.19 L 49.91 26.93 C 50.49 26.41 49.64 25.51 49.09 26.07 Z"), pivot: (51, 38), role: .strap, layer: 106),
        DogPart(name: "bundle.foldR", ops: ops("M 53.09 26.93 L 53.37 27.19 L 53.74 27.51 L 54.17 27.88 L 54.65 28.3 L 55.16 28.75 L 55.68 29.23 L 56.2 29.73 L 56.71 30.25 L 57.18 30.77 L 57.6 31.29 L 57.99 31.86 L 58.41 32.52 L 58.82 33.23 L 59.23 33.98 L 59.63 34.73 L 60.01 35.47 L 60.35 36.15 L 60.66 36.77 L 60.93 37.29 L 61.14 37.68 C 61.39 38.14 62.08 37.78 61.86 37.32 L 61.66 36.92 L 61.42 36.4 L 61.13 35.78 L 60.79 35.08 L 60.43 34.33 L 60.05 33.55 L 59.65 32.78 L 59.23 32.03 L 58.82 31.33 L 58.4 30.71 L 57.96 30.12 L 57.48 29.55 L 56.96 28.99 L 56.43 28.45 L 55.91 27.94 L 55.4 27.46 L 54.93 27.03 L 54.52 26.65 L 54.17 26.33 L 53.91 26.07 C 53.36 25.51 52.51 26.41 53.09 26.93 Z"), pivot: (51, 38), role: .strap, layer: 106),
        DogPart(name: "bundle.cornerL", ops: ops("M 50.2 24.6 C 50.06 24.04 47 20.92 46.2 20.2 C 45.4 19.48 42.4 17.24 42.2 17.4 C 42 17.56 43.66 20.96 44.2 21.8 C 44.74 22.64 47 25.52 47.6 25.8 C 48.2 26.08 50.34 25.16 50.2 24.6 Z"), pivot: (51, 38), role: .bundle, layer: 110),
        DogPart(name: "bundle.cornerR", ops: ops("M 52.8 24.6 C 52.94 24.04 56 20.92 56.8 20.2 C 57.6 19.48 60.6 17.24 60.8 17.4 C 61 17.56 59.34 20.96 58.8 21.8 C 58.26 22.64 56 25.52 55.4 25.8 C 54.8 26.08 52.66 25.16 52.8 24.6 Z"), pivot: (51, 38), role: .bundle, layer: 110),
        DogPart(name: "bundle.knot", ops: ops("M 54.7 24.6 C 54.7 26.04 53.27 27.2 51.5 27.2 C 49.73 27.2 48.3 26.04 48.3 24.6 C 48.3 23.16 49.73 22 51.5 22 C 53.27 22 54.7 23.16 54.7 24.6 Z"), pivot: (51, 38), role: .strap, layer: 115),
    ]

    /// Thought bubble (any problem). The glyph goes in bubbleGlyphFrame.
    static let bubble: [DogPart] = [
        DogPart(name: "bubble.tail1", ops: ops("M 97.8 21.8 C 97.8 22.57 97.17 23.2 96.4 23.2 C 95.63 23.2 95 22.57 95 21.8 C 95 21.03 95.63 20.4 96.4 20.4 C 97.17 20.4 97.8 21.03 97.8 21.8 Z"), pivot: (108.5, 11.5), role: .bubble, layer: 120),
        DogPart(name: "bubble.main", ops: ops("M 97.5 11.5 C 97.5 8.9 98.87 5.52 100.7 3.7 C 102.53 1.88 105.9 0.6 108.5 0.6 C 111.1 0.6 114.48 1.88 116.3 3.7 C 118.12 5.52 119.4 8.9 119.4 11.5 C 119.4 14.1 118.12 17.48 116.3 19.3 C 114.48 21.12 111.1 22.4 108.5 22.4 C 105.9 22.4 102.53 21.12 100.7 19.3 C 98.87 17.48 97.5 14.1 97.5 11.5 Z"), pivot: (108.5, 11.5), role: .bubble, layer: 120),
    ]

    /// Two heat waves above the head (pant).
    static let heat: [DogPart] = [
        DogPart(name: "fx.heat1", ops: ops("M 84.48 9.94 L 84.59 9.8 L 84.77 9.62 L 85.01 9.39 L 85.28 9.13 L 85.57 8.84 L 85.85 8.52 L 86.11 8.19 L 86.34 7.83 L 86.51 7.44 L 86.58 6.99 L 86.48 6.53 L 86.25 6.16 L 85.97 5.85 L 85.66 5.58 L 85.35 5.33 L 85.06 5.09 L 84.81 4.87 L 84.63 4.68 L 84.54 4.55 L 84.52 4.49 L 84.53 4.4 L 84.61 4.21 L 84.77 3.97 L 84.98 3.7 L 85.22 3.43 L 85.48 3.16 L 85.74 2.91 L 85.98 2.68 L 86.19 2.47 L 86.33 2.3 C 86.71 1.86 86.08 1.28 85.67 1.7 L 85.54 1.83 L 85.35 2 L 85.1 2.22 L 84.82 2.48 L 84.53 2.76 L 84.24 3.06 L 83.97 3.37 L 83.74 3.71 L 83.56 4.08 L 83.48 4.51 L 83.57 4.95 L 83.78 5.32 L 84.05 5.63 L 84.34 5.91 L 84.65 6.17 L 84.93 6.42 L 85.17 6.65 L 85.34 6.84 L 85.41 6.97 L 85.42 7.01 L 85.39 7.08 L 85.31 7.25 L 85.15 7.47 L 84.93 7.72 L 84.68 7.98 L 84.41 8.23 L 84.15 8.47 L 83.9 8.7 L 83.68 8.9 L 83.52 9.06 C 82.93 9.66 83.93 10.58 84.48 9.94 Z"), pivot: (85, 8), role: .effect, layer: 130),
        DogPart(name: "fx.heat2", ops: ops("M 92.48 10.94 L 92.59 10.8 L 92.77 10.62 L 93.01 10.39 L 93.28 10.13 L 93.57 9.84 L 93.85 9.52 L 94.11 9.19 L 94.34 8.83 L 94.51 8.44 L 94.58 7.99 L 94.48 7.53 L 94.25 7.16 L 93.97 6.85 L 93.66 6.58 L 93.35 6.33 L 93.06 6.09 L 92.81 5.87 L 92.63 5.68 L 92.54 5.55 L 92.52 5.49 L 92.53 5.4 L 92.61 5.21 L 92.77 4.97 L 92.98 4.7 L 93.22 4.43 L 93.48 4.16 L 93.74 3.91 L 93.98 3.68 L 94.19 3.47 L 94.33 3.3 C 94.71 2.86 94.08 2.28 93.67 2.7 L 93.54 2.83 L 93.35 3 L 93.1 3.22 L 92.82 3.48 L 92.53 3.76 L 92.24 4.06 L 91.97 4.37 L 91.74 4.71 L 91.56 5.08 L 91.48 5.51 L 91.57 5.95 L 91.78 6.32 L 92.05 6.63 L 92.34 6.91 L 92.65 7.17 L 92.93 7.42 L 93.17 7.65 L 93.34 7.84 L 93.41 7.97 L 93.42 8.01 L 93.39 8.08 L 93.31 8.25 L 93.15 8.47 L 92.93 8.72 L 92.68 8.98 L 92.41 9.23 L 92.15 9.47 L 91.9 9.7 L 91.68 9.9 L 91.52 10.06 C 90.93 10.66 91.93 11.58 92.48 10.94 Z"), pivot: (93, 9), role: .effect, layer: 130),
    ]

    /// Menu bar head, relaxed: one union silhouette in x 0..15, face cutouts. 24 x 18 pt box, y down.
    static let menuRelaxed: [DogPart] = [
        DogPart(name: "head", ops: ops("M 7.5 2.1 C 7.77 1.09 10.52 1.83 10.25 2.84 C 10.93 2.13 12.84 3.98 12.16 4.69 C 12.41 4.66 12.54 5.87 12.3 5.9 C 12.48 5.58 14.38 6.68 14.2 7 C 14.92 6.94 15.22 10.54 14.5 10.6 C 15.35 10.81 14.55 14.01 13.7 13.8 C 13.76 14.28 12.16 14.48 12.1 14 C 12.15 13.85 11.05 13.45 11 13.6 C 11.18 13.92 9.58 14.82 9.4 14.5 C 9.44 14.88 7.54 15.08 7.5 14.7 C 7.46 15.08 5.56 14.88 5.6 14.5 C 5.42 14.82 3.82 13.92 4 13.6 C 3.95 13.45 2.85 13.85 2.9 14 C 2.84 14.48 1.24 14.28 1.3 13.8 C 0.45 14.01 -0.35 10.81 0.5 10.6 C -0.22 10.54 0.08 6.94 0.8 7 C 0.62 6.68 2.52 5.58 2.7 5.9 C 2.46 5.87 2.59 4.66 2.84 4.69 C 2.16 3.98 4.07 2.13 4.75 2.84 C 4.48 1.83 7.23 1.09 7.5 2.1 Z"), pivot: (7.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 6.45 8.5 C 6.45 9.02 6.02 9.45 5.5 9.45 C 4.98 9.45 4.55 9.02 4.55 8.5 C 4.55 7.98 4.98 7.55 5.5 7.55 C 6.02 7.55 6.45 7.98 6.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 10.45 8.5 C 10.45 9.02 10.02 9.45 9.5 9.45 C 8.98 9.45 8.55 9.02 8.55 8.5 C 8.55 7.98 8.98 7.55 9.5 7.55 C 10.02 7.55 10.45 7.98 10.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 8.65 11.4 C 8.65 11.9 8.14 12.3 7.5 12.3 C 6.86 12.3 6.35 11.9 6.35 11.4 C 6.35 10.9 6.86 10.5 7.5 10.5 C 8.14 10.5 8.65 10.9 8.65 11.4 Z"), pivot: (0, 0), role: .cutout, layer: 0),
    ]

    /// Menu bar head, raised: one union silhouette in x 0..15, face cutouts. 24 x 18 pt box, y down.
    static let menuRaised: [DogPart] = [
        DogPart(name: "head", ops: ops("M 7.5 2.1 C 7.77 1.09 10.52 1.83 10.25 2.84 C 10.81 2.21 12.51 3.74 11.95 4.37 C 11.86 4.28 12.41 3.71 12.5 3.8 C 12.29 3.36 13.94 2.56 14.15 3 C 14.9 2.91 15.2 5.41 14.45 5.5 C 14.87 5.67 14.12 7.47 13.7 7.3 C 13.76 7.52 12.66 7.82 12.6 7.6 C 12.32 7.63 12.62 10.43 12.9 10.4 C 13.48 10.7 11.98 13.6 11.4 13.3 C 11.64 13.7 9.64 14.9 9.4 14.5 C 9.44 14.88 7.54 15.08 7.5 14.7 C 7.46 15.08 5.56 14.88 5.6 14.5 C 5.36 14.9 3.36 13.7 3.6 13.3 C 3.02 13.6 1.52 10.7 2.1 10.4 C 2.38 10.43 2.68 7.63 2.4 7.6 C 2.34 7.82 1.24 7.52 1.3 7.3 C 0.88 7.47 0.13 5.67 0.55 5.5 C -0.2 5.41 0.1 2.91 0.85 3 C 1.06 2.56 2.71 3.36 2.5 3.8 C 2.59 3.71 3.14 4.28 3.05 4.37 C 2.49 3.74 4.19 2.21 4.75 2.84 C 4.48 1.83 7.23 1.09 7.5 2.1 Z"), pivot: (7.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 6.45 8.5 C 6.45 9.02 6.02 9.45 5.5 9.45 C 4.98 9.45 4.55 9.02 4.55 8.5 C 4.55 7.98 4.98 7.55 5.5 7.55 C 6.02 7.55 6.45 7.98 6.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 10.45 8.5 C 10.45 9.02 10.02 9.45 9.5 9.45 C 8.98 9.45 8.55 9.02 8.55 8.5 C 8.55 7.98 8.98 7.55 9.5 7.55 C 10.02 7.55 10.45 7.98 10.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 8.65 11.4 C 8.65 11.9 8.14 12.3 7.5 12.3 C 6.86 12.3 6.35 11.9 6.35 11.4 C 6.35 10.9 6.86 10.5 7.5 10.5 C 8.14 10.5 8.65 10.9 8.65 11.4 Z"), pivot: (0, 0), role: .cutout, layer: 0),
    ]

    /// Menu bar head, pant: one union silhouette in x 0..15, face cutouts. 24 x 18 pt box, y down.
    static let menuPant: [DogPart] = [
        DogPart(name: "head", ops: ops("M 7.5 2.1 C 7.77 1.09 10.52 1.83 10.25 2.84 C 10.87 2.17 12.68 3.86 12.06 4.52 C 12.15 4.44 12.6 4.91 12.5 5 C 12.5 4.56 14.15 4.56 14.15 5 C 14.93 4.91 15.23 7.51 14.45 7.6 C 14.98 7.8 14.23 9.8 13.7 9.6 C 13.74 9.8 12.74 10 12.7 9.8 C 12.54 9.81 12.64 11.41 12.8 11.4 C 13.18 11.68 11.78 13.58 11.4 13.3 C 11.64 13.7 9.64 14.9 9.4 14.5 C 9.44 14.88 7.54 15.08 7.5 14.7 C 7.46 15.08 5.56 14.88 5.6 14.5 C 5.36 14.9 3.36 13.7 3.6 13.3 C 3.22 13.58 1.82 11.68 2.2 11.4 C 2.36 11.41 2.46 9.81 2.3 9.8 C 2.26 10 1.26 9.8 1.3 9.6 C 0.77 9.8 0.02 7.8 0.55 7.6 C -0.23 7.51 0.07 4.91 0.85 5 C 0.85 4.56 2.5 4.56 2.5 5 C 2.4 4.91 2.85 4.44 2.94 4.52 C 2.32 3.86 4.13 2.17 4.75 2.84 C 4.48 1.83 7.23 1.09 7.5 2.1 Z"), pivot: (7.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 6.45 8.5 C 6.45 9.02 6.02 9.45 5.5 9.45 C 4.98 9.45 4.55 9.02 4.55 8.5 C 4.55 7.98 4.98 7.55 5.5 7.55 C 6.02 7.55 6.45 7.98 6.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 10.45 8.5 C 10.45 9.02 10.02 9.45 9.5 9.45 C 8.98 9.45 8.55 9.02 8.55 8.5 C 8.55 7.98 8.98 7.55 9.5 7.55 C 10.02 7.55 10.45 7.98 10.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 8.65 10.5 C 8.65 11 8.14 11.4 7.5 11.4 C 6.86 11.4 6.35 11 6.35 10.5 C 6.35 10 6.86 9.6 7.5 9.6 C 8.14 9.6 8.65 10 8.65 10.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.mouth", ops: ops("M 5.2 12.3 C 5.52 12.05 6.73 12.8 7.5 12.8 C 8.27 12.8 9.48 12.05 9.8 12.3 C 10.12 12.55 9.78 13.85 9.4 14.3 C 9.02 14.75 8.13 15 7.5 15 C 6.87 15 5.98 14.75 5.6 14.3 C 5.22 13.85 4.88 12.55 5.2 12.3 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "tongue", ops: ops("M 5.8 13.8 C 6.12 13.25 6.93 13.3 7.5 13.3 C 8.07 13.3 8.88 13.25 9.2 13.8 C 9.52 14.35 9.68 15.92 9.4 16.6 C 9.12 17.28 8.13 17.9 7.5 17.9 C 6.87 17.9 5.88 17.28 5.6 16.6 C 5.32 15.92 5.48 14.35 5.8 13.8 Z"), pivot: (0, 0), role: .tongue, layer: 0),
    ]

    /// Badge glyph: cpu. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeCpu: [DogPart] = [
        DogPart(name: "cpu.core", ops: ops("M 2.6 2 L 5.4 2 C 5.73 2 6 2.27 6 2.6 L 6 5.4 C 6 5.73 5.73 6 5.4 6 L 2.6 6 C 2.27 6 2 5.73 2 5.4 L 2 2.6 C 2 2.27 2.27 2 2.6 2 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "cpu.ring", ops: ops("M 5 0 L 6.0 0 C 7.1 0 8 0.9 8 2.0 L 8 6.0 C 8 7.1 7.1 8 6.0 8 L 2.0 8 C 0.9 8 0 7.1 0 6.0 L 0 2.0 C 0 0.9 0.9 0 2.0 0 L 3 0 L 3 1 L 2 1 C 1.45 1 1 1.45 1 2 L 1 6 C 1 6.55 1.45 7 2 7 L 6 7 C 6.55 7 7 6.55 7 6 L 7 2 C 7 1.45 6.55 1 6 1 L 5 1 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: memory. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeMemory: [DogPart] = [
        DogPart(name: "memory.bar", ops: ops("M 0.9 1 L 7.1 1 C 7.6 1 8 1.4 8 1.9 L 8 4.1 C 8 4.6 7.6 5 7.1 5 L 0.9 5 C 0.4 5 0 4.6 0 4.1 L 0 1.9 C 0 1.4 0.4 1 0.9 1 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "memory.pins", ops: ops("M 1 4 L 3 4 L 3 7 L 1 7 Z M 5 4 L 7 4 L 7 7 L 5 7 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: thermal. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeThermal: [DogPart] = [
        DogPart(name: "thermal.stem", ops: ops("M 4 0 L 4 0 C 4.55 0 5 0.45 5 1 L 5 4 C 5 4.55 4.55 5 4 5 L 4 5 C 3.45 5 3 4.55 3 4 L 3 1 C 3 0.45 3.45 0 4 0 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "thermal.bulb", ops: ops("M 6.2 5.8 C 6.2 7.02 5.22 8 4 8 C 2.78 8 1.8 7.02 1.8 5.8 C 1.8 4.58 2.78 3.6 4 3.6 C 5.22 3.6 6.2 4.58 6.2 5.8 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: disk. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgeDisk: [DogPart] = [
        DogPart(name: "disk.lid", ops: ops("M 1 2 C 1 0.8 2.34 0 4 0 C 5.66 0 7 0.8 7 2 L 1 2 Z"), pivot: (4, 4), role: .ink, layer: 0),
        DogPart(name: "disk.body", ops: ops("M 1 3 L 7 3 L 7 6.8 C 7 7.6 5.66 8 4 8 C 2.34 8 1 7.6 1 6.8 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]

    /// Badge glyph: power. 8 x 8 pt box, y down, on the 1x pixel grid.
    static let badgePower: [DogPart] = [
        DogPart(name: "power.bolt", ops: ops("M 4 0 L 7 0 L 5.2 3 L 7.5 3 L 2.5 8 L 3.6 4.6 L 1 4.6 Z"), pivot: (4, 4), role: .ink, layer: 0),
    ]
    // ART-END
}
