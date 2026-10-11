// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (hand-written art data, docs/DESIGN.md 4.2, 8.1).
// Output: Bezier path data for the dog parts, the menu bar head and the corner badge glyphs.
// Pos: Art assets: numbers, names and enums. No drawing code. Foundation only. Owner I2. DogRig never changes the shapes.
//
// Coordinates: the card dog uses a 120 x 90 u box, origin top left, y down, the dog faces right, ground y = 82.
// The menu bar head uses a 24 x 18 pt box, y down. A badge uses a 10 x 10 pt box, y down.
// GlyphPaths and the menu renderer flip y for AppKit.
//
// Each shape is SVG-style path data (M, L, C, Z, absolute). The numbers were placed by hand on an authoring
// sheet: anchors around the silhouette, one cubic "lock of fur" per edge. Edit the numbers to change the art.

import Foundation

enum DogPathOp: Equatable {
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
enum DogOverlay: String, CaseIterable { case bundle, bubble, heat, speed }

enum DogArt {
    static let designSize: (w: Double, h: Double) = (120, 90)
    static let groundY = 82.0
    /// The lie pose moves the whole head down by this offset (u). The head art itself is the same.
    static let lieHeadOffset: (x: Double, y: Double) = (0, 20)
    /// Where the badge glyph sits in the thought bubble (u): a 10 x 10 box centered in the bubble.
    static let bubbleGlyphFrame: (x: Double, y: Double, size: Double) = (103.5, 4.5, 10)

