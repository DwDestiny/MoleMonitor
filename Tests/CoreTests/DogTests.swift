// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for DogArt, DogRig, DogMotor and MenuIconModel (docs/DESIGN.md 9.1), plus the 1x XOR metric
//         of the menu head, badges and alarm discs, and the 72 pt card leg and bubble metrics, from a small software
//         rasterizer (the CI gallery measures the CG pixels again).
// Pos: Called from main.swift via runDogTests(); no top-level code in this file. Owner I2.

import Foundation

// MARK: - Software rasterizer (tests only)

/// Flattens path ops into closed polygons. Cubics use 16 segments.
private func dogPolygons(_ ops: [DogPathOp], _ t: (Double, Double) -> (Double, Double) = { ($0, $1) }) -> [[(Double, Double)]] {
    var polys = [[(Double, Double)]]()
    var cur = [(Double, Double)]()
    var pos = (0.0, 0.0)
    for op in ops {
        switch op {
        case let .move(x, y):
            if cur.count > 1 { polys.append(cur) }
            pos = (x, y); cur = [t(x, y)]
        case let .line(x, y):
            pos = (x, y); cur.append(t(x, y))
        case let .cubic(x1, y1, x2, y2, x, y):
            for k in 1...16 {
                let s = Double(k) / 16, u = 1 - s
                let px = u * u * u * pos.0 + 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s * x
                let py = u * u * u * pos.1 + 3 * u * u * s * y1 + 3 * u * s * s * y2 + s * s * s * y
                cur.append(t(px, py))
            }
            pos = (x, y)
        case .close:
            if cur.count > 1 { polys.append(cur) }
            cur = []
        }
    }
    if cur.count > 1 { polys.append(cur) }
    return polys
}

private func dogWinding(_ polys: [[(Double, Double)]], _ x: Double, _ y: Double) -> Int {
    var w = 0
    for poly in polys {
        let n = poly.count
        for k in 0..<n {
            let (x0, y0) = poly[k], (x1, y1) = poly[(k + 1) % n]
            if (y0 <= y && y < y1) || (y1 <= y && y < y0) {
                let xi = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
                if xi > x { w += (y1 > y0) ? 1 : -1 }
            }
        }
    }
    return w
}

/// Coverage grid of a fill (stroke == nil) or a centered stroke of the given width.
/// `insideOnly` keeps only the part of the stroke inside the fill (the clipped inner ring of the hollow icon).
private func dogCoverage(_ polys: [[(Double, Double)]], w: Int, h: Int, stroke: Double? = nil, insideOnly: Bool = false,
                         ss: Int = 8) -> [[Double]] {
    var grid = Array(repeating: Array(repeating: 0.0, count: w), count: h)
    for py in 0..<h {
        for px in 0..<w {
            var c = 0
            for sy in 0..<ss {
                for sx in 0..<ss {
                    let x = Double(px) + (Double(sx) + 0.5) / Double(ss)
                    let y = Double(py) + (Double(sy) + 0.5) / Double(ss)
                    if let width = stroke {
                        if dogNearOutline(polys, x, y, width / 2), !insideOnly || dogWinding(polys, x, y) != 0 { c += 1 }
                    } else if dogWinding(polys, x, y) != 0 {
                        c += 1
                    }
                }
            }
            grid[py][px] = Double(c) / Double(ss * ss)
        }
    }
    return grid
}

private func dogNearOutline(_ polys: [[(Double, Double)]], _ x: Double, _ y: Double, _ r: Double) -> Bool {
    for poly in polys {
        let n = poly.count
        for k in 0..<n {
            let a = poly[k], b = poly[(k + 1) % n]
            let dx = b.0 - a.0, dy = b.1 - a.1
            let l2 = max(dx * dx + dy * dy, 1e-12)
            let t = max(0, min(1, ((x - a.0) * dx + (y - a.1) * dy) / l2))
            let qx = a.0 + t * dx - x, qy = a.1 + t * dy - y
            if qx * qx + qy * qy <= r * r { return true }
        }
    }
    return false
}

/// 1x alpha grid of a menu icon, following the rules of MenuIconRenderer (Sources/App/DogShapes.swift).
func dogMenuGrid(_ posture: MenuPosture, badge: HealthItem?) -> [[Double]] {
    let w = Int(DogArt.menuSize.w), h = Int(DogArt.menuSize.h)
    var a = Array(repeating: Array(repeating: 0.0, count: w), count: h)
    func over(_ c: [[Double]]) { for y in 0..<h { for x in 0..<w { a[y][x] = c[y][x] + a[y][x] * (1 - c[y][x]) } } }
    func clear(_ c: [[Double]]) { for y in 0..<h { for x in 0..<w { a[y][x] *= (1 - c[y][x]) } } }
    if posture == .hollow {
        // Inner ring of the silhouette (stroke 3 pt clipped to the head = 1.5 pt inside), then the face dots solid.
        for part in DogArt.menuHead(posture) where part.role == .fur {
            over(dogCoverage(dogPolygons(part.ops), w: w, h: h, stroke: 2 * 1.5, insideOnly: true))
        }
        for part in DogArt.menuHead(posture) where part.role == .cutout { over(dogCoverage(dogPolygons(part.ops), w: w, h: h)) }
    } else {
        for part in DogArt.menuHead(posture) {
            let polys = dogPolygons(part.ops)
            if part.role == .tongue {
                // Round 3: a clear ring around the tongue, then the tongue at 55 % alpha.
                clear(dogCoverage(polys, w: w, h: h, stroke: 1.5))
                over(dogCoverage(polys, w: w, h: h).map { $0.map { $0 * DogArt.menuTongueAlpha } })
            } else if part.role == .cutout {
                clear(dogCoverage(polys, w: w, h: h))
            } else {
                over(dogCoverage(polys, w: w, h: h))
            }
        }
    }
    if let badge, posture == .pant {
        // Round 3: red level, the 9 x 9 pt disc at x 15 to 24 with the glyph cleared out of it.
        let o = DogArt.alarmOrigin
        for part in DogArt.alarmDisc { over(dogCoverage(dogPolygons(part.ops) { ($0 + o.x, $1 + o.y) }, w: w, h: h)) }
        for part in DogArt.alarmBadge(badge) { clear(dogCoverage(dogPolygons(part.ops) { ($0 + o.x, $1 + o.y) }, w: w, h: h)) }
    } else if let badge {
        // No cutout: the badge box (x 16 to 24) never touches the head (x 0 to 16).
        let o = DogArt.menuBadgeOrigin
        for part in DogArt.badge(badge) {
            over(dogCoverage(dogPolygons(part.ops) { ($0 + o.x, $1 + o.y) }, w: w, h: h))
        }
    }
    return a
}

