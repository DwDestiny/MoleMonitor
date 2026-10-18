// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the five menu bar icon states (docs/DESIGN_V2.md 9.2, 9.3, gate W08): kind mapping, state
//         round trip, template flag, labels and text, color tokens and contrast, the data marks at 1x.
// Pos: Called from main.swift via runMenuIconTests(); no top-level code in this file. A1 registers it, WP-E fills it.
//      The pixel gates on the real Core Graphics drawing are in the App (DogGallery `--dog-gallery`, UITestIconChecks W08).

import Foundation

private func iconVerdict(_ item: HealthItem, _ level: HealthLevel, minutes: Double? = nil, headline: String = "") -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: "x", headline: headline,
                since: minutes.map { now.addingTimeInterval(-$0 * 60) }, levelChangedAt: nil, alert: nil)
}

/// Alpha grid of DogParts (y down, pt) at 1x: nonzero winding per part, 4 x 4 samples per pixel. An approximation of
/// Core Graphics coverage, good enough for margins far from the gate.
private func iconGrid(_ parts: [DogPart], width: Int, height: Int) -> [[Double]] {
    var polys = [[[(Double, Double)]]]()
    for part in parts {
        var list = [[(Double, Double)]]()
        var cur = [(Double, Double)]()
        var pen = (0.0, 0.0)
        for op in part.ops {
            switch op {
            case .move(let x, let y):
                if cur.count > 1 { list.append(cur) }
                pen = (x, y)
                cur = [pen]
            case .line(let x, let y):
                pen = (x, y)
                cur.append(pen)
            case .cubic(let x1, let y1, let x2, let y2, let x3, let y3):
                let (x0, y0) = pen
                for k in 1...12 {
                    let s = Double(k) / 12, a = pow(1 - s, 3), b = 3 * pow(1 - s, 2) * s, c = 3 * (1 - s) * s * s, e = s * s * s
                    cur.append((a * x0 + b * x1 + c * x2 + e * x3, a * y0 + b * y1 + c * y2 + e * y3))
                }
                pen = (x3, y3)
            case .close:
                if cur.count > 1 { list.append(cur) }
                cur = []
            }
        }
        if cur.count > 1 { list.append(cur) }
        polys.append(list)
    }
    func inside(_ list: [[(Double, Double)]], _ x: Double, _ y: Double) -> Bool {
        var w = 0
        for poly in list {
            for i in 0..<poly.count {
                let (x0, y0) = poly[i], (x1, y1) = poly[(i + 1) % poly.count]
                if (y0 <= y && y < y1) || (y1 <= y && y < y0) {
                    if x0 + (y - y0) / (y1 - y0) * (x1 - x0) > x { w += y1 > y0 ? 1 : -1 }
                }
            }
        }
        return w != 0
    }
    var grid = [[Double]](repeating: [Double](repeating: 0, count: width), count: height)
    for py in 0..<height {
        for px in 0..<width {
            var hit = 0
            for sy in 0..<4 {
                for sx in 0..<4 {
                    let x = Double(px) + (Double(sx) + 0.5) / 4, y = Double(py) + (Double(sy) + 0.5) / 4
                    if polys.contains(where: { inside($0, x, y) }) { hit += 1 }
                }
            }
            grid[py][px] = Double(hit) / 16
        }
    }
    return grid
}

