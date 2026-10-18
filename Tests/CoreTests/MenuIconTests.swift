// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the five menu bar icon states (docs/DESIGN_V2.md 9.2, 9.3, gate W08): kind mapping, state
//         round trip, template flag, labels and text, color tokens and contrast, the data marks
//         (collecting none, stale ring, R3).
// Pos: Called from main.swift via runMenuIconTests(); no top-level code in this file. A1 registers it, WP-E fills it.
//      The pixel gates on the real Core Graphics drawing are in the App (DogGallery `--dog-gallery`, UITestIconChecks W08).

import Foundation

private func iconVerdict(_ item: HealthItem, _ level: HealthLevel, minutes: Double? = nil, headline: String = "") -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: "x", headline: headline,
                since: minutes.map { now.addingTimeInterval(-$0 * 60) }, levelChangedAt: nil, alert: nil)
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

    // Data marks (R3, DESIGN_V3.md 4.2): collecting has no mark; stale is a hollow small circle in the mark box.
    expect(!MenuRunnerArt.hasDataMark(.collecting) && MenuRunnerArt.hasDataMark(.stale), "only stale draws a data mark")
    let ring = MenuRunnerArt.staleRing, o = MenuRunnerArt.markOrigin, side = MenuRunnerArt.markSize
    expect(ring.x - ring.outer >= o.x && ring.x + ring.outer <= o.x + side && ring.y - ring.outer >= o.y
           && ring.y + ring.outer <= o.y + side, "stale ring inside the 6.5 x 6.5 pt mark box")
    expect(ring.outer * 2 >= 6.0 && abs(ring.line - 1.2) < 1e-9, "stale ring about 6.5 pt across, 1.2 pt line")
    // At 1x: a ring of whole pixels with an open centre (a hollow circle, no hands).
    var ringPx = 0
    for y in 0..<18 {
        for x in 0..<24 {
            var hits = 0
            for sy in 0..<4 { for sx in 0..<4 {
                if MenuRunnerArt.staleRingContains(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4) { hits += 1 }
            } }
            if hits >= 8 { ringPx += 1 }
        }
    }
    expect(ringPx >= 14, "stale ring has \(ringPx) solid px at 1x")
    expect(!MenuRunnerArt.staleRingContains(ring.x, ring.y) && !MenuRunnerArt.staleRingContains(ring.x + 0.9, ring.y - 0.9),
           "stale ring centre is open (no clock hands)")
}