/// 1x alpha grid of one alarm disc (9 x 9 pt): the disc minus the knockout.
func dogAlarmGrid(_ item: HealthItem) -> [[Double]] {
    let side = Int(DogArt.alarmSize)
    let disc = dogCoverage(dogPolygons(DogArt.alarmDisc.flatMap { $0.ops }), w: side, h: side)
    let cut = dogCoverage(dogPolygons(DogArt.alarmBadge(item).flatMap { $0.ops }), w: side, h: side)
    return (0..<side).map { y in (0..<side).map { x in disc[y][x] * (1 - cut[y][x]) } }
}

/// Card frame polygons in card units (u), with the frame transforms applied. Roles in `skip` are left out.
private func dogCardPolygons(_ layers: [DogLayer], skip: Set<DogPartRole> = [.shadow, .effect]) -> [[(Double, Double)]] {
    layers.filter { !skip.contains($0.part.role) }.flatMap { l in dogPolygons(l.part.ops) { l.transform.apply($0, $1) } }
}

/// 1x alpha grid of a static card frame at `width` pt (fills only; the outline adds about 1 u around the fur).
func dogCardGrid(_ gait: DogGait, _ input: DogInput, width: Int = 72) -> [[Double]] {
    let k = Double(width) / DogArt.designSize.w
    let h = Int((DogArt.designSize.h * k).rounded())
    let pose = DogMotor.staticPose(gait: gait, input: input)
    let polys = dogCardPolygons(DogRig.layers(gait: gait, pose: pose)).map { $0.map { ($0.0 * k, $0.1 * k) } }
    return dogCoverage(polys, w: width, h: h, ss: 4)
}

func dogBadgeGrid(_ item: HealthItem) -> [[Double]] {
    let ops = DogArt.badge(item).flatMap { $0.ops }
    let side = Int(DogArt.badgeSize)
    return dogCoverage(dogPolygons(ops), w: side, h: side)
}

// MARK: - Helpers

private func dogPoints(_ ops: [DogPathOp]) -> [(Double, Double)] {
    var pts = [(Double, Double)]()
    for op in ops {
        switch op {
        case let .move(x, y), let .line(x, y): pts.append((x, y))
        case let .cubic(a, b, c, d, e, f): pts += [(a, b), (c, d), (e, f)]
        case .close: break
        }
    }
    return pts
}

/// Every subpath starts with move and ends with close.
private func dogClosed(_ ops: [DogPathOp]) -> Bool {
    guard case .move = ops.first, ops.last == .close else { return false }
    for (i, op) in ops.enumerated() where i > 0 {
        if case .move = op, ops[i - 1] != .close { return false }
    }
    return true
}

private func dogInput(cpu: Double?, thermal: ThermalLevel? = .nominal, memory: HealthLevel = .green,
                      worst: HealthItem? = nil, level: HealthLevel = .green, isStatic: Bool = false) -> DogInput {
    DogInput(cpuPercent: cpu, thermal: thermal, memoryLevel: memory, worstProblem: worst, worstLevel: level, isStatic: isStatic)
}

private func verdict(_ item: HealthItem, _ level: HealthLevel, minutes: Double? = nil, headline: String = "") -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: "x", headline: headline,
                since: minutes.map { now.addingTimeInterval(-$0 * 60) }, levelChangedAt: nil, alert: nil)
}

// MARK: - Tests

