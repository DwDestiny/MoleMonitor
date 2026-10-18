// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts and the data state (docs/DESIGN_V2.md 9.2, 9.3; docs/DESIGN.md 3.2, 3.6).
// Output: The five menu bar icon states (kind, posture, badge, data mark), the accessibility text, the badge color tokens,
//         and the 1x legibility metrics (XOR ratio, WCAG contrast) with their gate thresholds (W08, A, M14).
// Pos: Pure mapping from health to icon; no drawing. Foundation only. Owner WP-E.
//      v3 (U10, docs/DESIGN_V3.md 4.2): the icon is the runner silhouette (MenuRunner.swift). Health shows only as the mark
//      (yellow triangle, red square); the data states draw the hollow outline. `MenuPosture` is now only the name of the
//      level in a state (no head art follows it); it stays until P1 and P3 drop DogGallery and the old icon gates.

import Foundation

/// The level name of a state: normal (relaxed), yellow (raised), red (pant), data state (hollow). v3 draws no posture.
enum MenuPosture: String, CaseIterable { case relaxed, raised, pant, hollow }
struct MenuBadge: Hashable { var item: HealthItem }   // The category of the worst problem; the posture and the color show the level

/// The two data states (DESIGN_V3.md 4.2): collecting draws the hollow dog with no mark, stale adds a hollow small
/// circle in the mark box (MenuRunnerArt.staleRing). The cases name the state, not a glyph.
/// The mark is drawn in the menu bar text color, next to the hollow head.
enum MenuMark: String, CaseIterable { case collecting, stale }

struct MenuIconState: Hashable {
    var posture: MenuPosture
    var badge: MenuBadge?
    /// Collecting or stale only (with the hollow posture). Nil in the three health states.
    var mark: MenuMark? = nil

    /// The v2 state of this value (DESIGN_V2.md 9.2).
    var kind: MenuIconKind {
        if let mark { return mark == .collecting ? .collecting : .stale }
        guard badge != nil else { return .normal }
        return posture == .pant ? .alert : .caution
    }
}

/// The five states of the v2 menu bar icon (DESIGN_V2.md 9.2). `MenuIconState` is the drawable value of a state:
/// `MenuIconModel.state` gives it, and `MenuIconState.kind` maps it back.
enum MenuIconKind: String, CaseIterable {
    case normal, caution, alert, collecting, stale

    /// The head posture of the state (9.2 table).
    var posture: MenuPosture {
        switch self {
        case .normal: return .relaxed
        case .caution: return .raised
        case .alert: return .pant
        case .collecting, .stale: return .hollow
        }
    }

    /// v3 (DESIGN_V3.md 4.2): no state is a template image. The body is drawn in the button's `labelColor` and the
    /// yellow and red marks keep their colors, in every state.
    var isTemplate: Bool { false }

    /// The badge color token (DESIGN_V2.md 3.3), or nil for the menu bar text color.
    var badgeToken: MenuIconPalette.Token? {
        switch self {
        case .caution: return .warning
        case .alert: return .danger
        default: return nil
        }
    }
}

/// Badge colors of DESIGN_V2.md 3.3 (`dot.warning`, `dot.danger`) and the reference menu bar colors of the contrast gate.
/// The App resolves light or dark from the menu bar appearance at draw time.
enum MenuIconPalette {
    enum Token: String, CaseIterable { case warning, danger }

    static func hex(_ token: Token, dark: Bool) -> UInt32 {
        switch token {
        case .warning: return dark ? 0xFF9F0A : 0xC26400
        case .danger: return dark ? 0xFF453A : 0xE5302A
        }
    }

    /// Reference menu bar colors (the gallery bar backgrounds): the gate W08 needs contrast >= 3:1 on both.
    static func bar(dark: Bool) -> UInt32 { dark ? 0x252527 : 0xF2F2F2 }
    /// Informational backgrounds (not gated): the selected highlight and wallpaper-tinted bars (the gallery mock-up).
    static let lightExtras: [(String, UInt32)] = [("selected", 0xDCDCDC), ("wallpaperWarm", 0xD9C7A6)]
    static let darkExtras: [(String, UInt32)] = [("selected", 0x47474A), ("wallpaperBlue", 0x5B7DB1)]
}

