// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: An output directory from `--dog-gallery <directory>` (docs/DESIGN.md 4.8, 8.5).
// Output: PNG gallery of all static dog poses, menu bar icons and badges (1x and 2x, light and dark), contact sheets,
//         a menu bar mock-up with 8x pixel zoom, manifest.json (file names and pixel hashes), badge-matrix.json,
//         menu-metrics.json and card-metrics.json (measured on the real Core Graphics raster, DESIGN.md 3.3, 4.8, 9.4 G1).
//         Stage 2: stride sequences (sheet-seq.png), the motor timeline of a switch (sheet-timeline.png), the menu bar
//         switch frames (sheet-menu-switch.png) and menu-switch.json (every switch has 8 frames, the last one = the still).
//         In the UITEST build, `--dog-checks` runs the dog animation gates instead (UITestDogChecks).
//         v2 (WP-E, DESIGN_V2.md 9, gate W08): the five menu bar states in menu5/ (5 states x 6 bars x 1x and 2x),
//         sheet-menu-five.png (real size, 2x vector, 1x pixels zoomed, a grayscale row), and in badge-matrix.json the
//         five-state XOR matrix, the data mark glyph matrix and the badge contrast table.
// Pos: Review and CI tool; the app never calls it at run time. Offline, no network. Owner WP-E (menu bar part).
//
// Self-check: returns an error when two different poses give the same pixels, or when a 1x metric fails its gate.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum DogGallery {
    // MARK: Content

    struct CardPose {
        var name: String
        var gait: DogGait
        var input: DogInput
        /// Stride phase (radians). The default pi / 2 is the key frame the card shows.
        var phase: Double = Double.pi / 2
    }

    static func input(cpu: Double? = 5, thermal: ThermalLevel = .nominal, memory: HealthLevel = .green,
                      problem: HealthItem? = nil, level: HealthLevel = .green, isStatic: Bool = false) -> DogInput {
        DogInput(cpuPercent: cpu, thermal: thermal, memoryLevel: memory, worstProblem: problem,
                 worstLevel: level, isStatic: isStatic)
    }

    /// The card poses of DESIGN.md 4.4 and 4.8: key poses, gaits, overlays, gray.
    static var cardPoses: [CardPose] {
        [
            CardPose(name: "lie", gait: .lie, input: input(cpu: 3)),
            CardPose(name: "stand", gait: .stand, input: input()),
            CardPose(name: "walk", gait: .walk, input: input(cpu: 25)),
            CardPose(name: "walk-a", gait: .walk, input: input(cpu: 25), phase: Double.pi),
            CardPose(name: "walk-b", gait: .walk, input: input(cpu: 25), phase: Double.pi * 1.5),
            CardPose(name: "trot", gait: .trot, input: input(cpu: 60)),
            CardPose(name: "trot-a", gait: .trot, input: input(cpu: 60), phase: 0),
            CardPose(name: "trot-b", gait: .trot, input: input(cpu: 60), phase: Double.pi * 1.5),
            CardPose(name: "sprint", gait: .sprint, input: input(cpu: 95)),
            CardPose(name: "pant", gait: .stand, input: input(thermal: .serious)),
            // Round 3: no bundle. Memory red is the walk with the bubble (red memory glyph) and the menu alarm disc.
            CardPose(name: "memory-red", gait: .walk, input: input(cpu: 25, memory: .red, problem: .memory, level: .red)),
            CardPose(name: "attention", gait: .stand, input: input(problem: .disk, level: .yellow)),
            CardPose(name: "alarm", gait: .stand, input: input(thermal: .critical, problem: .thermal, level: .red)),
            CardPose(name: "gray", gait: .stand, input: input(cpu: nil, isStatic: true)),
        ]
    }

    static let cardSizes: [CGSize] = [CGSize(width: 104, height: 78), CGSize(width: 72, height: 54)]
    static let cardBackground: [Bool: UInt32] = [false: 0xECECEC, true: 0x2A2A2C]
    /// Menu bar backgrounds and the ink the system gives a template image there (approximate).
    static let barBackground: [Bool: UInt32] = [false: 0xF2F2F2, true: 0x252527]
    static func barInk(_ dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    }

    static var menuStates: [(name: String, state: MenuIconState, style: GlyphStyle)] {
        var out = [(name: String, state: MenuIconState, style: GlyphStyle)]()
        for mark in MenuMark.allCases {
            out.append(("hollow-" + mark.rawValue, MenuIconState(posture: .hollow, badge: nil, mark: mark), .glyph))
        }
        for posture in MenuPosture.allCases {
            out.append((posture.rawValue + "-none", MenuIconState(posture: posture, badge: nil), .glyph))
            for style in GlyphStyle.allCases {
                for item in HealthItem.allCases {
                    let name = posture.rawValue + "-" + item.rawValue + "-" + style.rawValue
                    out.append((name, MenuIconState(posture: posture, badge: MenuBadge(item: item)), style))
                }
            }
        }
        return out
    }

    // MARK: Output state

    private static var manifest = [[String: Any]]()
    private static var root = URL(fileURLWithPath: "/")
    private static var failures = [String]()

    /// Renders the gallery into `dir`. Returns an error text, or nil on success.
    static func render(to dir: URL) -> String? {
        root = dir
        manifest = []
        failures = []
        groups = [:]
        let fm = FileManager.default
        for sub in ["card", "menu", "badge"] {
            do {
                try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            } catch {
                return "Cannot create the gallery directory."
            }
        }
        renderCards()
        renderDogView()
        renderMenu()
        renderBadges()
        let choice = writeMetrics()
        writeCardMetrics()
        sheetCard()
        sheetMenu(.glyph)
        sheetMenu(.letter)
        sheetBadges()
        menubarMock(choice)
        renderFiveStates(choice)
        sheetFiveStates(choice)
        // Stage 2 (animation): stride sequences, the motor timeline of a switch, the menu bar switch frames.
        renderSequences()
        sheetSequences()
        sheetTimeline()
        sheetMenuSwitch(choice)
        checkMenuSwitchFrames(choice)
        checkGrayInk()
        writeJSON(["files": manifest, "glyphStyle": choice.rawValue], "manifest.json")
        checkDistinct()
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: Single images

    private static func renderCards() {
        for pose in cardPoses {
            for size in cardSizes {
                for dark in [false, true] {
                    for scale in [1, 2] {
                        let name = "card/\(pose.name)-\(Int(size.width))-\(dark ? "dark" : "light")@\(scale)x.png"
                        let image = draw(size, scale: scale, background: cardBackground[dark]) { ctx in
                            DogRenderer.drawStatic(pose.input, gait: pose.gait, phase: pose.phase, dark: dark,
                                                   in: CGRect(origin: .zero, size: size), ctx: ctx)
                        }
                        save(image, name, group: "card-\(Int(size.width))-\(dark)-\(scale)")
                    }
                }
            }
        }
    }

    /// The real SwiftUI path (DogView in ImageRenderer), to check that Canvas draws the same dog. Not hash-checked.
    private static func renderDogView() {
        // The gallery judges the vector dog: the bitmap switch is off while it renders (docs/DESIGN.md 4.9).
        let savedBitmap = DogView.useBitmapArt
        DogView.useBitmapArt = false
        defer { DogView.useBitmapArt = savedBitmap }
        for dark in [false, true] {
            let size = cardSizes[0]
            let back = Color(cgColor: rgb(cardBackground[dark] ?? 0))
            let view = DogView(input: input(cpu: 60), size: size)
                .background(back)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let name = "card/dogview-trot-104-\(dark ? "dark" : "light")@2x.png"
            if let image = renderer.cgImage {
                save(image, name, group: nil)
            } else {
                manifest.append(["file": name, "hash": "none", "note": "ImageRenderer returned no image"])
            }
        }
    }

    private static func renderMenu() {
        let size = MenuIconRenderer.size
        for entry in menuStates {
            for dark in [false, true] {
                for scale in [1, 2] {
                    let name = "menu/\(entry.name)-\(dark ? "dark" : "light")@\(scale)x.png"
                    let image = draw(size, scale: scale, background: barBackground[dark]) { ctx in
                        MenuIconRenderer.draw(entry.state, style: entry.style, ink: menuInk(entry.state, dark: dark), in: ctx)
                    }
                    save(image, name, group: "menu-\(dark)-\(scale)")
                }
            }
        }
    }

    private static func renderBadges() {
        let size = CGSize(width: DogArt.badgeSize, height: DogArt.badgeSize)
        for style in GlyphStyle.allCases {
            for item in HealthItem.allCases {
                for scale in [1, 2] {
                    let image = draw(size, scale: scale, background: barBackground[false]) { ctx in
                        ctx.setFillColor(barInk(false))
                        ctx.addPath(GlyphPaths.badgeYDown(item, style: style))
                        ctx.fillPath()
                    }
                    save(image, "badge/\(style.rawValue)-\(item.rawValue)@\(scale)x.png", group: "badge-\(scale)")
                    let disc = draw(alarmSize, scale: scale, background: barBackground[false]) { ctx in
                        drawAlarm(item, style: style, ink: barInk(false), in: ctx)
                    }
                    save(disc, "badge/alarm-\(style.rawValue)-\(item.rawValue)@\(scale)x.png", group: "alarm-\(scale)")
                }
            }
        }
    }

    static let alarmSize = CGSize(width: DogArt.alarmSize, height: DogArt.alarmSize)

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

    // MARK: Metrics (1x, Core Graphics raster)

    /// Alpha grid of a 1x render on a transparent background, y down, row 0 at the top.
    static func alphaGrid(_ size: CGSize, _ body: (CGContext) -> Void) -> [[Double]] {
        let w = Int(size.width), h = Int(size.height)
        guard let image = draw(size, scale: 1, background: nil, body),
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

    static func menuGrid(_ state: MenuIconState, style: GlyphStyle = .glyph) -> [[Double]] {
        alphaGrid(MenuIconRenderer.size) { ctx in
            MenuIconRenderer.draw(state, style: style, ink: CGColor(gray: 0, alpha: 1), in: ctx)
        }
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

    static func solidCount(_ g: [[Double]]) -> Int {
        var n = 0
        for row in g {
            for v in row where v >= IconMetrics.solidThreshold { n += 1 }
        }
        return n
    }

    static func rounded(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Writes badge-matrix.json and menu-metrics.json. Returns the badge style that passes (glyph first).
    private static func writeMetrics() -> GlyphStyle {
        var badgeJSON = [String: Any]()
        var passing = [GlyphStyle]()
        for style in GlyphStyle.allCases {
            let grids = HealthItem.allCases.map { ($0.rawValue, badgeGrid($0, style: style)) }
            let m = IconMetrics.matrix(grids)
            let pass = m.minimum >= IconMetrics.badgePass
            if pass { passing.append(style) }
            var solid = [String: Int]()
            for (name, grid) in grids { solid[name] = solidCount(grid) }
            var entry = [String: Any]()
            entry["pairs"] = m.pairs.mapValues(rounded)
            entry["minimum"] = rounded(m.minimum)
            entry["pass"] = pass
            entry["solidPixels"] = solid
            badgeJSON[style.rawValue] = entry
        }
        let choice: GlyphStyle = passing.first ?? .glyph
        badgeJSON["threshold"] = IconMetrics.badgePass
        // Round 3: the alarm discs (red level). Gate on the glyph style; the letter style is recorded only.
        var alarmJSON = [String: Any]()
        for style in GlyphStyle.allCases {
            let grids = HealthItem.allCases.map { ($0.rawValue, alarmGrid($0, style: style)) }
            let m = IconMetrics.matrix(grids)
            var solid = [String: Int]()
            for (name, grid) in grids { solid[name] = solidCount(grid) }
            alarmJSON[style.rawValue] = ["pairs": m.pairs.mapValues(rounded), "minimum": rounded(m.minimum),
                                         "pass": m.minimum >= IconMetrics.alarmPass, "solidPixels": solid] as [String: Any]
            if style == .glyph, m.minimum < IconMetrics.alarmPass {
                failures.append("Alarm gate: minimum XOR \(rounded(m.minimum)) < \(IconMetrics.alarmPass) at 1x.")
            }
        }
        alarmJSON["threshold"] = IconMetrics.alarmPass
        badgeJSON["alarm"] = alarmJSON
        badgeJSON["choice"] = choice.rawValue
        badgeJSON["codeChoice"] = GlyphPaths.chosen.rawValue
        for (key, value) in fiveStateMetrics(choice) { badgeJSON[key] = value }
        writeJSON(badgeJSON, "badge-matrix.json")
        if passing.isEmpty { failures.append("Badge gate: neither glyphs nor letters reach \(IconMetrics.badgePass) at 1x.") }
        if !passing.contains(GlyphPaths.chosen) {
            failures.append("Badge gate: GlyphPaths.chosen = \(GlyphPaths.chosen.rawValue) does not pass at 1x.")
        }

        // Postures: outer silhouette must change (G1-4); face cutouts must be clear; hollow must be light.
        let postures: [MenuPosture] = [.relaxed, .raised, .pant]
        let grids = postures.map { ($0.rawValue, menuGrid(MenuIconState(posture: $0, badge: nil))) }
        let m = IconMetrics.matrix(grids)
        if m.minimum < IconMetrics.posturePass {
            failures.append("Posture gate: minimum XOR \(rounded(m.minimum)) < \(IconMetrics.posturePass).")
        }
        let relaxed = grids[0].1
        // Round 2: relaxed and raised must differ more than the general gate, so that "attention" reads at 1x.
        let relaxedRaised = IconMetrics.xorRatio(grids[0].1, grids[1].1)
        if relaxedRaised < IconMetrics.relaxedRaisedPass {
            failures.append("Relaxed and raised differ by \(rounded(relaxedRaised)) < \(IconMetrics.relaxedRaisedPass) at 1x.")
        }
        // Pixel centers of the eyes (5.5, 8.5), (9.5, 8.5) and the nose (7.5, 11.4) of the menu art. Round 3: the raised
        // face moves 1 px right with the tilt; the pant nose sits 1 px higher.
        let face: [(String, Int, Int)] = [("eyeLeft", 5, 8), ("eyeRight", 9, 8), ("nose", 7, 11)]
        var faceJSON = [String: Double]()
        for (p, (posture, grid)) in grids.enumerated() {
            for (name, x0, y0) in face {
                let x = x0 + (p == 1 ? 1 : 0), y = y0 - (p == 2 && name == "nose" ? 1 : 0)
                faceJSON[posture + "." + name] = rounded(grid[y][x])
                if grid[y][x] >= 0.02 { failures.append("Face cutout \(posture).\(name) is not clear at 1x (alpha \(grid[y][x])).") }
            }
        }
        // The badge never touches the head: the head columns are the same with and without a badge
        // (0 to 15 next to the 8 pt glyph, 0 to 14 next to the 9 pt alarm disc of the pant head).
        var untouched = true
        for posture in MenuPosture.allCases {
            let plain = menuGrid(MenuIconState(posture: posture, badge: nil))
            let columns = posture == .pant ? Int(DogArt.alarmOrigin.x) : Int(DogArt.menuBadgeOrigin.x)
            for item in HealthItem.allCases {
                let marked = menuGrid(MenuIconState(posture: posture, badge: MenuBadge(item: item)))
                for y in 0..<marked.count { for x in 0..<columns where abs(marked[y][x] - plain[y][x]) > 1e-9 { untouched = false } }
            }
        }
        if !untouched { failures.append("A badge changes pixels of the head columns at 1x.") }
        let hollow = menuGrid(MenuIconState(posture: .hollow, badge: nil))
        if solidCount(hollow) * 10 >= solidCount(relaxed) * 6 {
            failures.append("Hollow icon is not lighter than 60 % of the filled icon.")
        }
        var coverage = [String: Int]()
        for entry in menuStates where entry.style == choice {
            coverage[entry.name] = solidCount(menuGrid(entry.state, style: entry.style))
        }
        var menuJSON = [String: Any]()
        menuJSON["postureXOR"] = m.pairs.mapValues(rounded)
        menuJSON["postureMinimum"] = rounded(m.minimum)
        menuJSON["postureThreshold"] = IconMetrics.posturePass
        menuJSON["relaxedRaisedXOR"] = rounded(relaxedRaised)
        menuJSON["relaxedRaisedThreshold"] = IconMetrics.relaxedRaisedPass
        menuJSON["faceCutoutAlpha"] = faceJSON
        menuJSON["headUntouchedByBadge"] = untouched
        menuJSON["solidPixels"] = coverage
        menuJSON["hollowSolid"] = solidCount(hollow)
        menuJSON["relaxedSolid"] = solidCount(relaxed)
        menuJSON["pathCacheEntries"] = DogPathCache.count
        writeJSON(menuJSON, "menu-metrics.json")
        return choice
    }


    // MARK: v2 five states (WP-E, DESIGN_V2.md 9.2 and 9.3, gate W08)

    /// The five states in the order of DESIGN_V2.md 9.2, with their Chinese names for the sheets.
    static let fiveKinds: [(kind: MenuIconKind, name: String)] = [
        (.normal, "正常"), (.caution, "留意（黄）"), (.alert, "异常（红）"), (.collecting, "采集中"), (.stale, "过期")]

    /// Menu bars of the five-state sheet: name, color, dark appearance, selected highlight. The first two are the
    /// reference bars of the contrast gate (MenuIconPalette.bar).
    static let fiveBars: [(id: String, name: String, color: UInt32, dark: Bool, selected: Bool)] = [
        ("light", "浅色菜单栏", MenuIconPalette.bar(dark: false), false, false),
        ("dark", "深色菜单栏", MenuIconPalette.bar(dark: true), true, false),
        ("light-selected", "浅色·选中高亮", MenuIconPalette.bar(dark: false), false, true),
        ("dark-selected", "深色·选中高亮", MenuIconPalette.bar(dark: true), true, true),
        ("wallpaper-warm", "暖色壁纸（深字）", 0xD9C7A6, false, false),
        ("wallpaper-blue", "蓝色壁纸（浅字）", 0x5B7DB1, true, false)]

    /// The inks the app gives a state on a light or dark bar: template states in one ink, caution and alert with the
    /// head in the bar text color and the badge in its token color.
    static func menuInk(_ state: MenuIconState, dark: Bool) -> MenuIconInk {
        state.kind.isTemplate ? .mono(barInk(dark)) : .colored(dark: dark, head: barInk(dark))
    }

    /// The selected highlight behind a status item (approximate): a rounded rect, black 12 % or white 20 %.
    static func drawHighlight(_ rect: CGRect, dark: Bool, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// One five-state icon on one bar: 30 x 22 pt (the icon at (3, 2), the highlight around it when selected).
    static func fiveCell(_ state: MenuIconState, bar: (id: String, name: String, color: UInt32, dark: Bool, selected: Bool),
                         style: GlyphStyle, scale: Int) -> CGImage? {
        draw(CGSize(width: 30, height: 22), scale: scale, background: bar.color) { ctx in
            if bar.selected { drawHighlight(CGRect(x: 0, y: 0, width: 30, height: 22), dark: bar.dark, in: ctx) }
            MenuIconRenderer.draw(state, style: style, ink: menuInk(state, dark: bar.dark), at: CGPoint(x: 3, y: 2), in: ctx)
        }
    }

    private static func renderFiveStates(_ style: GlyphStyle) {
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("menu5"), withIntermediateDirectories: true)
        } catch {
            failures.append("Cannot create menu5.")
            return
        }
        for bar in fiveBars {
            for scale in [1, 2] {
                for entry in fiveKinds {
                    let state = MenuIconModel.state(for: entry.kind, item: .disk)
                    save(fiveCell(state, bar: bar, style: style, scale: scale),
                         "menu5/\(entry.kind.rawValue)-\(bar.id)@\(scale)x.png", group: "menu5-\(bar.id)-\(scale)")
                }
            }
        }
    }

    /// Five-state metrics for badge-matrix.json (W08). Adds a failure when a gate fails:
    /// five states pairwise at 1x >= 0.20 (every badge item), data marks with the category glyphs >= 0.35,
    /// yellow and red badge contrast >= 3:1 on the reference light and dark bars.
    private static func fiveStateMetrics(_ style: GlyphStyle) -> [String: Any] {
        var out = [String: Any]()
        // (1) Five states pairwise, disk as the representative item.
        let rep = fiveKinds.map { ($0.kind.rawValue, menuGrid(MenuIconModel.state(for: $0.kind, item: .disk), style: style)) }
        let repMatrix = IconMetrics.matrix(rep)
        // Every item: caution and alert of each item against every other state of another kind.
        var all = [(kind: MenuIconKind, name: String, grid: [[Double]])]()
        for entry in fiveKinds {
            let items: [HealthItem] = (entry.kind == .caution || entry.kind == .alert) ? HealthItem.allCases : [.disk]
            for item in items {
                let name = entry.kind.rawValue + ((entry.kind == .caution || entry.kind == .alert) ? "-" + item.rawValue : "")
                all.append((entry.kind, name, menuGrid(MenuIconModel.state(for: entry.kind, item: item), style: style)))
            }
        }
        var worst = (value: Double.infinity, pair: "")
        var byKinds = [String: Double]()
        for i in 0..<all.count {
            for j in (i + 1)..<all.count where all[i].kind != all[j].kind {
                let r = IconMetrics.xorRatio(all[i].grid, all[j].grid)
                let key = all[i].kind.rawValue + "/" + all[j].kind.rawValue
                byKinds[key] = min(byKinds[key] ?? .infinity, r)
                if r < worst.value { worst = (r, all[i].name + "/" + all[j].name) }
            }
        }
        let fivePass = repMatrix.minimum >= IconMetrics.fiveStatePass && worst.value >= IconMetrics.fiveStatePass
        if !fivePass {
            failures.append("Five-state gate: minimum XOR \(rounded(worst.value)) (\(worst.pair)) < \(IconMetrics.fiveStatePass) at 1x.")
        }
        var solid = [String: Int]()
        for (name, grid) in rep { solid[name] = solidCount(grid) }
        out["fiveStates"] = ["pairs": repMatrix.pairs.mapValues(rounded), "minimum": rounded(repMatrix.minimum),
                             "minimumAllItems": rounded(worst.value), "worstPair": worst.pair,
                             "minimumByKinds": byKinds.mapValues(rounded), "solidPixels": solid,
                             "threshold": IconMetrics.fiveStatePass, "pass": fivePass,
                             "representativeItem": HealthItem.disk.rawValue] as [String: Any]
        // (2) Data marks join the category glyph matrix (9.3: glyphs pairwise >= 0.35).
        var glyphs = HealthItem.allCases.map { ($0.rawValue, badgeGrid($0, style: style)) }
        for mark in MenuMark.allCases { glyphs.append((mark.rawValue, markGrid(mark))) }
        let gm = IconMetrics.matrix(glyphs)
        let marksPass = gm.minimum >= IconMetrics.badgePass
        if !marksPass { failures.append("Mark glyph gate: minimum XOR \(rounded(gm.minimum)) < \(IconMetrics.badgePass) at 1x.") }
        var markSolid = [String: Int]()
        for mark in MenuMark.allCases { markSolid[mark.rawValue] = solidCount(markGrid(mark)) }
        out["marks"] = ["pairs": gm.pairs.mapValues(rounded), "minimum": rounded(gm.minimum), "threshold": IconMetrics.badgePass,
                        "pass": marksPass, "solidPixels": markSolid] as [String: Any]
        // (3) Badge contrast against the reference bars (gated) and the extra bars (information).
        var contrast = [String: Any]()
        var contrastPass = true
        for token in MenuIconPalette.Token.allCases {
            for dark in [false, true] {
                let color = MenuIconPalette.hex(token, dark: dark)
                let ratio = IconMetrics.contrast(color, MenuIconPalette.bar(dark: dark))
                if ratio < IconMetrics.badgeContrastPass {
                    contrastPass = false
                    failures.append("Badge contrast \(token.rawValue) \(dark ? "dark" : "light"): \(rounded(ratio)) < 3.")
                }
                var extras = [String: Double]()
                for (name, bg) in dark ? MenuIconPalette.darkExtras : MenuIconPalette.lightExtras {
                    extras[name] = rounded(IconMetrics.contrast(color, bg))
                }
                contrast[token.rawValue + (dark ? "-dark" : "-light")] = ["color": String(format: "%06X", color),
                    "bar": String(format: "%06X", MenuIconPalette.bar(dark: dark)), "ratio": rounded(ratio),
                    "extrasNotGated": extras] as [String: Any]
            }
        }
        contrast["threshold"] = IconMetrics.badgeContrastPass
        contrast["pass"] = contrastPass
        out["contrast"] = contrast
        return out
    }

    /// sheet-menu-five.png: rows are the six bars, columns the five states. Each cell: the icon at real size (1x and
    /// 2x), the 2x pixels at 3x zoom, and the 1x pixels at 4x zoom. A last row shows the light bar in grayscale
    /// (shape only, as a color-blind reader sees the level).
    private static func sheetFiveStates(_ style: GlyphStyle) {
        let cellW: CGFloat = 250, rowH: CGFloat = 132, top: CGFloat = 52, left: CGFloat = 110
        let rows = fiveBars.count + 1
        let size = CGSize(width: left + cellW * CGFloat(fiveKinds.count) + 8, height: top + rowH * CGFloat(rows) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("菜单栏图标五态（磁盘为代表项）：每格左上为实际大小 1x 与 2x，左下为 2x 像素放大 3 倍，右为 1x 像素放大 4 倍",
                  at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            label("最后一行为浅色菜单栏的灰度版本：只看形状（色盲模拟）", at: CGPoint(x: 8, y: 34), size: 10, in: ctx)
            for (c, entry) in fiveKinds.enumerated() {
                label(entry.name, at: CGPoint(x: left + CGFloat(c) * cellW + 4, y: top - 4), size: 11, in: ctx)
            }
            for r in 0..<rows {
                let gray = (r == fiveBars.count)
                let bar = gray ? fiveBars[0] : fiveBars[r]
                let y = top + CGFloat(r) * rowH
                label(gray ? "灰度（浅色）" : bar.name, at: CGPoint(x: 6, y: y + 60), size: 10, in: ctx)
                for (c, entry) in fiveKinds.enumerated() {
                    let state = MenuIconModel.state(for: entry.kind, item: .disk)
                    let x = left + CGFloat(c) * cellW
                    fill(CGRect(x: x, y: y, width: cellW - 6, height: rowH - 6), bar.color, in: ctx)
                    var one = fiveCell(state, bar: bar, style: style, scale: 1)
                    var two = fiveCell(state, bar: bar, style: style, scale: 2)
                    if gray { one = one.flatMap(grayscale); two = two.flatMap(grayscale) }
                    // Real size: 1x pixels at 1 pt (the sheet is 2x, so each pixel is 2 sheet pixels), 2x at 1 pt.
                    pixels(one, in: CGRect(x: x + 6, y: y + 6, width: 30, height: 22), ctx: ctx)
                    if let two { ctx.draw(two, in: CGRect(x: x + 42, y: y + 6, width: 30, height: 22)) }
                    pixels(two, in: CGRect(x: x + 6, y: y + 34, width: 90, height: 66), ctx: ctx)
                    pixels(one, in: CGRect(x: x + 108, y: y + 6, width: 120, height: 88), ctx: ctx)
                }
            }
        }
        save(image, "sheet-menu-five.png", group: nil)
    }

    /// The image in gray (luma), opaque.
    static func grayscale(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: Card metrics (round 3)

    /// card-metrics.json: leg band XOR of stand, walk and trot at 72 x 54 1x, paw lift, body bob, bubble size and gap.
    private static func writeCardMetrics() {
        let size = cardSizes[1]
        let px = Double(size.width) / DogArt.designSize.w          // 0.6 px per u
        let gaits: [(String, DogGait, DogInput)] = [("stand", .stand, input()), ("walk", .walk, input(cpu: 25)),
                                                     ("trot", .trot, input(cpu: 60))]
        let grids = gaits.map { g in
            (g.0, alphaGrid(size) { ctx in
                DogRenderer.drawStatic(g.2, gait: g.1, dark: false, in: CGRect(origin: .zero, size: size), ctx: ctx)
            })
        }
        var band = [String: Double]()
        for i in 0..<grids.count {
            for j in (i + 1)..<grids.count {
                let r = IconMetrics.bandRatio(grids[i].1, grids[j].1, rows: IconMetrics.cardLegRows)
                band[grids[i].0 + "/" + grids[j].0] = rounded(r)
                if r < IconMetrics.cardLegPass {
                    failures.append("Card legs: \(grids[i].0)/\(grids[j].0) differ by \(rounded(r)) < \(IconMetrics.cardLegPass) at 72.")
                }
            }
        }
        // Paw lift: the highest lifted paw bottom above the ground, from the drawn paths. Bob: bodyY range per stride.
        var lift = [String: Double](), bob = [String: Double]()
        let moving: [(String, DogGait, DogInput)] = Array(gaits.dropFirst()) + [("sprint", .sprint, input(cpu: 95))]
        for (name, gait, inp) in moving {
            let pose = DogMotor.staticPose(gait: gait, input: inp)
            var best = -Double.infinity
            for layer in DogRig.layers(gait: gait, pose: pose) where DogRig.legNames.contains(layer.part.name) {
                best = max(best, (DogArt.groundY - Double(DogRenderer.transformed(layer).boundingBoxOfPath.maxY)) * px)
            }
            lift[name] = rounded(best)
            let ys = (0..<32).map { DogMotor.staticPose(gait: gait, input: inp, phase: Double($0) * Double.pi / 16).bodyY }
            bob[name] = rounded((ys.max()! - ys.min()!) * px)
            if name != "sprint", best < IconMetrics.pawLiftPx {
                failures.append("Card legs: the \(name) paw lifts \(rounded(best)) px < \(IconMetrics.pawLiftPx) px at 72.")
            }
            if bob[name]! < IconMetrics.bobPx { failures.append("Card legs: the \(name) body bobs \(bob[name]!) px < \(IconMetrics.bobPx) px.") }
        }
        // Bubble: diameter, and the gap between the drawn bubble (outline included) and the drawn dog, at 4x.
        let c = DogArt.bubbleCircle
        let outline = Double(DogRenderer.outlineWidth) / 2
        let diameter = rounded((2 * c.r + 2 * outline) * px)
        if diameter < IconMetrics.bubbleMinPx { failures.append("Bubble is \(diameter) px < \(IconMetrics.bubbleMinPx) px at 72.") }
        var gaps = [String: Double](), dotGaps = [String: Double]()
        let tail = DogArt.bubble.first(where: { $0.name == "bubble.tail1" })
        let dotBox = tail.map { GlyphPaths.cgPath($0.ops).boundingBoxOfPath } ?? .zero
        let dot = (x: Double(dotBox.midX), y: Double(dotBox.midY), r: Double(dotBox.width) / 2)
        let problems: [(String, DogGait, DogInput)] = [
            ("lie", .lie, input(cpu: 3, problem: .disk, level: .yellow)), ("stand", .stand, input(problem: .disk, level: .yellow)),
            ("walk", .walk, input(cpu: 25, problem: .memory, level: .red)), ("trot", .trot, input(cpu: 60, problem: .cpu, level: .yellow)),
            ("sprint", .sprint, input(cpu: 95, problem: .cpu, level: .red)),
            ("alarm", .stand, input(thermal: .critical, problem: .thermal, level: .red))]
        let k = 4
        for (name, gait, inp) in problems {
            var worst = Double.infinity, worstDot = Double.infinity
            for step in 0..<8 {
                let pose = DogMotor.staticPose(gait: gait, input: inp, phase: Double(step) * Double.pi / 4)
                let dog = DogRig.layers(gait: gait, pose: pose).filter { !$0.part.name.hasPrefix("bubble.") }
                let g = alphaGrid(CGSize(width: size.width * CGFloat(k), height: size.height * CGFloat(k))) { ctx in
                    ctx.scaleBy(x: CGFloat(px) * CGFloat(k), y: CGFloat(px) * CGFloat(k))
                    DogRenderer.draw(dog, opacity: 1, palette: DogPalette(dark: false), level: .yellow, in: ctx)
                }
                for (y, row) in g.enumerated() {
                    for (x, v) in row.enumerated() where v >= IconMetrics.solidThreshold {
                        let ux = (Double(x) + 0.5) / Double(k) / px, uy = (Double(y) + 0.5) / Double(k) / px
                        let d = ((ux - c.x) * (ux - c.x) + (uy - c.y) * (uy - c.y)).squareRoot() - c.r - outline
                        worst = min(worst, d * px)
                        let e = ((ux - dot.x) * (ux - dot.x) + (uy - dot.y) * (uy - dot.y)).squareRoot() - dot.r - outline
                        worstDot = min(worstDot, e * px)
                    }
                }
            }
            gaps[name] = rounded(worst)
            dotGaps[name] = rounded(worstDot)
            if worstDot < IconMetrics.bubbleGapPx { failures.append("Bubble tail dot gap \(name): \(rounded(worstDot)) px < \(IconMetrics.bubbleGapPx) px.") }
            if worst < IconMetrics.bubbleGapPx { failures.append("Bubble gap \(name): \(rounded(worst)) px < \(IconMetrics.bubbleGapPx) px at 72.") }
        }
        var json = [String: Any]()
        json["legBandRows"] = [IconMetrics.cardLegRows.lowerBound, IconMetrics.cardLegRows.upperBound - 1]
        json["legBandXOR"] = band
        json["legBandThreshold"] = IconMetrics.cardLegPass
        json["pawLiftPx"] = lift
        json["pawLiftThreshold"] = IconMetrics.pawLiftPx
        json["bodyBobPx"] = bob
        json["bodyBobThreshold"] = IconMetrics.bobPx
        json["bubbleDiameterPx"] = diameter
        json["bubbleGapPx"] = gaps
        json["bubbleTailDotGapPx"] = dotGaps
        json["bubbleGapThreshold"] = IconMetrics.bubbleGapPx
        writeJSON(json, "card-metrics.json")
    }

    // MARK: Contact sheets

    private static func sheetCard() {
        let poses = cardPoses
        let cellW: CGFloat = 116, cellH: CGFloat = 100, top: CGFloat = 30
        let size = CGSize(width: cellW * 4 + 8, height: top + cellH * CGFloat(poses.count) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("比熊状态卡图册：104 × 78 与 72 × 54，浅色与深色", at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            for (r, pose) in poses.enumerated() {
                for c in 0..<4 {
                    let dark = (c % 2 == 1)
                    let cardSize = cardSizes[c / 2]
                    let cell = CGRect(x: 4 + CGFloat(c) * cellW, y: top + CGFloat(r) * cellH, width: cellW - 4, height: cellH - 4)
                    fill(cell, cardBackground[dark] ?? 0, in: ctx)
                    let dog = CGRect(x: cell.minX + (cell.width - cardSize.width) / 2, y: cell.minY + 4,
                                     width: cardSize.width, height: cardSize.height)
                    DogRenderer.drawStatic(pose.input, gait: pose.gait, phase: pose.phase, dark: dark, in: dog, ctx: ctx)
                    let text = "\(pose.name) \(Int(cardSize.width))"
                    label(text, at: CGPoint(x: cell.minX + 4, y: cell.maxY - 5), size: 9, dark: dark, in: ctx)
                }
            }
        }
        save(image, "sheet-card.png", group: nil)
    }

    private static func sheetMenu(_ style: GlyphStyle) {
        let postures = MenuPosture.allCases
        let badges: [HealthItem?] = [nil] + HealthItem.allCases.map { Optional($0) }
        let cellW: CGFloat = 112, cellH: CGFloat = 64, top: CGFloat = 30, left: CGFloat = 64
        let size = CGSize(width: left + cellW * CGFloat(badges.count) + 8, height: top + cellH * CGFloat(postures.count * 2) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            let title = "菜单栏图标（角标：\(style == .glyph ? "字形" : "字母")）每格左为 2 倍矢量，右为 1x 像素放大 2 倍"
            label(title, at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            for (c, badge) in badges.enumerated() {
                let name = badge.map { $0.label } ?? "无角标"
                label(name, at: CGPoint(x: left + CGFloat(c) * cellW + 4, y: top - 2), size: 9, in: ctx)
            }
            for dark in [false, true] {
                for (p, posture) in postures.enumerated() {
                    let r = (dark ? postures.count : 0) + p
                    let y = top + 4 + CGFloat(r) * cellH
                    label(posture.rawValue + (dark ? " 深" : " 浅"), at: CGPoint(x: 6, y: y + 30), size: 9, in: ctx)
                    for (c, badge) in badges.enumerated() {
                        let cell = CGRect(x: left + CGFloat(c) * cellW, y: y, width: cellW - 4, height: cellH - 6)
                        fill(cell, barBackground[dark] ?? 0, in: ctx)
                        let state = MenuIconState(posture: posture, badge: badge.map { MenuBadge(item: $0) })
                        ctx.saveGState()
                        ctx.translateBy(x: cell.minX + 4, y: cell.minY + 11)
                        ctx.scaleBy(x: 2, y: 2)
                        MenuIconRenderer.draw(state, style: style, ink: barInk(dark), in: ctx)
                        ctx.restoreGState()
                        let one = draw(MenuIconRenderer.size, scale: 1, background: barBackground[dark]) { c1 in
                            MenuIconRenderer.draw(state, style: style, ink: barInk(dark), in: c1)
                        }
                        pixels(one, in: CGRect(x: cell.minX + 56, y: cell.minY + 11, width: 48, height: 36), ctx: ctx)
                    }
                }
            }
        }
        save(image, "sheet-menu-\(style.rawValue).png", group: nil)
    }

    private static func sheetBadges() {
        let cell: CGFloat = 96
        let top: CGFloat = 30
        // Rows: yellow glyph, yellow letter, red alarm disc (glyph), red alarm disc (letter). Each has a vector row
        // (8x) and a 1x pixel row (8x zoom).
        let kinds: [(String, GlyphStyle, Bool)] = [("字形", .glyph, false), ("字母", .letter, false),
                                                   ("红盘字形", .glyph, true), ("红盘字母", .letter, true)]
        let size = CGSize(width: 90 + cell * 5 + 8, height: top + (cell + 24) * CGFloat(kinds.count * 2) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("角标对照：黄为 8 × 8 字形，红为 9 × 9 实心圆盘镂空字形。每种 2 行，上为 8 倍矢量，下为 1x 放大 8 倍",
                  at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            for (s, kind) in kinds.enumerated() {
                let side = kind.2 ? CGFloat(DogArt.alarmSize) : CGFloat(DogArt.badgeSize)
                for (i, item) in HealthItem.allCases.enumerated() {
                    let x = 90 + CGFloat(i) * cell
                    let yVector = top + CGFloat(s * 2) * (cell + 24)
                    let yPixel = yVector + cell + 24
                    label(item.label, at: CGPoint(x: x, y: yVector + 14), size: 10, in: ctx)
                    let box = CGRect(x: x, y: yVector + 20, width: side * 8, height: side * 8)
                    fill(box, barBackground[false] ?? 0, in: ctx)
                    ctx.saveGState()
                    ctx.translateBy(x: box.minX, y: box.minY)
                    ctx.scaleBy(x: 8, y: 8)
                    if kind.2 {
                        drawAlarm(item, style: kind.1, ink: barInk(false), in: ctx)
                    } else {
                        ctx.setFillColor(barInk(false))
                        ctx.addPath(GlyphPaths.badgeYDown(item, style: kind.1))
                        ctx.fillPath()
                    }
                    ctx.restoreGState()
                    let one = draw(CGSize(width: side, height: side), scale: 1, background: barBackground[false]) { c1 in
                        if kind.2 {
                            drawAlarm(item, style: kind.1, ink: barInk(false), in: c1)
                        } else {
                            c1.setFillColor(barInk(false))
                            c1.addPath(GlyphPaths.badgeYDown(item, style: kind.1))
                            c1.fillPath()
                        }
                    }
                    pixels(one, in: CGRect(x: x, y: yPixel + 4, width: side * 8, height: side * 8), ctx: ctx)
                }
                let yy = top + CGFloat(s * 2) * (cell + 24)
                label(kind.0, at: CGPoint(x: 8, y: yy + 64), size: 11, in: ctx)
                label(kind.0 + " 1x", at: CGPoint(x: 8, y: yy + cell + 24 + 50), size: 11, in: ctx)
            }
        }
        save(image, "sheet-badges.png", group: nil)
    }

    // MARK: Stage 2: motion

    static let strideGaits: [(DogGait, Double)] = [(.walk, 25), (.trot, 60), (.sprint, 95)]

    /// One stride of each moving gait, 8 frames, phi = i x 45 deg (DESIGN.md 4.8 "步态序列"), 104 pt, light and dark.
    private static func renderSequences() {
        for (gait, cpu) in strideGaits {
            for i in 0..<8 {
                for dark in [false, true] {
                    let size = cardSizes[0]
                    let name = "card/seq-\(gait.rawValue)-\(i)-104-\(dark ? "dark" : "light")@2x.png"
                    let image = draw(size, scale: 2, background: cardBackground[dark]) { ctx in
                        DogRenderer.drawStatic(input(cpu: cpu), gait: gait, phase: Double(i) * Double.pi / 4, dark: dark,
                                               in: CGRect(origin: .zero, size: size), ctx: ctx)
                    }
                    save(image, name, group: "seq-\(gait.rawValue)-\(dark)")
                }
            }
        }
    }

    /// Contact sheet: rows walk, trot, sprint at 104 pt (light, dark) and 72 pt (light); 8 frames per row.
    private static func sheetSequences() {
        var rows = [(DogGait, Double, Int, Bool)]()
        for (sizeIndex, dark) in [(0, false), (0, true), (1, false)] {
            for g in strideGaits { rows.append((g.0, g.1, sizeIndex, dark)) }
        }
        let cellW: CGFloat = 112, cellH: CGFloat = 96, top: CGFloat = 30, left: CGFloat = 70
        let size = CGSize(width: left + cellW * 8 + 8, height: top + cellH * CGFloat(rows.count) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("步态序列：每行 1 个步幅 8 帧（φ 每 45°），左起 φ = 0。104 pt 浅色、深色，72 pt 浅色", at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            for (r, row) in rows.enumerated() {
                let cardSize = cardSizes[row.2]
                let y = top + CGFloat(r) * cellH
                label("\(row.0.rawValue) \(Int(cardSize.width))\(row.3 ? " 深" : "")", at: CGPoint(x: 6, y: y + 44), size: 10, in: ctx)
                for i in 0..<8 {
                    let cell = CGRect(x: left + CGFloat(i) * cellW, y: y, width: cellW - 4, height: cellH - 6)
                    fill(cell, cardBackground[row.3] ?? 0, in: ctx)
                    let dog = CGRect(x: cell.minX + (cell.width - cardSize.width) / 2, y: cell.minY + 4,
                                     width: cardSize.width, height: cardSize.height)
                    DogRenderer.drawStatic(input(cpu: row.1), gait: row.0, phase: Double(i) * Double.pi / 4, dark: row.3,
                                           in: dog, ctx: ctx)
                    label("\(i * 45)°", at: CGPoint(x: cell.minX + 4, y: cell.maxY - 4), size: 8, dark: row.3, in: ctx)
                }
            }
        }
        save(image, "sheet-seq.png", group: nil)
    }

    /// The motor itself at 24 fps: CPU jumps 5 % -> 95 % at t = 0 (lie -> walk at 0.46 s with the 0.6 s crossfade,
    /// walk -> trot at 4.46 s with the 0.35 s crossfade), and the bubble pop of a new problem. Frames as DogView draws them.
    private static func sheetTimeline() {
        var motor = DogMotor(initialCPU: 5)
        let hot = input(cpu: 95)
        var frames = [(t: Double, frame: DogFrame, input: DogInput)]()
        for n in 1...(24 * 6) {
            let f = motor.frame(dt: 1.0 / 24, input: hot)
            frames.append((t: Double(n) / 24, frame: f, input: hot))
        }
        let rise = frames.filter { $0.t >= 0.4 && $0.t < 1.15 }
        let trot = frames.filter { $0.t >= 4.4 && $0.t < 4.9 }
        var popMotor = DogMotor(initialCPU: 25)
        let problem = input(cpu: 25, problem: .disk, level: .yellow)
        var pop = [(t: Double, frame: DogFrame, input: DogInput)]()
        for n in 1...16 { pop.append((t: Double(n) / 24, frame: popMotor.frame(dt: 1.0 / 24, input: problem), input: problem)) }
        let groups: [(String, [(t: Double, frame: DogFrame, input: DogInput)])] = [
            ("趴 → 走（0.6 秒交叉淡变）", rise), ("走 → 小跑（0.35 秒交叉淡变）", trot), ("气泡弹出（0.6 → 1）", pop)]
        let cols = 9
        let cellW: CGFloat = 112, cellH: CGFloat = 96, top: CGFloat = 30
        var rowCount = 0
        for g in groups { rowCount += (g.1.count + cols - 1) / cols }
        let size = CGSize(width: cellW * CGFloat(cols) + 8, height: top + CGFloat(rowCount) * cellH + CGFloat(groups.count) * 18 + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("马达时间线（24 fps，每格 1 帧，DogView 的真实帧）", at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            var y = top
            for g in groups {
                label(g.0, at: CGPoint(x: 6, y: y + 12), size: 10, in: ctx)
                y += 18
                for (i, item) in g.1.enumerated() {
                    let x = 4 + CGFloat(i % cols) * cellW
                    let yy = y + CGFloat(i / cols) * cellH
                    let cell = CGRect(x: x, y: yy, width: cellW - 4, height: cellH - 6)
                    fill(cell, cardBackground[false] ?? 0, in: ctx)
                    let dog = CGRect(x: cell.minX + 4, y: cell.minY + 4, width: 104, height: 78)
                    DogRenderer.drawFrame(item.frame, input: item.input, dark: false, in: dog, ctx: ctx)
                    let fade = item.frame.fadeFrom.map { " \($0.rawValue)>\(item.frame.gait.rawValue) \(Int(item.frame.fade * 100))%" } ?? " \(item.frame.gait.rawValue)"
                    label(String(format: "%.2fs", item.t) + fade, at: CGPoint(x: cell.minX + 3, y: cell.maxY - 3), size: 7, in: ctx)
                }
                y += CGFloat((g.1.count + cols - 1) / cols) * cellH
            }
        }
        save(image, "sheet-timeline.png", group: nil)
    }

    static let menuSwitches: [(String, MenuIconState, MenuIconState)] = [
        ("正常 → 关注 CPU", MenuIconState(posture: .relaxed, badge: nil), MenuIconState(posture: .raised, badge: MenuBadge(item: .cpu))),
        ("关注 CPU → 警告 CPU", MenuIconState(posture: .raised, badge: MenuBadge(item: .cpu)), MenuIconState(posture: .pant, badge: MenuBadge(item: .cpu))),
        ("正常 → 警告 内存", MenuIconState(posture: .relaxed, badge: nil), MenuIconState(posture: .pant, badge: MenuBadge(item: .memory))),
        ("关注 磁盘 → 关注 耗电", MenuIconState(posture: .raised, badge: MenuBadge(item: .disk)), MenuIconState(posture: .raised, badge: MenuBadge(item: .power))),
        ("警告 温度 → 正常", MenuIconState(posture: .pant, badge: MenuBadge(item: .thermal)), MenuIconState(posture: .relaxed, badge: nil)),
        ("关注 内存 → 正常", MenuIconState(posture: .raised, badge: MenuBadge(item: .memory)), MenuIconState(posture: .relaxed, badge: nil)),
    ]

    /// Contact sheet of the menu bar switch: the start state, then the 8 frames (70 ms apart). Each frame as a 2x
    /// vector and as 1x pixels zoomed 2x on the light menu bar; the dark bar repeats the vector row.
    private static func sheetMenuSwitch(_ style: GlyphStyle) {
        let cellW: CGFloat = 80, rowH: CGFloat = 132, top: CGFloat = 30, left: CGFloat = 8
        let size = CGSize(width: left + cellW * 9 + 8, height: top + rowH * CGFloat(menuSwitches.count) + 8)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("菜单栏切换动画：每行起始态 + 8 帧（每帧 70 ms）。上：浅色 2 倍矢量。中：1x 像素放大 2 倍。下：深色 2 倍矢量",
                  at: CGPoint(x: 8, y: 18), size: 11, in: ctx)
            for (r, sw) in menuSwitches.enumerated() {
                let y = top + CGFloat(r) * rowH
                label(sw.0, at: CGPoint(x: left, y: y + 10), size: 10, in: ctx)
                let frames = [MenuMotion.still(sw.1)] + MenuMotion.frames(from: sw.1, to: sw.2)
                for (i, f) in frames.enumerated() {
                    let x = left + CGFloat(i) * cellW
                    for (k, dark) in [(0, false), (2, true)] {
                        let cell = CGRect(x: x, y: y + 14 + CGFloat(k) * 38, width: cellW - 6, height: 36)
                        fill(cell, barBackground[dark] ?? 0, in: ctx)
                        ctx.saveGState()
                        ctx.translateBy(x: cell.minX + 13, y: cell.minY)
                        ctx.scaleBy(x: 2, y: 2)
                        MenuIconRenderer.draw(f, style: style, ink: barInk(dark), cached: false, in: ctx)
                        ctx.restoreGState()
                    }
                    let one = draw(MenuIconRenderer.size, scale: 1, background: barBackground[false]) { c1 in
                        MenuIconRenderer.draw(f, style: style, ink: barInk(false), cached: false, in: c1)
                    }
                    pixels(one, in: CGRect(x: x + 13, y: y + 14 + 38, width: 48, height: 36), ctx: ctx)
                    label(i == 0 ? "起始" : "\(i)", at: CGPoint(x: x + 2, y: y + rowH - 2), size: 8, in: ctx)
                }
            }
        }
        save(image, "sheet-menu-switch.png", group: nil)
    }

    /// Every switch between two non-hollow states has 8 frames, and its last frame has the pixels of the still target
    /// (1x and 2x). Hollow switches have no frames. Results go to menu-switch.json.
    private static func checkMenuSwitchFrames(_ style: GlyphStyle) {
        var states = [MenuIconState(posture: .relaxed, badge: nil)]
        for posture in [MenuPosture.raised, .pant] {
            for item in HealthItem.allCases { states.append(MenuIconState(posture: posture, badge: MenuBadge(item: item))) }
        }
        var pairs = 0, bad = [String]()
        var maxScale = 0.0
        for a in states {
            for b in states where a != b {
                pairs += 1
                let frames = MenuMotion.frames(from: a, to: b)
                maxScale = max(maxScale, frames.map { $0.badgeScale }.max() ?? 0)
                let name = "\(a.posture.rawValue)-\(a.badge?.item.rawValue ?? "none")>\(b.posture.rawValue)-\(b.badge?.item.rawValue ?? "none")"
                guard frames.count == MenuMotion.frameCount, let last = frames.last else {
                    bad.append(name + " frames \(frames.count)")
                    continue
                }
                for scale in [1, 2] {
                    let x = draw(MenuIconRenderer.size, scale: scale, background: nil) { c in
                        MenuIconRenderer.draw(last, style: style, ink: CGColor(gray: 0, alpha: 1), cached: false, in: c)
                    }
                    let y = draw(MenuIconRenderer.size, scale: scale, background: nil) { c in
                        MenuIconRenderer.draw(b, style: style, ink: CGColor(gray: 0, alpha: 1), in: c)
                    }
                    if let x, let y, maxAlphaDifference(x, y) > 8 { bad.append(name + " last frame @\(scale)x") }
                }
            }
        }
        let hollow = MenuMotion.frames(from: MenuIconState(posture: .hollow, badge: nil), to: states[1]).count
        if hollow != 0 { bad.append("hollow switch has \(hollow) frames") }
        writeJSON(["pairs": pairs, "framesPerSwitch": MenuMotion.frameCount, "frameIntervalMs": MenuMotion.frameInterval * 1000,
                   "playMs": Double(MenuMotion.frameCount - 1) * MenuMotion.frameInterval * 1000, "badgePeak": maxScale,
                   "failures": bad], "menu-switch.json")
        if !bad.isEmpty { failures.append("Menu switch frames: " + bad.prefix(5).joined(separator: "; ")) }
    }

    /// Largest difference of the alpha bytes of two images of the same size (255 when the sizes differ).
    /// The gray dog (collecting, stale) against card-like surfaces, measured like the M19 gate of the UI regression:
    /// pixels whose color differs from the dominant color by more than 30 (RGB distance) count as ink. Writes
    /// gray-dog.json. The light gray dog must reach 1.5 % at 72 x 54 and 104 x 78 (I3 request 6), and it must stay
    /// paler than the normal dog (its darkest pixel is lighter).
    private static func checkGrayInk() {
        var rows = [[String: Any]]()
        let gray = input(cpu: nil, isStatic: true)
        let normal = input(cpu: 5)
        for size in [CGSize(width: 72, height: 54), CGSize(width: 104, height: 78)] {
            for (dark, surfaces) in [(false, [0xFFFFFF, 0xF2F2F2, 0xECECEC, 0xE4E4E4]), (true, [0x1E1E1E, 0x282828, 0x323232])] {
                for surface in surfaces {
                    func measure(_ dogInput: DogInput) -> (share: Double, darkest: Double) {
                        guard let image = draw(size, scale: 2, background: UInt32(surface), { ctx in
                            DogRenderer.drawStatic(dogInput, gait: .stand, dark: dark, in: DogView.fit(size), ctx: ctx)
                        }) else { return (0, 0) }
                        return inkShare(image)
                    }
                    let g = measure(gray), n = measure(normal)
                    let paler = dark ? true : g.darkest > n.darkest
                    if !dark && g.share < 0.015 {
                        failures.append("gray dog \(Int(size.width)) light on \(String(surface, radix: 16)): ink \(g.share) < 1.5 %")
                    }
                    if !paler { failures.append("gray dog \(Int(size.width)) is not paler than the normal dog") }
                    rows.append(["size": "\(Int(size.width))x\(Int(size.height))", "dark": dark, "surface": String(format: "%06lX", surface),
                                 "grayInkPercent": rounded(g.share * 100), "normalInkPercent": rounded(n.share * 100),
                                 "grayDarkestLuma": rounded(g.darkest), "normalDarkestLuma": rounded(n.darkest)])
                }
            }
        }
        writeJSON(["rows": rows, "rule": "ink = RGB distance to the dominant color > 30 (M19); light gray >= 1.5 %"], "gray-dog.json")
    }

    /// Ink share of an opaque image (the M19 rule) and the luma of its darkest pixel (0 to 255).
    static func inkShare(_ image: CGImage) -> (share: Double, darkest: Double) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var counts = [Int: Int]()
        for i in stride(from: 0, to: data.count, by: 4) {
            let key = (Int(data[i]) >> 4) << 8 | (Int(data[i + 1]) >> 4) << 4 | (Int(data[i + 2]) >> 4)
            counts[key, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return (0, 0) }
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            let key = (Int(data[i]) >> 4) << 8 | (Int(data[i + 1]) >> 4) << 4 | (Int(data[i + 2]) >> 4)
            if key == top { sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2]); n += 1 }
        }
        let bg = (sum.0 / n, sum.1 / n, sum.2 / n)
        var ink = 0
        var darkest = 255.0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
            let d = (r - bg.0) * (r - bg.0) + (g - bg.1) * (g - bg.1) + (b - bg.2) * (b - bg.2)
            if d > 900 { ink += 1 }
            darkest = min(darkest, 0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        return (Double(ink) / Double(w * h), darkest)
    }

    static func maxAlphaDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return 255 }
        let n = min(CFDataGetLength(da), CFDataGetLength(db))
        var worst = 0
        var i = 3
        while i < n {
            worst = max(worst, abs(Int(pa[i]) - Int(pb[i])))
            i += 4
        }
        return worst
    }

    // MARK: Menu bar mock-up

    private static func menubarMock(_ style: GlyphStyle) {
        let states: [(String, MenuIconState)] = [
            ("正常", MenuIconModel.state(for: .normal, item: .disk)),
            ("留意 CPU", MenuIconModel.state(for: .caution, item: .cpu)),
            ("异常 磁盘", MenuIconModel.state(for: .alert, item: .disk)),
            ("采集中", MenuIconModel.state(for: .collecting, item: .disk)),
            ("过期", MenuIconModel.state(for: .stale, item: .disk)),
            ("异常 温度", MenuIconModel.state(for: .alert, item: .thermal)),
            ("留意 内存", MenuIconModel.state(for: .caution, item: .memory)),
        ]
        let bars: [(String, UInt32, Bool)] = [("浅色菜单栏", 0xF2F2F2, false), ("深色菜单栏", 0x252527, true),
                                               ("彩色壁纸（浅字）", 0x5B7DB1, true), ("彩色壁纸（深字）", 0xD9C7A6, false)]
        let barW: CGFloat = 640, barH: CGFloat = 24, gap: CGFloat = 26, zoomH: CGFloat = 144 + 20
        let size = CGSize(width: barW + 16, height: 30 + CGFloat(bars.count) * (barH + gap) + 2 * zoomH + 16)
        let image = draw(size, scale: 2, background: 0xFFFFFF) { ctx in
            label("菜单栏实景模拟：24 pt 高菜单栏，图标 24 × 18 pt，两侧为系统图标示意", at: CGPoint(x: 8, y: 18), size: 12, in: ctx)
            for (b, bar) in bars.enumerated() {
                let y = 30 + CGFloat(b) * (barH + gap)
                label(bar.0, at: CGPoint(x: 8, y: y + 12), size: 9, in: ctx)
                let rect = CGRect(x: 8, y: y + 16, width: barW, height: barH)
                fill(rect, bar.1, in: ctx)
                let ink = barInk(bar.2)
                var x = rect.minX + 12
                fakeSystemIcon(at: CGPoint(x: x, y: rect.minY + 4), ink: ink, in: ctx)
                x += 30
                for (_, state) in states {
                    MenuIconRenderer.draw(state, style: style, ink: menuInk(state, dark: bar.2), at: CGPoint(x: x, y: rect.minY + 3), in: ctx)
                    x += 24 + 14
                }
                fakeSystemIcon(at: CGPoint(x: x + 4, y: rect.minY + 4), ink: ink, in: ctx)
                label("周日 10:42", at: CGPoint(x: rect.maxX - 70, y: rect.minY + 16), size: 13, color: ink, in: ctx)
            }
            // 1x pixels, 8x zoom: each 1x pixel is an 8 x 8 pt block.
            let zoomTop = 30 + CGFloat(bars.count) * (barH + gap)
            for (r, dark) in [false, true].enumerated() {
                let y = zoomTop + CGFloat(r) * zoomH
                label(dark ? "1x 像素放大 8 倍（深色）" : "1x 像素放大 8 倍（浅色）", at: CGPoint(x: 8, y: y + 12), size: 9, in: ctx)
                for (i, entry) in states.prefix(5).enumerated() {
                    let one = draw(MenuIconRenderer.size, scale: 1, background: barBackground[dark]) { c1 in
                        MenuIconRenderer.draw(entry.1, style: style, ink: menuInk(entry.1, dark: dark), in: c1)
                    }
                    let box = CGRect(x: 8 + CGFloat(i) * 128, y: y + 18, width: 24 * 5, height: 18 * 5)
                    pixels(one, in: box, ctx: ctx)
                    label(entry.0, at: CGPoint(x: box.minX, y: box.maxY + 12), size: 9, in: ctx)
                }
            }
        }
        save(image, "menubar-mock.png", group: nil)
    }

    /// A neutral stand-in for the neighbor status items (a battery shape), so the icon's weight can be compared.
    private static func fakeSystemIcon(at p: CGPoint, ink: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(1)
        let body = CGRect(x: p.x + 0.5, y: p.y + 4.5, width: 21, height: 10)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.strokePath()
        ctx.fill(CGRect(x: p.x + 2.5, y: p.y + 6.5, width: 13, height: 6))
        ctx.fill(CGRect(x: p.x + 22.5, y: p.y + 7.5, width: 1.5, height: 4))
        ctx.restoreGState()
    }

    // MARK: Drawing helpers

    static func rgb(_ hex: UInt32) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func fill(_ rect: CGRect, _ hex: UInt32, in ctx: CGContext) {
        ctx.setFillColor(rgb(hex))
        ctx.fill(rect)
    }

    /// An sRGB bitmap of `size` pt at `scale`, y down, 1 unit = 1 pt. `background` nil keeps it transparent.
    static func draw(_ size: CGSize, scale: Int, background: UInt32?, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((size.width * CGFloat(scale)).rounded())
        let h = Int((size.height * CGFloat(scale)).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        if let background {
            ctx.setFillColor(rgb(background))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        body(ctx)
        return ctx.makeImage()
    }

    /// Draws a bitmap with nearest-neighbor scaling into `rect` of a y-down context.
    private static func pixels(_ image: CGImage?, in rect: CGRect, ctx: CGContext) {
        guard let image else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Text label with its baseline at `p` in a y-down context.
    private static func label(_ text: String, at p: CGPoint, size: CGFloat, dark: Bool = false,
                              color: CGColor? = nil, in ctx: CGContext) {
        let ink = color ?? (dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75)
                                 : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        var attributes = [NSAttributedString.Key: Any]()
        attributes[.font] = font
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = ink
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Files

    private static var groups = [String: [String: String]]()   // group -> hash -> first file

    private static func save(_ image: CGImage?, _ name: String, group: String?) {
        guard let image else {
            failures.append("Cannot render \(name).")
            return
        }
        let hash = pixelHash(image)
        if let group {
            var seen = groups[group] ?? [:]
            if let other = seen[hash] {
                failures.append("Same pixels: \(name) and \(other).")
            } else {
                seen[hash] = name
            }
            groups[group] = seen
        }
        let url = root.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            failures.append("Cannot write \(name).")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) { failures.append("Cannot write \(name).") }
        manifest.append(["file": name, "hash": hash, "width": image.width, "height": image.height])
    }

    /// FNV-1a 64-bit over the raw pixel bytes.
    static func pixelHash(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "none" }
        var h: UInt64 = 0xcbf29ce484222325
        let n = CFDataGetLength(data)
        for i in 0..<n {
            h ^= UInt64(bytes[i])
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h)
    }

    /// The hash check runs inside `save`; this only records that the expected groups exist.
    private static func checkDistinct() {
        let expected = cardPoses.count
        for (group, seen) in groups where group.hasPrefix("card-") && seen.count != expected {
            failures.append("Group \(group) has \(seen.count) distinct images, expected \(expected).")
        }
    }

    private static func writeJSON(_ object: [String: Any], _ name: String) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            failures.append("Cannot encode \(name).")
            return
        }
        do {
            try data.write(to: root.appendingPathComponent(name))
        } catch {
            failures.append("Cannot write \(name).")
        }
    }

    /// Entry for `--dog-gallery <directory>`. Never returns: exit 0 on success, 1 on failure, 2 for a missing path.
    static func run(_ args: [String]) -> Never {
        guard let path = MoleMonitorMain.argumentValue("--dog-gallery", in: args) else {
            FileHandle.standardError.write(Data("--dog-gallery needs an output directory.\n".utf8))
            exit(2)
        }
#if UITEST
        // The dog animation gates (scripts/ci_acceptance.py, I2 block) run only in the UITEST build.
        if args.contains("--dog-checks") { UITestDogChecks.run(outDir: URL(fileURLWithPath: path, isDirectory: true)) }
#endif
        if let error = render(to: URL(fileURLWithPath: path, isDirectory: true)) {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            exit(1)
        }
        print(path)
        exit(0)
    }
}