func runDogTests() {
    section("DogArt data")
    let required: [DogBasePose: [String]] = [
        .stand: ["shadow", "body", "tail", "head", "head.ear", "head.eyeNear", "head.eyeFar", "head.nose", "head.mouth"] + DogRig.legNames,
        .trot: ["body", "tail", "head", "head.ear", "head.mouth", "head.tongue"] + DogRig.legNames,
        .pant: ["body", "head", "head.mouth", "head.tongue", "head.tongue.line"] + DogRig.legNames,
        .lie: ["shadow", "body", "tail", "head", "head.ear", "leg.nearFore", "leg.farFore", "leg.nearHind"],
    ]
    var totalOps = 0
    for base in DogBasePose.allCases {
        let parts = DogArt.parts(for: base)
        let names = Set(parts.map { $0.name })
        for n in required[base]! { expect(names.contains(n), "\(base.rawValue) has part \(n)") }
        expect(names.count == parts.count, "\(base.rawValue) part names are unique")
        for p in parts { totalOps += p.ops.count }
    }
    var allCard = DogArt.parts(body: .lie, head: .pant) + DogArt.parts(body: .trot, head: .pant)
    for o in DogOverlay.allCases { allCard += DogArt.overlay(o) }
    // Round 3: no bundle; the heat lines are two short sweat drops beside the back of the head.
    expect(DogOverlay.allCases == [.bubble, .sweat], "overlays are the bubble and the sweat drops only")
    expect(!DogPartRole.allCases.map { $0.rawValue }.contains { $0.hasPrefix("bundle") || $0 == "strap" }, "no bundle roles")
    let drops = DogArt.overlay(.sweat)
    expect(drops.count == 2, "two sweat drops")
    for d in drops {
        let ys = dogPolygons(d.ops).joined().map { $0.1 }, xs = dogPolygons(d.ops).joined().map { $0.0 }
        expect(ys.max()! - ys.min()! <= 6.5 && xs.max()! < 70, "\(d.name) is short (\(ys.max()! - ys.min()!) u) and beside the head, not above it")
    }
    for base in DogBasePose.allCases { allCard += DogArt.parts(for: base) }
    var badClosed = [String](), outside = [String](), tooShort = [String]()
    for p in allCard {
        if !dogClosed(p.ops) { badClosed.append(p.name) }
        if p.ops.count < 4 { tooShort.append(p.name) }
        for (x, y) in dogPoints(p.ops) where x < 0 || x > 120 || y < 0 || y > 90 { outside.append(p.name); break }
    }
    expect(badClosed.isEmpty, "every card path is closed: \(badClosed)")
    expect(outside.isEmpty, "every card point is inside 120 x 90: \(outside)")
    expect(tooShort.isEmpty, "every card part has at least 4 ops: \(tooShort)")
    // Path cache budget (DESIGN.md 4.6): a CGPath element is about 56 bytes; all key poses must stay well under 50 KB.
    expect(totalOps * 56 < 50_000, "key pose path ops fit the 50 KB cache budget (\(totalOps) ops)")
    print("  key pose ops: \(totalOps)")
    expect(DogArt.ops("M 1 2 L 3 4 C 5 6 7 8 9 10 Z") == [.move(1, 2), .line(3, 4), .cubic(5, 6, 7, 8, 9, 10), .close], "path data decoder")

    var menuBad = [String]()
    for posture in MenuPosture.allCases {
        for p in DogArt.menuHead(posture) {
            if !dogClosed(p.ops) { menuBad.append("\(posture.rawValue).\(p.name) open") }
            // Round 2: the whole head, ears and tongue included, stays left of the badge box (the drawn curve,
            // not the control points). Round 3: the raised head tilts and may reach x 16; the pant head stays
            // left of the alarm disc (x 15).
            let right = posture == .raised ? DogArt.menuRaisedWidth : DogArt.menuHeadWidth
            for (x, y) in dogPolygons(p.ops).joined() where x < 0 || x > right || y < 0 || y > 18 {
                menuBad.append("\(posture.rawValue).\(p.name) outside"); break
            }
        }
    }
    for item in HealthItem.allCases {
        for p in DogArt.badge(item) {
            if !dogClosed(p.ops) { menuBad.append("badge \(item.rawValue) open") }
            for (x, y) in dogPoints(p.ops) where x < 0 || x > DogArt.badgeSize || y < 0 || y > DogArt.badgeSize {
                menuBad.append("badge \(item.rawValue) outside"); break
            }
        }
        expect(!DogArt.badge(item).isEmpty && DogArt.badge(item).count <= 2, "badge \(item.rawValue) has 1 or 2 features")
        for p in DogArt.alarmBadge(item) {
            if !dogClosed(p.ops) || p.role != .cutout { menuBad.append("alarm \(item.rawValue) open or not a cutout") }
            for (x, y) in dogPoints(p.ops) where x < 0 || x > DogArt.alarmSize || y < 0 || y > DogArt.alarmSize {
                menuBad.append("alarm \(item.rawValue) outside"); break
            }
        }
    }
    for (x, y) in dogPolygons(DogArt.alarmDisc[0].ops).joined() where x < -1e-9 || x > DogArt.alarmSize + 1e-9 || y < -1e-9 || y > DogArt.alarmSize + 1e-9 {
        menuBad.append("alarm disc outside \(x),\(y)"); break
    }
    expect(DogArt.alarmOrigin.x >= DogArt.menuHeadWidth && DogArt.alarmOrigin.x + DogArt.alarmSize <= DogArt.menuSize.w
           && DogArt.alarmOrigin.y + DogArt.alarmSize <= DogArt.menuSize.h, "the alarm disc sits right of the pant head, inside 24 x 18")
    expect(menuBad.isEmpty, "menu head and badge paths are closed and inside their boxes: \(menuBad)")
    expect(DogArt.menuHead(.relaxed) != DogArt.menuHead(.raised) && DogArt.menuHead(.raised) != DogArt.menuHead(.pant), "the 3 postures have different art")

    section("Menu icon 1x metric (software raster)")
    let postures: [MenuPosture] = [.relaxed, .raised, .pant]
    let pGrids = postures.map { ($0.rawValue, dogMenuGrid($0, badge: nil)) }
    let pm = IconMetrics.matrix(pGrids)
    for (k, v) in pm.pairs.sorted(by: { $0.key < $1.key }) { print("  posture \(k): \(String(format: "%.3f", v))") }
    expect(pm.minimum >= IconMetrics.posturePass, "postures differ by XOR >= 0.20 at 1x (min \(String(format: "%.3f", pm.minimum)))")
    for (name, grid) in pGrids {
        // Pixels under the three face cutouts: eyes (5, 8) and (9, 8), nose (7, 11); the pant nose sits 1 pt higher;
        // the raised face moves 1 pt right with the tilt (round 3).
        let dx = name == "raised" ? 1 : 0
        for (cx, cy) in [(5 + dx, 8), (9 + dx, 8), (7 + dx, name == "pant" ? 10 : 11)] {
            expect(grid[cy][cx] < 0.02, "\(name): face cutout pixel (\(cx), \(cy)) is fully clear (alpha \(grid[cy][cx]))")
        }
    }
    let relaxedRaised = IconMetrics.xorRatio(pGrids[0].1, pGrids[1].1)
    expect(relaxedRaised >= IconMetrics.relaxedRaisedPass,
           "relaxed and raised differ by XOR >= 0.25 at 1x (\(String(format: "%.3f", relaxedRaised)))")
    let hollow = dogMenuGrid(.hollow, badge: nil)
    let hollowInk = hollow.joined().filter { $0 >= 0.5 }.count
    let filledInk = pGrids[0].1.joined().filter { $0 >= 0.5 }.count
    expect(hollowInk > 40 && hollowInk * 10 < filledInk * 6, "hollow is a ring, lighter than the filled head (\(hollowInk) of \(filledInk) solid pixels)")
    let bGrids = HealthItem.allCases.map { ($0.rawValue, dogBadgeGrid($0)) }
    let bm = IconMetrics.matrix(bGrids)
    for (k, v) in bm.pairs.sorted(by: { $0.key < $1.key }) { print("  badge \(k): \(String(format: "%.3f", v))") }
    expect(bm.minimum >= IconMetrics.badgePass, "badge glyphs differ by XOR >= 0.35 at 1x (min \(String(format: "%.3f", bm.minimum)))")
    // Round 3: the stems of the thermometer and the strokes of the bolt are at least 2 px wide at 1x.
    let thermal = dogBadgeGrid(.thermal), power = dogBadgeGrid(.power)
    let stemRows = (0..<4).map { y in thermal[y].filter { $0 >= 0.5 }.count }
    let boltRows = (0..<8).map { y in power[y].filter { $0 >= 0.5 }.count }
    expect(stemRows.allSatisfy { $0 >= 2 } && boltRows.allSatisfy { $0 >= 2 }, "thermometer stem and bolt strokes are >= 2 px at 1x (\(stemRows), \(boltRows))")
    let aGrids = HealthItem.allCases.map { ($0.rawValue, dogAlarmGrid($0)) }
    let am = IconMetrics.matrix(aGrids)
    for (k, v) in am.pairs.sorted(by: { $0.key < $1.key }) { print("  alarm \(k): \(String(format: "%.3f", v))") }
    expect(am.minimum >= IconMetrics.alarmPass, "alarm discs differ by XOR >= 0.30 at 1x (min \(String(format: "%.3f", am.minimum)))")
    // The alarm disc is heavier than the yellow glyph: more solid pixels for every item.
    for item in HealthItem.allCases {
        let disc = dogAlarmGrid(item).joined().filter { $0 >= 0.5 }.count
        let glyph = dogBadgeGrid(item).joined().filter { $0 >= 0.5 }.count
        expect(disc > glyph, "\(item.rawValue): the alarm disc (\(disc) px) outweighs the yellow glyph (\(glyph) px)")
    }
    // Round 2: the badge never cuts the head. The head columns are the same with and without a badge:
    // 0 to 15 next to the 8 pt glyph, 0 to 14 next to the 9 pt alarm disc of the pant head (round 3).
    let o = DogArt.menuBadgeOrigin, side = DogArt.badgeSize
    expect(o.x >= DogArt.menuRaisedWidth && o.x + side <= DogArt.menuSize.w && o.y + side <= DogArt.menuSize.h,
           "the badge box sits right of the head, inside 24 x 18")
    var headInBadge = [String]()
    for posture in MenuPosture.allCases {
        let plain = dogMenuGrid(posture, badge: nil)
        let split = posture == .pant ? Int(DogArt.alarmOrigin.x) : Int(o.x)
        for item in HealthItem.allCases {
            let marked = dogMenuGrid(posture, badge: item)
            var same = true, badgeInk = 0
            for y in 0..<18 {
                for x in 0..<split where abs(marked[y][x] - plain[y][x]) > 1e-9 { same = false }
                for x in split..<24 where marked[y][x] >= 0.5 { badgeInk += 1 }
            }
            expect(same, "\(posture.rawValue) + \(item.rawValue): the badge leaves the head untouched")
            expect(badgeInk >= 20, "\(posture.rawValue) + \(item.rawValue): the badge has at least 20 solid pixels (\(badgeInk))")
        }
        for y in 0..<18 { for x in split..<24 where plain[y][x] > 0 { headInBadge.append("\(posture.rawValue) \(x),\(y)") } }
    }
    // Round 3: the pant tongue is lighter than the face and wider than tall.
    let tongue = DogArt.menuPant.first { $0.role == .tongue }!
    let tx = dogPolygons(tongue.ops).joined().map { $0.0 }, ty = dogPolygons(tongue.ops).joined().map { $0.1 }
    expect(tx.max()! - tx.min()! > ty.max()! - ty.min()! && DogArt.menuTongueAlpha <= 0.6,
           "pant tongue is wider than tall and drawn at <= 60 % alpha")
    expect(headInBadge.isEmpty, "no head ink in the badge columns: \(headInBadge)")
    expect(IconMetrics.xorRatio([[1, 0]], [[1, 1]]) == 0.5, "xorRatio: 1 different of max 2 solid")
    expect(IconMetrics.xorRatio([[0.4]], [[0]]) == 0, "xorRatio: alpha below 0.5 is not solid")

    section("Dog gait rules")
    expect(DogGaitRules.nextGait(from: .lie, s: 9.9) == .lie, "lie stays below 10")
    expect(DogGaitRules.nextGait(from: .lie, s: 10) == .walk, "walk enters at 10")
    expect(DogGaitRules.nextGait(from: .walk, s: 7.5) == .walk, "walk holds above 7")
    expect(DogGaitRules.nextGait(from: .walk, s: 6.9) == .lie, "walk leaves below 7")
    expect(DogGaitRules.nextGait(from: .walk, s: 39) == .walk, "trot needs 40")
    expect(DogGaitRules.nextGait(from: .trot, s: 35) == .trot, "trot holds above 34")
    expect(DogGaitRules.nextGait(from: .trot, s: 33) == .walk, "trot leaves below 34")
    expect(DogGaitRules.nextGait(from: .sprint, s: 73) == .sprint, "sprint holds above 72")
    expect(DogGaitRules.nextGait(from: .sprint, s: 71) == .trot, "sprint leaves below 72")
    expect(DogGaitRules.nextGait(from: .lie, s: 90) == .sprint, "a jump up may skip gaits")
    expect(DogGaitRules.nextGait(from: .sprint, s: 3) == .lie, "a drop may skip gaits")
    expect(DogGaitRules.nextGait(from: .stand, s: 50) == .trot, "stand uses the plain bands")
    expect(abs(DogGaitRules.frequency(.walk, s: 10) - 0.8) < 1e-9, "walk starts at 0.8 Hz")
    expect(abs(DogGaitRules.frequency(.walk, s: 25) - 1.1) < 1e-9, "walk at 25 is 1.1 Hz")
    expect(abs(DogGaitRules.frequency(.walk, s: 60) - 1.4) < 1e-9, "walk caps at 1.4 Hz")
    expect(abs(DogGaitRules.frequency(.trot, s: 60) - 2.0) < 1e-9, "trot at 60 is 2.0 Hz")
    expect(abs(DogGaitRules.frequency(.sprint, s: 100) - 3.6) < 1e-9, "sprint at 100 is 3.6 Hz")
    expect(DogGaitRules.frequency(.lie, s: 5) == 0, "lie does not step")

    section("Dog motor")
    var m0 = DogMotor(initialCPU: nil)
    expect(m0.gait == .stand, "no value: stand")
    _ = m0.step(dt: 0.04, input: dogInput(cpu: nil))
    expect(m0.gait == .stand, "still no value: stand")
    _ = m0.step(dt: 0.04, input: dogInput(cpu: 50))
    expect(m0.gait == .trot && abs((m0.smoothed ?? 0) - 50) < 1e-9, "first value sets s and the gait at once")

    var m1 = DogMotor(initialCPU: 0)
    expect(m1.gait == .lie, "initial 0: lie")
    _ = m1.step(dt: 1, input: dogInput(cpu: 100))
    let expected = 100 * (1 - exp(-1.0 / 8))
    expect(abs((m1.smoothed ?? 0) - expected) < 1e-9, "exponential smoothing with tau 8 s")
    var m1b = DogMotor(initialCPU: 76)
    expect(m1b.gait == .trot, "the open value gives the gait at once, no ramp from 0")
    _ = m1b.step(dt: 0.1, input: dogInput(cpu: 76))
    expect(m1b.gait == .trot, "a steady value keeps the gait")

    // Hold and switch budget: a square wave between 0 and 100 every 1.5 s for 60 s.
    var m2 = DogMotor(initialCPU: 0)
    var switches = [Double](), last = m2.gait, t = 0.0
    var maxSlope = 0.0, lastFrequency = m2.frequency
    var maxLegJump = 0.0, lastLegs = m2.step(dt: 0, input: dogInput(cpu: 0)).legAngle
    let dt = 1.0 / 24
    while t < 60 {
        t += dt
        let x: Double = Int(t / 1.5) % 2 == 0 ? 100 : 0
        let pose = m2.step(dt: dt, input: dogInput(cpu: x))
        if m2.gait != last { switches.append(t); last = m2.gait }
        maxSlope = max(maxSlope, abs(m2.frequency - lastFrequency) / dt)
        lastFrequency = m2.frequency
        for i in 0..<4 { maxLegJump = max(maxLegJump, abs(pose.legAngle[i] - lastLegs[i])) }
        lastLegs = pose.legAngle
    }
    let gaps = zip(switches.dropFirst(), switches).map { $0 - $1 }
    expect(gaps.allSatisfy { $0 >= 4 - 1e-9 }, "each gait holds at least 4 s (\(switches.count) switches)")
    var windowOK = true
    for (i, s) in switches.enumerated() where switches[i...].filter({ $0 < s + 10 - 1e-9 }).count > 2 { windowOK = false }
    expect(windowOK, "at most 2 gait switches in any 10 s")
    expect(maxSlope <= 0.6 + 1e-6, "step frequency changes at most 0.6 Hz/s (max \(String(format: "%.3f", maxSlope)))")
    // Natural limit: amplitude x 2 pi x f x dt of the fastest gait, plus 3 degrees for a gait blend. A phase reset would jump up to 80.
    let sprintLimit = 40 * 2 * Double.pi * 3.6 * dt
    expect(maxLegJump < sprintLimit + 3, "gait changes never make a leg jump (max \(String(format: "%.2f", maxLegJump)), limit \(String(format: "%.1f", sprintLimit + 3)))")

    // Steady gaits: phase accumulates; walk stays under 12 degrees per frame (DESIGN.md 9.1); trot and sprint
    // stay within their natural limit amplitude x 2 pi x f x dt (12 degrees is not reachable for them at 24 fps).
    for (cpu, amp, fmax) in [(25.0, 26.0, 1.4), (60.0, 34.0, 2.4), (95.0, 40.0, 3.6)] {
        var m3 = DogMotor(initialCPU: cpu)
        var phaseOK = true, previousPhase = m3.phase, jump3 = 0.0
        var legs3 = m3.step(dt: 0, input: dogInput(cpu: cpu)).legAngle
        for _ in 0..<480 {
            let pose = m3.step(dt: dt, input: dogInput(cpu: cpu))
            if m3.phase <= previousPhase { phaseOK = false }
            previousPhase = m3.phase
            for i in 0..<4 { jump3 = max(jump3, abs(pose.legAngle[i] - legs3[i])) }
            legs3 = pose.legAngle
        }
        let limit = cpu < 40 ? 12 : amp * 2 * Double.pi * fmax * dt * 1.01
        expect(phaseOK, "\(m3.gait.rawValue): phase only grows")
        expect(jump3 < limit, "\(m3.gait.rawValue) at 24 fps: leg change per frame \(String(format: "%.2f", jump3)) < \(String(format: "%.1f", limit))")
    }

    section("Dog static poses and overlays")
    let walk = DogMotor.staticPose(gait: .walk, input: dogInput(cpu: 20))
    let walkSwing = 26 * sin(0.75 * Double.pi)
    expect(abs(walk.legAngle[0] - walkSwing) < 1e-9 && abs(walk.legAngle[2] + walkSwing) < 1e-9, "static walk is the phase pi/2 frame")
    expect(abs(walk.legLift[3] - 11) < 1e-9 && walk.legAngle[3] > 15, "static walk: the near fore paw is 11 u up and forward")
    expect(abs(walk.bodyY + 4) < 1e-9 && abs(walk.earAngle - 10) < 1e-9, "static walk: body up 4 u, ears swing")
    let walkB = DogMotor.staticPose(gait: .walk, input: dogInput(cpu: 20), phase: Double.pi)
    expect(abs(walkB.bodyY) < 1e-9 && walkB.legLift[2] > 10.9, "walk frame B: body down, the near hind paw lifted")
    let trot = DogMotor.staticPose(gait: .trot, input: dogInput(cpu: 60))
    expect(abs(trot.legAngle[3] - 34) < 1e-9 && abs(trot.legAngle[1] + 34) < 1e-9 && trot.bodyPitch == 4,
           "static trot: diagonal pairs at +-34, body leans 4 degrees")
    let sprint = DogMotor.staticPose(gait: .sprint, input: dogInput(cpu: 90))
    expect(sprint.bodyPitch >= 8 && sprint.earAngle < -35, "static sprint: strong lean and ears blown back")
    let sprintLayers = DogRig.layers(gait: .sprint, pose: sprint)
    expect(!sprintLayers.contains { $0.part.name.hasPrefix("speed") }, "sprint has no speed lines")
    let gray = DogMotor.staticPose(gait: .trot, input: dogInput(cpu: 8, isStatic: true))
    expect(gray.opacity == 0.45 && gray.bubble == 0 && gray.legAngle == [0, 0, 0, 0], "collecting or stale: still, gray stand")
    let hot = DogMotor.staticPose(gait: .lie, input: dogInput(cpu: 5, thermal: .serious))
    expect(hot.mouthOpen == 1 && hot.tongue == 8, "thermal serious: pant with the static tongue")
    expect(DogRig.head(for: .lie, pose: hot) == .pant, "pant replaces the head")
    // Round 3: no bundle. Memory red alone does not change the dog; the bubble and the menu alarm disc show it.
    let heavy = DogMotor.staticPose(gait: .walk, input: dogInput(cpu: 20, memory: .red))
    expect(heavy == walk, "memory red alone: the same walk, no bundle, no slower steps")
    let heavyLayers = DogRig.layers(gait: .walk, pose: DogMotor.staticPose(gait: .walk, input: dogInput(cpu: 20, memory: .red, worst: .memory, level: .red)),
                                    glyph: DogArt.badge(.memory))
    expect(!heavyLayers.contains { $0.part.name.hasPrefix("bundle") } && heavyLayers.contains { $0.part.name == "bubble.main" },
           "memory red problem: the bubble with the memory glyph, no bundle")
    let worried = DogMotor.staticPose(gait: .lie, input: dogInput(cpu: 5, worst: .disk, level: .yellow))
    expect(worried.bubble == 1 && worried.earAngle == -25 && worried.headTilt == 8, "any problem: bubble, ears up, head tilt")
    let lieLayers = DogRig.layers(gait: .lie, pose: DogMotor.staticPose(gait: .lie, input: dogInput(cpu: 2)))
    expect(lieLayers.count == DogArt.parts(for: .lie).count, "lie frame draws every lie part once")
    let bubbleLayers = DogRig.layers(gait: .stand, pose: worried, glyph: DogArt.badge(.disk))
    expect(bubbleLayers.contains { $0.part.name.hasPrefix("glyph.") } && bubbleLayers.contains { $0.part.name == "bubble.main" },
           "attention frame has the bubble and the glyph")
    let hotLayers = DogRig.layers(gait: .stand, pose: DogMotor.staticPose(gait: .stand, input: dogInput(cpu: nil, thermal: .serious)))
    expect(hotLayers.filter { $0.part.role == .effect }.count == 2 && !hotLayers.contains { $0.part.name.hasPrefix("fx.heat") },
           "pant: two sweat drops, no heat lines")

    section("Card 72 pt legs and bubble (software raster)")
    let k72 = 72.0 / DogArt.designSize.w
    let legGaits: [(String, DogGait, DogInput)] = [("stand", .stand, dogInput(cpu: nil)), ("walk", .walk, dogInput(cpu: 25)),
                                                   ("trot", .trot, dogInput(cpu: 60))]
    let legGrids = legGaits.map { ($0.0, dogCardGrid($0.1, $0.2)) }
    for i in 0..<3 {
        for j in (i + 1)..<3 {
            let r = IconMetrics.bandRatio(legGrids[i].1, legGrids[j].1, rows: IconMetrics.cardLegRows)
            print("  legs \(legGrids[i].0)/\(legGrids[j].0): \(String(format: "%.3f", r))")
            expect(r >= IconMetrics.cardLegPass, "72 pt: \(legGrids[i].0) and \(legGrids[j].0) legs differ by XOR >= 0.30 (\(String(format: "%.3f", r)))")
        }
    }
    for (name, gait, input) in legGaits.dropFirst() {
        let pose = DogMotor.staticPose(gait: gait, input: input)
        var lifted = -Double.infinity, planted = [Double]()
        for l in DogRig.layers(gait: gait, pose: pose) where DogRig.legNames.contains(l.part.name) {
            let bottom = dogPolygons(l.part.ops) { l.transform.apply($0, $1) }.joined().map { $0.1 }.max()!
            let up = (DogArt.groundY - bottom) * k72
            lifted = max(lifted, up)
            if l.part.role == .fur, up < 1 { planted.append(up) }
        }
        print("  \(name) paw lift: \(String(format: "%.2f", lifted)) px")
        expect(lifted >= IconMetrics.pawLiftPx, "72 pt: the \(name) paw lifts >= 6 px (\(String(format: "%.2f", lifted)))")
        expect(!planted.isEmpty && planted.allSatisfy { abs($0) < 0.5 }, "\(name): the near planted paw stays on the ground (\(planted))")
        let ys = (0..<32).map { DogMotor.staticPose(gait: gait, input: input, phase: Double($0) * Double.pi / 16).bodyY }
        expect((ys.max()! - ys.min()!) * k72 >= IconMetrics.bobPx, "\(name): the body bobs >= 2 px at 72 pt")
    }
    let bc = DogArt.bubbleCircle, half = 1.1
    expect((2 * bc.r + 2 * half) * k72 >= IconMetrics.bubbleMinPx && bc.x + bc.r + half <= 120 && bc.y - bc.r - half >= -0.5,
           "the bubble is >= 14 px at 72 pt, in the top right corner")
    var worstGap = Double.infinity, worstDot = Double.infinity
    let dotPts = dogPolygons(DogArt.bubble.first { $0.name == "bubble.tail1" }!.ops).joined()
    let dotX = (dotPts.map { $0.0 }.max()! + dotPts.map { $0.0 }.min()!) / 2, dotY = (dotPts.map { $0.1 }.max()! + dotPts.map { $0.1 }.min()!) / 2
    let dotR = (dotPts.map { $0.0 }.max()! - dotPts.map { $0.0 }.min()!) / 2
    for (gait, input) in [(DogGait.lie, dogInput(cpu: 3, worst: .disk, level: .yellow)), (.stand, dogInput(cpu: nil, worst: .disk, level: .yellow)),
                          (.walk, dogInput(cpu: 25, worst: .memory, level: .red)), (.trot, dogInput(cpu: 60, worst: .cpu, level: .yellow)),
                          (.sprint, dogInput(cpu: 95, worst: .cpu, level: .red)),
                          (.stand, dogInput(cpu: nil, thermal: .critical, worst: .thermal, level: .red))] {
        for step in 0..<8 {
            let pose = DogMotor.staticPose(gait: gait, input: input, phase: Double(step) * Double.pi / 4)
            let layers = DogRig.layers(gait: gait, pose: pose).filter { !$0.part.name.hasPrefix("bubble.") }
            for (x, y) in dogCardPolygons(layers, skip: [.shadow]).joined() {
                // Fur outline (1.1 u) and bubble outline (1.1 u) both count.
                let d = ((x - bc.x) * (x - bc.x) + (y - bc.y) * (y - bc.y)).squareRoot() - bc.r - 2 * half
                worstGap = min(worstGap, d * k72)
                let e = ((x - dotX) * (x - dotX) + (y - dotY) * (y - dotY)).squareRoot() - dotR - 2 * half
                worstDot = min(worstDot, e * k72)
            }
        }
    }
    print("  bubble gap: \(String(format: "%.2f", worstGap)) px, tail dot gap: \(String(format: "%.2f", worstDot)) px")
    expect(worstDot >= IconMetrics.bubbleGapPx, "the bubble tail dot keeps >= 2 px off the fur at 72 pt (\(String(format: "%.2f", worstDot)))")
    expect(worstGap >= IconMetrics.bubbleGapPx, "the bubble keeps >= 2 px off the fur at 72 pt (\(String(format: "%.2f", worstGap)))")

    section("Dog affine")
    let r = DogAffine.rotate(90, about: (0, 0)).apply(1, 0)
    expect(abs(r.x) < 1e-9 && abs(r.y - 1) < 1e-9, "positive rotation turns clockwise on a y-down screen")
    let chain = DogAffine.translate(1, 0).then(.scale(2, 2, about: (0, 0))).apply(1, 1)
    expect(chain.x == 4 && chain.y == 2, "then() applies left first")

    section("Dog fixtures")
    let fixtureGait: [PreviewCase: DogGait] = [.allGreen: .lie, .cpuYellow: .trot, .diskRed: .walk, .powerYellow: .walk,
                                               .multi: .trot, .collecting: .stand, .stale: .stand]
    for c in PreviewCase.allCases {
        let input = PreviewScenario.fixture(c, full: false, now: now).dogInput
        expect(DogMotor.staticGait(for: input) == fixtureGait[c], "\(c.rawValue): static gait \(fixtureGait[c]!.rawValue)")
    }

    section("Menu icon model")
    let green = [verdict(.thermal, .green), verdict(.memory, .green), verdict(.disk, .green), verdict(.power, .green), verdict(.cpu, .green)]
    expect(MenuIconModel.state(green, dataState: .fresh) == MenuIconState(posture: .relaxed, badge: nil), "all green: relaxed, no badge")
    expect(MenuIconModel.state(green, dataState: .collecting).posture == .hollow, "collecting: hollow")
    expect(MenuIconModel.state(green, dataState: .stale(now)) == MenuIconState(posture: .hollow, badge: nil), "stale: hollow, no badge")
    let cpuY = [verdict(.cpu, .yellow, minutes: 40)] + green.filter { $0.item != .cpu }
    expect(MenuIconModel.state(cpuY, dataState: .fresh) == MenuIconState(posture: .raised, badge: MenuBadge(item: .cpu)), "yellow: raised + category")
    let diskR = [verdict(.disk, .red, minutes: 192, headline: "5 天多占用 314 GB")] + green.filter { $0.item != .disk }
    expect(MenuIconModel.state(diskR, dataState: .fresh) == MenuIconState(posture: .pant, badge: MenuBadge(item: .disk)), "red: pant + category")
    let diskY = [verdict(.disk, .yellow, minutes: 10)] + green.filter { $0.item != .disk }
    expect(MenuIconModel.state(diskY, dataState: .fresh).badge == MenuIconModel.state(diskR, dataState: .fresh).badge, "the badge does not show the level")
    let multi = PreviewScenario.fixture(.multi, full: false, now: now)
    let first = ProblemOrder.problems(multi.verdicts).first!.item
    expect(MenuIconModel.state(multi.verdicts, dataState: .fresh).badge == MenuBadge(item: first), "many problems: the first problem gives the badge")
    expect(MenuIconModel.text(green, dataState: .fresh, now: now) == "MoleMonitor：一切正常。温度、内存、磁盘、耗电、CPU 正常。", "text: all normal")
    expect(MenuIconModel.text(diskR, dataState: .fresh, now: now) == "MoleMonitor：磁盘异常，5 天多占用 314 GB，已持续 3 小时 12 分。温度、内存、耗电、CPU 正常。", "text: one problem")
    let two = [verdict(.disk, .red, minutes: 192), verdict(.cpu, .yellow, minutes: 40)] + green.filter { $0.item != .disk && $0.item != .cpu }
    expect(MenuIconModel.text(two, dataState: .fresh, now: now) == "MoleMonitor：2 项需要处理。磁盘异常，已持续 3 小时 12 分。CPU 需留意，已持续 40 分。温度、内存、耗电正常。", "text: two problems in order")
    let desktop = green.filter { $0.item != .power } + [verdict(.power, .notApplicable)]
    expect(!MenuIconModel.text(desktop, dataState: .fresh, now: now).contains("耗电"), "text: no power item on a desktop")
    expect(MenuIconModel.text(green, dataState: .collecting, now: now) == "MoleMonitor：正在统计。", "text: collecting")
    expect(MenuIconModel.text(green, dataState: .stale(now), now: now).hasPrefix("MoleMonitor：数据已过期，最后数据 "), "text: stale")
    expect(MenuIconModel.duration(30) == "不到 1 分" && MenuIconModel.duration(25 * 60) == "25 分", "duration: minutes")
    expect(MenuIconModel.duration(26 * 3600) == "1 天 2 小时" && MenuIconModel.duration(7200) == "2 小时", "duration: hours and days")
}