enum MenuIconModel {
    /// The v2 state: collecting and stale are separate, yellow is `caution`, red is `alert`. The worst problem decides
    /// (ProblemOrder puts red first). Equal to `state(verdicts, dataState:).kind`.
    static func kind(_ verdicts: [ItemVerdict], dataState: DataState) -> MenuIconKind {
        switch dataState {
        case .collecting: return .collecting
        case .stale: return .stale
        case .fresh: break
        }
        guard let first = ProblemOrder.problems(verdicts).first else { return .normal }
        return first.level == .red ? .alert : .caution
    }

    /// The drawable value of a state for one badge item (`item` is used by caution and alert only). Round trip:
    /// `state(for: k, item: i).kind == k`.
    static func state(for kind: MenuIconKind, item: HealthItem) -> MenuIconState {
        switch kind {
        case .normal: return MenuIconState(posture: .relaxed, badge: nil)
        case .caution: return MenuIconState(posture: .raised, badge: MenuBadge(item: item))
        case .alert: return MenuIconState(posture: .pant, badge: MenuBadge(item: item))
        case .collecting: return MenuIconState(posture: .hollow, badge: nil, mark: .collecting)
        case .stale: return MenuIconState(posture: .hollow, badge: nil, mark: .stale)
        }
    }

    /// Collecting or stale: hollow, no badge, the data mark. Otherwise the worst level picks the posture and the first problem item
    /// in ProblemOrder picks the badge (DESIGN.md 3.2).
    static func state(_ verdicts: [ItemVerdict], dataState: DataState) -> MenuIconState {
        switch dataState {
        case .collecting: return MenuIconState(posture: .hollow, badge: nil, mark: .collecting)
        case .stale: return MenuIconState(posture: .hollow, badge: nil, mark: .stale)
        case .fresh: break
        }
        guard let first = ProblemOrder.problems(verdicts).first else {
            return MenuIconState(posture: .relaxed, badge: nil)
        }
        let posture: MenuPosture = (first.level == .red) ? .pant : .raised
        return MenuIconState(posture: posture, badge: MenuBadge(item: first.item))
    }

    /// The accessibility label of a state (DESIGN_V2.md 9.2 table), without the end mark. `item` is the badge item of
    /// caution and alert. The tooltip and VoiceOver text (`text`) start with this label.
    static func label(_ kind: MenuIconKind, item: HealthItem?) -> String {
        let name = item?.label ?? ""
        let latin = name.unicodeScalars.last.map { $0.isASCII } ?? false
        switch kind {
        case .normal: return "MoleMonitor：一切正常"
        case .caution: return "MoleMonitor：" + name + (latin ? " " : "") + "需要留意"
        case .alert: return "MoleMonitor：" + name + (latin ? " " : "") + "异常"
        case .collecting: return "MoleMonitor：正在采集"
        case .stale: return "MoleMonitor：数据已过期"
        }
    }

    /// Tooltip and VoiceOver text (DESIGN.md 3.6, DESIGN_V2.md 9.2): one problem starts with the 9.2 label; more problems
    /// give the count, then each problem item in ProblemOrder; then the normal items.
    static func text(_ verdicts: [ItemVerdict], dataState: DataState, now: Date) -> String {
        switch dataState {
        case .collecting:
            return label(.collecting, item: nil) + "。"
        case .stale(let last):
            return label(.stale, item: nil) + "，最后数据 \(clock(last))。"
        case .fresh:
            break
        }
        let problems = ProblemOrder.problems(verdicts)
        let normals = verdicts
            .filter { $0.level == .green }
            .sorted { $0.item.fixedPriority < $1.item.fixedPriority }
            .map { $0.item.label }
        let joined = normals.joined(separator: "、")
        let latinEnd = joined.unicodeScalars.last.map { $0.isASCII } ?? false
        let normalText = normals.isEmpty ? "" : joined + (latinEnd ? " 正常。" : "正常。")
        if problems.isEmpty {
            return label(.normal, item: nil) + "。" + normalText
        }
        func name(_ v: ItemVerdict) -> String {
            let w = v.level == .red ? "异常" : "需要留意"
            let latin = v.item.label.unicodeScalars.last.map { $0.isASCII } ?? false
            return v.item.label + (latin ? " " : "") + w
        }
        func since(_ v: ItemVerdict) -> String {
            guard let s = v.since else { return "" }
            return "，已持续 " + duration(now.timeIntervalSince(s))
        }
        var text = "MoleMonitor："
        if problems.count == 1, let p = problems.first {
            let headline = p.headline.isEmpty ? "" : "，" + p.headline
            text += name(p) + headline + since(p) + "。"
        } else {
            text += "\(problems.count) 项需要处理。"
            for p in problems {
                text += name(p) + since(p) + "。"
            }
        }
        return text + normalText
    }

