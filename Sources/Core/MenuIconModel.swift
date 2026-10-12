// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts and the data state (docs/DESIGN.md 3.2, 3.3, 3.6, 8.1).
// Output: The menu bar icon state (posture and badge), its accessibility text, and the 1x XOR ratio metric (3.3, 9.4 G1).
// Pos: Pure mapping from health to icon; no drawing. Foundation only. Owner I2.

import Foundation

enum MenuPosture: String, CaseIterable { case relaxed, raised, pant, hollow }   // Ears relaxed, ears raised, tongue out, hollow
struct MenuBadge: Hashable { var item: HealthItem }   // The badge shows the category only, not yellow or red
struct MenuIconState: Hashable {
    var posture: MenuPosture
    var badge: MenuBadge?
}

/// The five states of the v2 menu bar icon (DESIGN_V2.md 9.2). Named `MenuIconKind` because `MenuIconState`
/// is the existing posture-and-badge value used by the renderer. WP-E may map one to the other.
enum MenuIconKind: String, CaseIterable {
    case normal, caution, alert, collecting, stale
}

enum MenuIconModel {
    /// The v2 state: collecting and stale are separate, yellow is `caution`, red is `alert`.
    static func kind(_ verdicts: [ItemVerdict], dataState: DataState) -> MenuIconKind {
        switch dataState {
        case .collecting: return .collecting
        case .stale: return .stale
        case .fresh: break
        }
        guard let first = ProblemOrder.problems(verdicts).first else { return .normal }
        return first.level == .red ? .alert : .caution
    }

    /// Collecting or stale: hollow, no badge. Otherwise the worst level picks the posture and the first problem item
    /// in ProblemOrder picks the badge (DESIGN.md 3.2).
    static func state(_ verdicts: [ItemVerdict], dataState: DataState) -> MenuIconState {
        switch dataState {
        case .collecting, .stale: return MenuIconState(posture: .hollow, badge: nil)
        case .fresh: break
        }
        guard let first = ProblemOrder.problems(verdicts).first else {
            return MenuIconState(posture: .relaxed, badge: nil)
        }
        let posture: MenuPosture = (first.level == .red) ? .pant : .raised
        return MenuIconState(posture: posture, badge: MenuBadge(item: first.item))
    }

    /// Tooltip and VoiceOver text (DESIGN.md 3.6): problem items in ProblemOrder, then the normal items.
    static func text(_ verdicts: [ItemVerdict], dataState: DataState, now: Date) -> String {
        switch dataState {
        case .collecting:
            return "MoleMonitor：正在统计。"
        case .stale(let last):
            return "MoleMonitor：数据已过期，最后数据 \(clock(last))。"
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
            return "MoleMonitor：一切正常。" + normalText
        }
        func name(_ v: ItemVerdict) -> String {
            let w = v.level == .red ? "异常" : "需留意"
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

/// The 1x legibility metric of DESIGN.md 3.3 and 9.4 G1-4 and G1-5.
enum IconMetrics {
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