func runMenuIconTests() {
    section("MenuIconTests")
    expect(MenuIconKind.allCases.count == 5, "five states")
    let green = HealthItem.allCases.map { iconVerdict($0, .green) }
    expect(MenuIconModel.kind(green, dataState: .fresh) == .normal, "all green is normal")
    expect(MenuIconModel.kind(green, dataState: .collecting) == .collecting, "collecting")
    expect(MenuIconModel.kind(green, dataState: .stale(now)) == .stale, "stale")
    var yellow = green
    yellow[0].level = .yellow
    yellow[0].since = now
    expect(MenuIconModel.kind(yellow, dataState: .fresh) == .caution, "yellow is caution")
    yellow[0].level = .red
    expect(MenuIconModel.kind(yellow, dataState: .fresh) == .alert, "red is alert")

    // 9.2 table: posture, badge, data mark and template flag of each state (v3: no template image, DESIGN_V3.md 4.2).
    let table: [(MenuIconKind, MenuPosture, Bool, MenuMark?, Bool)] = [
        (.normal, .relaxed, false, nil, false), (.caution, .raised, true, nil, false), (.alert, .pant, true, nil, false),
        (.collecting, .hollow, false, .collecting, false), (.stale, .hollow, false, .stale, false),
    ]
    for (kind, posture, hasBadge, mark, template) in table {
        expect(kind.posture == posture, "\(kind.rawValue): posture \(posture.rawValue)")
        expect(kind.isTemplate == template, "\(kind.rawValue): template \(template)")
        expect((kind.badgeToken != nil) == hasBadge, "\(kind.rawValue): colored badge \(hasBadge)")
        for item in HealthItem.allCases {
            let s = MenuIconModel.state(for: kind, item: item)
            expect(s.kind == kind && s.posture == posture && s.mark == mark && (s.badge != nil) == hasBadge,
                   "\(kind.rawValue)/\(item.rawValue): state round trip")
        }
    }
    expect(MenuIconKind.caution.badgeToken == .warning && MenuIconKind.alert.badgeToken == .danger, "tokens: yellow warning, red danger")

    // The model state and its kind agree for every data state and level.
    for item in HealthItem.allCases {
        for level in [HealthLevel.yellow, .red] {
            let v = [iconVerdict(item, level, minutes: 5)] + green.filter { $0.item != item }
            let s = MenuIconModel.state(v, dataState: .fresh)
            expect(s.kind == MenuIconModel.kind(v, dataState: .fresh) && s.badge?.item == item,
                   "\(item.rawValue) \(level.rawValue): state kind equals kind, badge item")
            expect(s.mark == nil, "\(item.rawValue) \(level.rawValue): no data mark")
        }
    }
    expect(MenuIconModel.state(yellow, dataState: .collecting) == MenuIconState(posture: .hollow, badge: nil, mark: .collecting),
           "collecting hides the problem: hollow, ellipsis")
    expect(MenuIconModel.state(yellow, dataState: .stale(now)) == MenuIconState(posture: .hollow, badge: nil, mark: .stale),
           "stale hides the problem: hollow, clock")
    expect(MenuIconModel.state(green, dataState: .collecting) != MenuIconModel.state(green, dataState: .stale(now)),
           "collecting and stale are different states")

    // Labels (9.2) and the text that starts with them.
    expect(MenuIconModel.label(.normal, item: nil) == "MoleMonitor：一切正常", "label: normal")
    expect(MenuIconModel.label(.caution, item: .disk) == "MoleMonitor：磁盘需要留意", "label: caution")
    expect(MenuIconModel.label(.alert, item: .disk) == "MoleMonitor：磁盘异常", "label: alert")
    expect(MenuIconModel.label(.caution, item: .cpu) == "MoleMonitor：CPU 需要留意", "label: caution, Latin name")
    expect(MenuIconModel.label(.collecting, item: nil) == "MoleMonitor：正在采集", "label: collecting")
    expect(MenuIconModel.label(.stale, item: nil) == "MoleMonitor：数据已过期", "label: stale")
    let diskY = [iconVerdict(.disk, .yellow, minutes: 10)] + green.filter { $0.item != .disk }
    let diskR = [iconVerdict(.disk, .red, minutes: 10)] + green.filter { $0.item != .disk }
    expect(MenuIconModel.text(green, dataState: .fresh, now: now).hasPrefix(MenuIconModel.label(.normal, item: nil)), "text starts with the label: normal")
    expect(MenuIconModel.text(diskY, dataState: .fresh, now: now).hasPrefix("MoleMonitor：磁盘需要留意"), "text starts with the label: caution")
    expect(MenuIconModel.text(diskR, dataState: .fresh, now: now).hasPrefix("MoleMonitor：磁盘异常"), "text starts with the label: alert")
    expect(MenuIconModel.text(green, dataState: .collecting, now: now).hasPrefix("MoleMonitor：正在采集"), "text starts with the label: collecting")
    expect(MenuIconModel.text(green, dataState: .stale(now), now: now).hasPrefix("MoleMonitor：数据已过期"), "text starts with the label: stale")
    expect(!MenuIconModel.text(diskY, dataState: .fresh, now: now).contains("需留意，"), "text: the old wording is gone")

    // Colors (DESIGN_V2.md 3.3) and contrast on the reference bars (9.3: at least 3:1).
    expect(MenuIconPalette.hex(.warning, dark: false) == 0xC26400 && MenuIconPalette.hex(.warning, dark: true) == 0xFF9F0A, "dot.warning")
    expect(MenuIconPalette.hex(.danger, dark: false) == 0xE5302A && MenuIconPalette.hex(.danger, dark: true) == 0xFF453A, "dot.danger")
    expect(abs(IconMetrics.contrast(0xFFFFFF, 0x000000) - 21) < 0.01 && abs(IconMetrics.contrast(0x777777, 0x777777) - 1) < 1e-9, "contrast: WCAG ends")
    for token in MenuIconPalette.Token.allCases {
        for dark in [false, true] {
            let c = IconMetrics.contrast(MenuIconPalette.hex(token, dark: dark), MenuIconPalette.bar(dark: dark))
            expect(c >= IconMetrics.badgeContrastPass, "\(token.rawValue) \(dark ? "dark" : "light"): contrast \(String(format: "%.2f", c)) >= 3")
        }
    }
    expect(IconMetrics.fiveStatePass == 0.20 && IconMetrics.badgePass == 0.35 && IconMetrics.alarmPass == 0.30
           && IconMetrics.headInkTolerance == 8, "gate thresholds of 9.3 and 13.2.1 are unchanged")

    // Data marks at 1x: inside the 8 x 8 pt box, not empty, apart from each other and from every category glyph.
    var grids = [(String, [[Double]])]()
    for mark in MenuMark.allCases {
        let g = iconGrid(DogArt.mark(mark), width: 8, height: 8)
        let solid = g.joined().filter { $0 >= IconMetrics.solidThreshold }.count
        expect(solid >= 6, "\(mark.rawValue): mark has \(solid) solid px at 1x")
        var inBox = true
        for part in DogArt.mark(mark) {
            for op in part.ops {
                switch op {
                case .move(let x, let y), .line(let x, let y): inBox = inBox && (0...8).contains(x) && (0...8).contains(y)
                case .cubic(_, _, _, _, let x, let y): inBox = inBox && (0...8).contains(x) && (0...8).contains(y)
                case .close: break
                }
            }
        }
        expect(inBox, "\(mark.rawValue): mark inside the 8 x 8 pt box")
        grids.append((mark.rawValue, g))
    }
    for item in HealthItem.allCases { grids.append((item.rawValue, iconGrid(DogArt.badge(item), width: 8, height: 8))) }
    let m = IconMetrics.matrix(grids)
    for (pair, r) in m.pairs where pair.contains("collecting") || pair.contains("stale") {
        expect(r >= IconMetrics.badgePass, "mark XOR \(pair) \(String(format: "%.3f", r)) >= 0.35")
    }
}