    static let menuSize: (w: Double, h: Double) = (24, 18)
    /// Top-left corner of the 10 x 10 pt badge box in the menu head box (y down): x 14 to 24, y 8 to 18.
    static let menuBadgeOrigin: (x: Double, y: Double) = (14, 8)
    static let badgeSize = 10.0

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
        case .speed: return speed
        }
    }

    /// The menu bar head: relaxed, raised ears, tongue out. Design box 24 x 18 pt, y down.
    /// `hollow` uses the relaxed art; the renderer draws it as a 1 pt outline.
    static func menuHead(_ posture: MenuPosture) -> [DogPart] {
        switch posture {
        case .relaxed, .hollow: return menuRelaxed
        case .raised: return menuRaised
        case .pant: return menuPant
        }
    }

    /// The clear gap around the badge, in the 24 x 18 pt box, y down.
    static var menuBadgeCutout: [DogPathOp] { menuBadgeCutoutPath }

    /// Corner badge glyph in a 10 x 10 pt box, y down. At most 2 features, all solid (docs/DESIGN.md 3.3).
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
        DogPart(name: "leg.farFore", ops: ops("M 86 73.5 C 85.98 72.14 102.98 71.84 103 73.2 C 103.85 71.94 108.35 74.99 107.5 76.25 C 108.45 76.7 106.95 79.85 106 79.4 C 106.17 80.52 102.17 81.12 102 80 C 102 82.67 86 82.67 86 80 C 85.57 80 85.57 73.5 86 73.5 Z"), pivot: (86, 77), role: .shade, layer: 10),
        DogPart(name: "tail", ops: ops("M 26 66 C 24.83 68.17 18.33 64.67 19.5 62.5 C 17.12 63.6 14.12 57.1 16.5 56 C 14.12 55.27 16.12 48.77 18.5 49.5 C 17.22 47.3 23.22 43.8 24.5 46 C 24.67 43.67 31.67 44.17 31.5 46.5 C 32.83 44.83 37.83 48.83 36.5 50.5 C 38 50.35 38.5 55.35 37 55.5 C 37.5 56.2 34 58.7 33.5 58 C 33.48 58.12 29.98 57.62 30 57.5 C 30.07 57.58 27.57 59.58 27.5 59.5 C 27.6 59.48 28.1 62.48 28 62.5 C 28.35 62.7 26.35 66.2 26 66 Z"), pivot: (26, 64), role: .fur, layer: 20),
        DogPart(name: "leg.nearFore", ops: ops("M 80 75.2 C 79.98 73.76 97.98 73.46 98 74.9 C 98.92 73.64 103.42 76.94 102.5 78.2 C 103.52 78.65 102.02 82.05 101 81.6 C 101.17 82.72 97.17 83.32 97 82.2 C 97 85.03 80 85.03 80 82.2 C 79.53 82.2 79.53 75.2 80 75.2 Z"), pivot: (80, 78), role: .fur, layer: 30),
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

    /// Bundle on the back (memory red): two straps, the puffy sack, a bow knot and dots.
    static let bundle: [DogPart] = [
        DogPart(name: "bundle.strapA", ops: ops("M 41.91 36.68 L 41.97 37.24 L 42.05 37.96 L 42.15 38.81 L 42.26 39.77 L 42.37 40.8 L 42.5 41.89 L 42.62 43 L 42.75 44.11 L 42.88 45.18 L 43.01 46.2 L 43.14 47.2 L 43.28 48.21 L 43.42 49.23 L 43.56 50.26 L 43.71 51.29 L 43.86 52.31 L 44 53.32 L 44.14 54.32 L 44.28 55.28 L 44.42 56.22 L 44.55 57.17 L 44.69 58.16 L 44.83 59.15 L 44.97 60.14 L 45.1 61.1 L 45.23 62.01 L 45.35 62.85 L 45.46 63.59 L 45.55 64.22 L 45.62 64.72 L 48.71 63.78 L 48.62 63.14 L 48.52 62.4 L 48.4 61.56 L 48.27 60.65 L 48.14 59.69 L 48 58.7 L 47.86 57.71 L 47.72 56.73 L 47.58 55.78 L 47.45 54.83 L 47.31 53.86 L 47.17 52.87 L 47.02 51.86 L 46.88 50.84 L 46.73 49.81 L 46.59 48.79 L 46.45 47.78 L 46.31 46.78 L 46.19 45.8 L 46.06 44.79 L 45.93 43.73 L 45.8 42.63 L 45.68 41.53 L 45.55 40.45 L 45.44 39.41 L 45.33 38.46 L 45.23 37.61 L 45.15 36.88 L 45.09 36.32 Z"), pivot: (51, 38), role: .strap, layer: 90),
        DogPart(name: "bundle.strapB", ops: ops("M 56.91 36.65 L 56.96 37.21 L 57.02 37.93 L 57.1 38.78 L 57.19 39.74 L 57.28 40.77 L 57.38 41.86 L 57.49 42.97 L 57.59 44.07 L 57.7 45.15 L 57.81 46.17 L 57.92 47.17 L 58.04 48.18 L 58.16 49.21 L 58.29 50.23 L 58.42 51.26 L 58.55 52.28 L 58.67 53.29 L 58.79 54.28 L 58.91 55.24 L 59.01 56.17 L 59.11 57.11 L 59.21 58.09 L 59.3 59.08 L 59.39 60.06 L 59.48 61.02 L 59.56 61.93 L 59.64 62.76 L 59.7 63.51 L 59.76 64.15 L 59.81 64.65 L 62.95 63.86 L 62.89 63.23 L 62.83 62.48 L 62.75 61.64 L 62.67 60.73 L 62.58 59.77 L 62.49 58.78 L 62.39 57.78 L 62.29 56.79 L 62.19 55.83 L 62.08 54.88 L 61.97 53.9 L 61.85 52.9 L 61.72 51.89 L 61.59 50.86 L 61.47 49.84 L 61.34 48.82 L 61.22 47.8 L 61.1 46.81 L 60.99 45.83 L 60.89 44.82 L 60.78 43.76 L 60.67 42.66 L 60.57 41.56 L 60.47 40.48 L 60.37 39.45 L 60.29 38.49 L 60.21 37.64 L 60.15 36.92 L 60.09 36.35 Z"), pivot: (51, 38), role: .strap, layer: 90),
        DogPart(name: "bundle.sack", ops: ops("M 38 34.5 C 37.25 32.55 38.33 28.5 39.5 26.5 C 40.67 24.5 42.92 23.33 45 22.5 C 47.08 21.67 49.67 21.42 52 21.5 C 54.33 21.58 57.08 21.92 59 23 C 60.92 24.08 62.67 26 63.5 28 C 64.33 30 64.92 33.3 64 35 C 63.08 36.7 60.17 37.57 58 38.2 C 55.83 38.83 53.33 38.8 51 38.8 C 48.67 38.8 46.17 38.92 44 38.2 C 41.83 37.48 38.75 36.45 38 34.5 Z"), pivot: (51, 38), role: .bundle, layer: 100),
        DogPart(name: "bundle.knotL", ops: ops("M 50 21.5 C 49.37 20.7 47.23 18.68 46 18.2 C 44.77 17.72 43.13 17.9 42.6 18.6 C 42.07 19.3 42.17 21.5 42.8 22.4 C 43.43 23.3 45.23 23.9 46.4 24 C 47.57 24.1 49.2 23.42 49.8 23 C 50.4 22.58 50.63 22.3 50 21.5 Z"), pivot: (51, 38), role: .bundle, layer: 100),
        DogPart(name: "bundle.knotR", ops: ops("M 53 21.5 C 53.63 20.7 55.77 18.68 57 18.2 C 58.23 17.72 59.87 17.9 60.4 18.6 C 60.93 19.3 60.83 21.5 60.2 22.4 C 59.57 23.3 57.77 23.9 56.6 24 C 55.43 24.1 53.8 23.42 53.2 23 C 52.6 22.58 52.37 22.3 53 21.5 Z"), pivot: (51, 38), role: .bundle, layer: 100),
        DogPart(name: "bundle.knot", ops: ops("M 54.1 22.2 C 54.1 23.47 52.94 24.5 51.5 24.5 C 50.06 24.5 48.9 23.47 48.9 22.2 C 48.9 20.93 50.06 19.9 51.5 19.9 C 52.94 19.9 54.1 20.93 54.1 22.2 Z"), pivot: (51, 38), role: .bundle, layer: 100),
        DogPart(name: "bundle.dot0", ops: ops("M 45.8 30 C 45.8 30.72 45.22 31.3 44.5 31.3 C 43.78 31.3 43.2 30.72 43.2 30 C 43.2 29.28 43.78 28.7 44.5 28.7 C 45.22 28.7 45.8 29.28 45.8 30 Z"), pivot: (51, 38), role: .bundleDot, layer: 110),
        DogPart(name: "bundle.dot1", ops: ops("M 52.3 27.5 C 52.3 28.22 51.72 28.8 51 28.8 C 50.28 28.8 49.7 28.22 49.7 27.5 C 49.7 26.78 50.28 26.2 51 26.2 C 51.72 26.2 52.3 26.78 52.3 27.5 Z"), pivot: (51, 38), role: .bundleDot, layer: 110),
        DogPart(name: "bundle.dot2", ops: ops("M 58.8 30.5 C 58.8 31.22 58.22 31.8 57.5 31.8 C 56.78 31.8 56.2 31.22 56.2 30.5 C 56.2 29.78 56.78 29.2 57.5 29.2 C 58.22 29.2 58.8 29.78 58.8 30.5 Z"), pivot: (51, 38), role: .bundleDot, layer: 110),
        DogPart(name: "bundle.dot3", ops: ops("M 48.7 35 C 48.7 35.66 48.16 36.2 47.5 36.2 C 46.84 36.2 46.3 35.66 46.3 35 C 46.3 34.34 46.84 33.8 47.5 33.8 C 48.16 33.8 48.7 34.34 48.7 35 Z"), pivot: (51, 38), role: .bundleDot, layer: 110),
        DogPart(name: "bundle.dot4", ops: ops("M 55.7 35.2 C 55.7 35.86 55.16 36.4 54.5 36.4 C 53.84 36.4 53.3 35.86 53.3 35.2 C 53.3 34.54 53.84 34 54.5 34 C 55.16 34 55.7 34.54 55.7 35.2 Z"), pivot: (51, 38), role: .bundleDot, layer: 110),
    ]

    /// Thought bubble (any problem). The glyph goes in bubbleGlyphFrame.
    static let bubble: [DogPart] = [
        DogPart(name: "bubble.tail2", ops: ops("M 98.9 19.4 C 98.9 20.12 98.32 20.7 97.6 20.7 C 96.88 20.7 96.3 20.12 96.3 19.4 C 96.3 18.68 96.88 18.1 97.6 18.1 C 98.32 18.1 98.9 18.68 98.9 19.4 Z"), pivot: (108.5, 9.5), role: .bubble, layer: 120),
        DogPart(name: "bubble.tail1", ops: ops("M 102.7 15.6 C 102.7 16.76 101.76 17.7 100.6 17.7 C 99.44 17.7 98.5 16.76 98.5 15.6 C 98.5 14.44 99.44 13.5 100.6 13.5 C 101.76 13.5 102.7 14.44 102.7 15.6 Z"), pivot: (108.5, 9.5), role: .bubble, layer: 120),
        DogPart(name: "bubble.main", ops: ops("M 99 9 C 99 6.77 100.33 3.93 102 2.6 C 103.67 1.27 106.75 0.87 109 1 C 111.25 1.13 114 1.98 115.5 3.4 C 117 4.82 118 7.47 118 9.5 C 118 11.53 117 14.18 115.5 15.6 C 114 17.02 111.25 17.93 109 18 C 106.75 18.07 103.67 17.5 102 16 C 100.33 14.5 99 11.23 99 9 Z"), pivot: (108.5, 9.5), role: .bubble, layer: 120),
    ]

    /// Two heat waves above the head (pant).
    static let heat: [DogPart] = [
        DogPart(name: "fx.heat1", ops: ops("M 84.48 9.94 L 84.59 9.8 L 84.77 9.62 L 85.01 9.39 L 85.28 9.13 L 85.57 8.84 L 85.85 8.52 L 86.11 8.19 L 86.34 7.83 L 86.51 7.44 L 86.58 6.99 L 86.48 6.53 L 86.25 6.16 L 85.97 5.85 L 85.66 5.58 L 85.35 5.33 L 85.06 5.09 L 84.81 4.87 L 84.63 4.68 L 84.54 4.55 L 84.52 4.49 L 84.53 4.4 L 84.61 4.21 L 84.77 3.97 L 84.98 3.7 L 85.22 3.43 L 85.48 3.16 L 85.74 2.91 L 85.98 2.68 L 86.19 2.47 L 86.33 2.3 C 86.71 1.86 86.08 1.28 85.67 1.7 L 85.54 1.83 L 85.35 2 L 85.1 2.22 L 84.82 2.48 L 84.53 2.76 L 84.24 3.06 L 83.97 3.37 L 83.74 3.71 L 83.56 4.08 L 83.48 4.51 L 83.57 4.95 L 83.78 5.32 L 84.05 5.63 L 84.34 5.91 L 84.65 6.17 L 84.93 6.42 L 85.17 6.65 L 85.34 6.84 L 85.41 6.97 L 85.42 7.01 L 85.39 7.08 L 85.31 7.25 L 85.15 7.47 L 84.93 7.72 L 84.68 7.98 L 84.41 8.23 L 84.15 8.47 L 83.9 8.7 L 83.68 8.9 L 83.52 9.06 C 82.93 9.66 83.93 10.58 84.48 9.94 Z"), pivot: (85, 8), role: .effect, layer: 130),
        DogPart(name: "fx.heat2", ops: ops("M 92.48 10.94 L 92.59 10.8 L 92.77 10.62 L 93.01 10.39 L 93.28 10.13 L 93.57 9.84 L 93.85 9.52 L 94.11 9.19 L 94.34 8.83 L 94.51 8.44 L 94.58 7.99 L 94.48 7.53 L 94.25 7.16 L 93.97 6.85 L 93.66 6.58 L 93.35 6.33 L 93.06 6.09 L 92.81 5.87 L 92.63 5.68 L 92.54 5.55 L 92.52 5.49 L 92.53 5.4 L 92.61 5.21 L 92.77 4.97 L 92.98 4.7 L 93.22 4.43 L 93.48 4.16 L 93.74 3.91 L 93.98 3.68 L 94.19 3.47 L 94.33 3.3 C 94.71 2.86 94.08 2.28 93.67 2.7 L 93.54 2.83 L 93.35 3 L 93.1 3.22 L 92.82 3.48 L 92.53 3.76 L 92.24 4.06 L 91.97 4.37 L 91.74 4.71 L 91.56 5.08 L 91.48 5.51 L 91.57 5.95 L 91.78 6.32 L 92.05 6.63 L 92.34 6.91 L 92.65 7.17 L 92.93 7.42 L 93.17 7.65 L 93.34 7.84 L 93.41 7.97 L 93.42 8.01 L 93.39 8.08 L 93.31 8.25 L 93.15 8.47 L 92.93 8.72 L 92.68 8.98 L 92.41 9.23 L 92.15 9.47 L 91.9 9.7 L 91.68 9.9 L 91.52 10.06 C 90.93 10.66 91.93 11.58 92.48 10.94 Z"), pivot: (93, 9), role: .effect, layer: 130),
    ]

    /// Three speed lines behind the dog (sprint).
    static let speed: [DogPart] = [
        DogPart(name: "fx.speed1", ops: ops("M 14 39.2 L 13.36 39.2 L 12.48 39.2 L 11.42 39.2 L 10.24 39.2 L 9 39.2 L 7.76 39.2 L 6.58 39.2 L 5.52 39.2 L 4.64 39.2 L 4 39.2 C 2.96 39.2 2.96 40.8 4 40.8 L 4.64 40.8 L 5.52 40.8 L 6.58 40.8 L 7.76 40.8 L 9 40.8 L 10.24 40.8 L 11.42 40.8 L 12.48 40.8 L 13.36 40.8 L 14 40.8 C 15.04 40.8 15.04 39.2 14 39.2 Z"), pivot: (14, 40), role: .effect, layer: 130),
        DogPart(name: "fx.speed2", ops: ops("M 16 49.2 L 15.1 49.2 L 13.87 49.2 L 12.39 49.2 L 10.74 49.2 L 9 49.2 L 7.26 49.2 L 5.61 49.2 L 4.13 49.2 L 2.9 49.2 L 2 49.2 C 0.96 49.2 0.96 50.8 2 50.8 L 2.9 50.8 L 4.13 50.8 L 5.61 50.8 L 7.26 50.8 L 9 50.8 L 10.74 50.8 L 12.39 50.8 L 13.87 50.8 L 15.1 50.8 L 16 50.8 C 17.04 50.8 17.04 49.2 16 49.2 Z"), pivot: (16, 50), role: .effect, layer: 130),
        DogPart(name: "fx.speed3", ops: ops("M 14 57.2 L 13.49 57.2 L 12.78 57.2 L 11.94 57.2 L 10.99 57.2 L 10 57.2 L 9.01 57.2 L 8.06 57.2 L 7.22 57.2 L 6.51 57.2 L 6 57.2 C 4.96 57.2 4.96 58.8 6 58.8 L 6.51 58.8 L 7.22 58.8 L 8.06 58.8 L 9.01 58.8 L 10 58.8 L 10.99 58.8 L 11.94 58.8 L 12.78 58.8 L 13.49 58.8 L 14 58.8 C 15.04 58.8 15.04 57.2 14 57.2 Z"), pivot: (14, 58), role: .effect, layer: 130),
    ]

    /// Menu bar head, relaxed. 24 x 18 pt box, y down.
    static let menuRelaxed: [DogPart] = [
        DogPart(name: "head", ops: ops("M 3.96 11.5 C 2.82 11.85 1.98 9.09 3.12 8.75 C 2.04 8.55 2.5 5.95 3.58 6.15 C 2.68 5.56 4.1 3.37 5 3.96 C 4.38 3.08 6.52 1.58 7.14 2.46 C 6.95 1.39 9.53 0.94 9.72 2 C 9.98 0.95 12.52 1.59 12.26 2.64 C 12.94 1.8 14.97 3.45 14.29 4.28 C 15.23 3.76 16.5 6.04 15.56 6.56 C 16.73 6.46 16.98 9.31 15.8 9.41 C 16.67 9.73 15.91 11.81 15.04 11.5 C 15.54 11.79 14.1 14.29 13.6 14 C 13.93 14.54 11.63 15.94 11.3 15.4 C 11.3 16.6 7.7 16.6 7.7 15.4 C 7.37 15.94 5.07 14.54 5.4 14 C 4.9 14.29 3.46 11.79 3.96 11.5 Z"), pivot: (9.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "earLeft", ops: ops("M 3.3 4.2 C 3.58 3.86 5.28 5.26 5 5.6 C 5.52 5.56 5.82 9.46 5.3 9.5 C 5.85 9.55 5.45 13.65 4.9 13.6 C 5.74 14.33 3.74 16.63 2.9 15.9 C 2.31 16.56 0.51 14.96 1.1 14.3 C 0.5 14.33 0.3 9.83 0.9 9.8 C 0.34 9.71 1.04 5.51 1.6 5.6 C 1.32 5.26 3.02 3.86 3.3 4.2 Z"), pivot: (3.4, 4.5), role: .ear, layer: 0),
        DogPart(name: "earRight", ops: ops("M 15.7 4.2 C 15.42 3.86 13.72 5.26 14 5.6 C 13.48 5.56 13.18 9.46 13.7 9.5 C 13.15 9.55 13.55 13.65 14.1 13.6 C 13.26 14.33 15.26 16.63 16.1 15.9 C 16.69 16.56 18.49 14.96 17.9 14.3 C 18.5 14.33 18.7 9.83 18.1 9.8 C 18.66 9.71 17.96 5.51 17.4 5.6 C 17.68 5.26 15.98 3.86 15.7 4.2 Z"), pivot: (15.6, 4.5), role: .ear, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 7.45 8.5 C 7.45 9.02 7.02 9.45 6.5 9.45 C 5.98 9.45 5.55 9.02 5.55 8.5 C 5.55 7.98 5.98 7.55 6.5 7.55 C 7.02 7.55 7.45 7.98 7.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 13.45 8.5 C 13.45 9.02 13.02 9.45 12.5 9.45 C 11.98 9.45 11.55 9.02 11.55 8.5 C 11.55 7.98 11.98 7.55 12.5 7.55 C 13.02 7.55 13.45 7.98 13.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 10.65 11.5 C 10.65 12 10.14 12.4 9.5 12.4 C 8.86 12.4 8.35 12 8.35 11.5 C 8.35 11 8.86 10.6 9.5 10.6 C 10.14 10.6 10.65 11 10.65 11.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
    ]

    /// Menu bar head, raised. 24 x 18 pt box, y down.
    static let menuRaised: [DogPart] = [
        DogPart(name: "head", ops: ops("M 3.96 11.5 C 2.82 11.85 1.98 9.09 3.12 8.75 C 2.04 8.55 2.5 5.95 3.58 6.15 C 2.68 5.56 4.1 3.37 5 3.96 C 4.38 3.08 6.52 1.58 7.14 2.46 C 6.95 1.39 9.53 0.94 9.72 2 C 9.98 0.95 12.52 1.59 12.26 2.64 C 12.94 1.8 14.97 3.45 14.29 4.28 C 15.23 3.76 16.5 6.04 15.56 6.56 C 16.73 6.46 16.98 9.31 15.8 9.41 C 16.67 9.73 15.91 11.81 15.04 11.5 C 15.54 11.79 14.1 14.29 13.6 14 C 13.93 14.54 11.63 15.94 11.3 15.4 C 11.3 16.6 7.7 16.6 7.7 15.4 C 7.37 15.94 5.07 14.54 5.4 14 C 4.9 14.29 3.46 11.79 3.96 11.5 Z"), pivot: (9.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "earLeft", ops: ops("M 3.6 3.6 C 3.92 3.28 5.52 4.88 5.2 5.2 C 5.65 5.28 5.05 8.68 4.6 8.6 C 5 8.81 3.4 11.81 3 11.6 C 3.29 12.22 1.59 13.02 1.3 12.4 C 0.57 12.55 0.17 10.55 0.9 10.4 C 0.27 10.38 0.37 6.58 1 6.6 C 0.71 6.48 1.61 4.28 1.9 4.4 C 1.74 4.06 3.44 3.26 3.6 3.6 Z"), pivot: (3.4, 4.5), role: .ear, layer: 0),
        DogPart(name: "earRight", ops: ops("M 15.4 3.6 C 15.08 3.28 13.48 4.88 13.8 5.2 C 13.35 5.28 13.95 8.68 14.4 8.6 C 14 8.81 15.6 11.81 16 11.6 C 15.71 12.22 17.41 13.02 17.7 12.4 C 18.43 12.55 18.83 10.55 18.1 10.4 C 18.73 10.38 18.63 6.58 18 6.6 C 18.29 6.48 17.39 4.28 17.1 4.4 C 17.26 4.06 15.56 3.26 15.4 3.6 Z"), pivot: (15.6, 4.5), role: .ear, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 7.45 8.5 C 7.45 9.02 7.02 9.45 6.5 9.45 C 5.98 9.45 5.55 9.02 5.55 8.5 C 5.55 7.98 5.98 7.55 6.5 7.55 C 7.02 7.55 7.45 7.98 7.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 13.45 8.5 C 13.45 9.02 13.02 9.45 12.5 9.45 C 11.98 9.45 11.55 9.02 11.55 8.5 C 11.55 7.98 11.98 7.55 12.5 7.55 C 13.02 7.55 13.45 7.98 13.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 10.65 11.5 C 10.65 12 10.14 12.4 9.5 12.4 C 8.86 12.4 8.35 12 8.35 11.5 C 8.35 11 8.86 10.6 9.5 10.6 C 10.14 10.6 10.65 11 10.65 11.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
    ]

    /// Menu bar head, pant. 24 x 18 pt box, y down.
    static let menuPant: [DogPart] = [
        DogPart(name: "head", ops: ops("M 3.96 11.5 C 2.82 11.85 1.98 9.09 3.12 8.75 C 2.04 8.55 2.5 5.95 3.58 6.15 C 2.68 5.56 4.1 3.37 5 3.96 C 4.38 3.08 6.52 1.58 7.14 2.46 C 6.95 1.39 9.53 0.94 9.72 2 C 9.98 0.95 12.52 1.59 12.26 2.64 C 12.94 1.8 14.97 3.45 14.29 4.28 C 15.23 3.76 16.5 6.04 15.56 6.56 C 16.73 6.46 16.98 9.31 15.8 9.41 C 16.67 9.73 15.91 11.81 15.04 11.5 C 15.54 11.79 14.1 14.29 13.6 14 C 13.93 14.54 11.63 15.94 11.3 15.4 C 11.3 16.6 7.7 16.6 7.7 15.4 C 7.37 15.94 5.07 14.54 5.4 14 C 4.9 14.29 3.46 11.79 3.96 11.5 Z"), pivot: (9.5, 8.5), role: .fur, layer: 0),
        DogPart(name: "earLeft", ops: ops("M 4.2 3 C 4.6 2.76 5.8 4.76 5.4 5 C 5.75 5.21 4.15 7.81 3.8 7.6 C 4.1 7.92 2.2 9.72 1.9 9.4 C 1.61 9.73 0.71 8.93 1 8.6 C 0.12 8.6 0.12 6.2 1 6.2 C 0.52 6.06 1.22 3.66 1.7 3.8 C 1.46 3.56 2.66 2.36 2.9 2.6 C 2.98 2.34 4.28 2.74 4.2 3 Z"), pivot: (3.4, 4.5), role: .ear, layer: 0),
        DogPart(name: "earRight", ops: ops("M 14.8 3 C 14.4 2.76 13.2 4.76 13.6 5 C 13.25 5.21 14.85 7.81 15.2 7.6 C 14.9 7.92 16.8 9.72 17.1 9.4 C 17.39 9.73 18.29 8.93 18 8.6 C 18.88 8.6 18.88 6.2 18 6.2 C 18.48 6.06 17.78 3.66 17.3 3.8 C 17.54 3.56 16.34 2.36 16.1 2.6 C 16.02 2.34 14.72 2.74 14.8 3 Z"), pivot: (15.6, 4.5), role: .ear, layer: 0),
        DogPart(name: "cut.eyeLeft", ops: ops("M 7.45 8.5 C 7.45 9.02 7.02 9.45 6.5 9.45 C 5.98 9.45 5.55 9.02 5.55 8.5 C 5.55 7.98 5.98 7.55 6.5 7.55 C 7.02 7.55 7.45 7.98 7.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.eyeRight", ops: ops("M 13.45 8.5 C 13.45 9.02 13.02 9.45 12.5 9.45 C 11.98 9.45 11.55 9.02 11.55 8.5 C 11.55 7.98 11.98 7.55 12.5 7.55 C 13.02 7.55 13.45 7.98 13.45 8.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.nose", ops: ops("M 10.65 11.5 C 10.65 12 10.14 12.4 9.5 12.4 C 8.86 12.4 8.35 12 8.35 11.5 C 8.35 11 8.86 10.6 9.5 10.6 C 10.14 10.6 10.65 11 10.65 11.5 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "cut.mouth", ops: ops("M 7.4 13 C 7.68 12.73 8.8 13.4 9.5 13.4 C 10.2 13.4 11.32 12.73 11.6 13 C 11.88 13.27 11.55 14.57 11.2 15 C 10.85 15.43 10.07 15.6 9.5 15.6 C 8.93 15.6 8.15 15.43 7.8 15 C 7.45 14.57 7.12 13.27 7.4 13 Z"), pivot: (0, 0), role: .cutout, layer: 0),
        DogPart(name: "tongue", ops: ops("M 8 14.8 C 8.27 14.42 9 14.3 9.5 14.3 C 10 14.3 10.73 14.42 11 14.8 C 11.27 15.18 11.35 16.12 11.1 16.6 C 10.85 17.08 10.03 17.7 9.5 17.7 C 8.97 17.7 8.15 17.08 7.9 16.6 C 7.65 16.12 7.73 15.18 8 14.8 Z"), pivot: (0, 0), role: .tongue, layer: 0),
    ]

    /// Clear gap around the badge: 12 x 12 pt rounded square, 1 pt larger than the badge on each side.
    static let menuBadgeCutoutPath: [DogPathOp] = ops("M 16.2 7 L 21.8 7 C 23.56736 7 25 8.43264 25 10.2 L 25 15.8 C 25 17.56736 23.56736 19 21.8 19 L 16.2 19 C 14.43264 19 13 17.56736 13 15.8 L 13 10.2 C 13 8.43264 14.43264 7 16.2 7 Z")

    /// Badge glyph: cpu. 10 x 10 pt box, y down.
    static let badgeCpu: [DogPart] = [
        DogPart(name: "cpu.core", ops: ops("M 3.65 2.75 L 6.35 2.75 C 6.85 2.75 7.25 3.15 7.25 3.65 L 7.25 6.35 C 7.25 6.85 6.85 7.25 6.35 7.25 L 3.65 7.25 C 3.15 7.25 2.75 6.85 2.75 6.35 L 2.75 3.65 C 2.75 3.15 3.15 2.75 3.65 2.75 Z"), pivot: (5, 5), role: .ink, layer: 0),
        DogPart(name: "cpu.ring", ops: ops("M 6.5 0.5 L 7.3 0.5 C 8.51506 0.5 9.5 1.4849400000000001 9.5 2.7 L 9.5 7.3 C 9.5 8.51506 8.51506 9.5 7.3 9.5 L 2.7 9.5 C 1.4849400000000001 9.5 0.5 8.51506 0.5 7.3 L 0.5 2.7 C 0.5 1.4849400000000001 1.4849400000000001 0.5 2.7 0.5 L 3.5 0.5 L 3.5 1.5 L 2.7 1.5 C 2.03724 1.5 1.5 2.03724 1.5 2.7 L 1.5 7.3 C 1.5 7.962759999999999 2.03724 8.5 2.7 8.5 L 7.3 8.5 C 7.962759999999999 8.5 8.5 7.962759999999999 8.5 7.3 L 8.5 2.7 C 8.5 2.03724 7.962759999999999 1.5 7.3 1.5 L 6.5 1.5 Z"), pivot: (5, 5), role: .ink, layer: 0),
    ]

    /// Badge glyph: memory. 10 x 10 pt box, y down.
    static let badgeMemory: [DogPart] = [
        DogPart(name: "memory.bar", ops: ops("M 1.8 3 L 8.2 3 C 8.92 3 9.5 3.58 9.5 4.3 L 9.5 5.7 C 9.5 6.42 8.92 7 8.2 7 L 1.8 7 C 1.08 7 0.5 6.42 0.5 5.7 L 0.5 4.3 C 0.5 3.58 1.08 3 1.8 3 Z"), pivot: (5, 5), role: .ink, layer: 0),
    ]

    /// Badge glyph: thermal. 10 x 10 pt box, y down.
    static let badgeThermal: [DogPart] = [
        DogPart(name: "thermal.stem", ops: ops("M 5 0 L 5 0 C 5.83 0 6.5 0.67 6.5 1.5 L 6.5 5 C 6.5 5.83 5.83 6.5 5 6.5 L 5 6.5 C 4.17 6.5 3.5 5.83 3.5 5 L 3.5 1.5 C 3.5 0.67 4.17 0 5 0 Z"), pivot: (5, 5), role: .ink, layer: 0),
        DogPart(name: "thermal.bulb", ops: ops("M 7.5 7.5 C 7.5 8.88 6.38 10 5 10 C 3.62 10 2.5 8.88 2.5 7.5 C 2.5 6.12 3.62 5 5 5 C 6.38 5 7.5 6.12 7.5 7.5 Z"), pivot: (5, 5), role: .ink, layer: 0),
    ]

    /// Badge glyph: disk. 10 x 10 pt box, y down.
    static let badgeDisk: [DogPart] = [
        DogPart(name: "disk.body", ops: ops("M 1.5 2 C 1.5 0.9 3.07 0.5 5 0.5 C 6.93 0.5 8.5 0.9 8.5 2 L 8.5 8 C 8.5 9.1 6.93 9.5 5 9.5 C 3.07 9.5 1.5 9.1 1.5 8 Z"), pivot: (5, 5), role: .ink, layer: 0),
    ]

    /// Badge glyph: power. 10 x 10 pt box, y down.
    static let badgePower: [DogPart] = [
        DogPart(name: "power.bolt", ops: ops("M 5.5 0 L 1.5 5.5 L 4.5 5.5 L 3.5 10 L 8.5 4 L 5.5 4 Z"), pivot: (5, 5), role: .ink, layer: 0),
    ]
    // ART-END
}