    /// "3 小时 12 分", "25 分", "不到 1 分", "2 天 3 小时".
    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 1 { return "不到 1 分" }
        if m < 60 { return "\(m) 分" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) 小时" : "\(h) 小时 \(m % 60) 分" }
        return h % 24 == 0 ? "\(h / 24) 天" : "\(h / 24) 天 \(h % 24) 小时"
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// The 1x legibility metric of DESIGN.md 3.3 and 9.4 G1-4 and G1-5, and the five-state gates of DESIGN_V2.md 9.3 (W08).
enum IconMetrics {
    /// Five states pairwise at 1x (W08, DESIGN_V2.md 9.3).
    static let fiveStatePass = 0.20
    /// Yellow and red badges against the reference menu bars (W08): WCAG contrast at least this ratio.
    static let badgeContrastPass = 3.0
    /// Head ink of a non-template icon against the menu bar text color: each channel within this value (0 to 255, gate A).
    static let headInkTolerance = 8.0

    /// WCAG 2 relative luminance of an sRGB color 0xRRGGBB.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// WCAG 2 contrast ratio of two opaque sRGB colors (1 to 21).
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A pixel is solid when its alpha is at least this value.
    static let solidThreshold = 0.5
    /// Badge glyphs pass at this ratio (G1-5), postures at 0.20 (G1-4).
    static let badgePass = 0.35
    static let posturePass = 0.20
    /// Relaxed against raised must reach this ratio (round 2, I2): "attention" has to read at 1x on its own.
    static let relaxedRaisedPass = 0.25
    /// Alarm discs (red level, 9 x 9 pt, glyph knocked out) pass at this ratio (round 3, I2). A knockout in a
    /// 9 px disc has less room than an 8 px glyph on an empty box, so the gate is lower than badgePass; the
    /// level itself reads from the shape (solid disc against open glyph), not from this ratio.
    static let alarmPass = 0.30

    /// Card legs (round 3, I2): rows 38 to 49 of the 72 x 54 pt card at 1x (y 63 to 83 u) hold the legs.
    /// stand, walk and trot must differ there by this ratio, a lifted paw must clear the ground by `pawLiftPx`,
    /// the body must bob by `bobPx`, and the bubble must keep `bubbleGapPx` off the fur.
    static let cardLegRows = 38..<50
    static let cardLegPass = 0.30
    static let pawLiftPx = 6.0
    static let bobPx = 2.0
    static let bubbleMinPx = 14.0
    static let bubbleGapPx = 2.0

    /// xorRatio over the rows `rows` only.
    static func bandRatio(_ a: [[Double]], _ b: [[Double]], rows: Range<Int>) -> Double {
        xorRatio(Array(a[rows]), Array(b[rows]))
    }

    /// XOR pixel count divided by the larger solid pixel count. Inputs are alpha grids of the same size.
    static func xorRatio(_ a: [[Double]], _ b: [[Double]]) -> Double {
        var x = 0, na = 0, nb = 0
        for (ra, rb) in zip(a, b) {
            for (va, vb) in zip(ra, rb) {
                let sa = va >= solidThreshold, sb = vb >= solidThreshold
                if sa { na += 1 }
                if sb { nb += 1 }
                if sa != sb { x += 1 }
            }
        }
        return Double(x) / Double(max(na, nb, 1))
    }

    /// Pairwise ratios of the grids, keyed "a/b" for the given names, and the smallest value.
    static func matrix(_ grids: [(String, [[Double]])]) -> (pairs: [String: Double], minimum: Double) {
        var pairs = [String: Double]()
        var minimum = Double.infinity
        for i in 0..<grids.count {
            for j in (i + 1)..<grids.count {
                let r = xorRatio(grids[i].1, grids[j].1)
                pairs[grids[i].0 + "/" + grids[j].0] = r
                minimum = min(minimum, r)
            }
        }
        return (pairs, minimum.isFinite ? minimum : 0)
    }
}
