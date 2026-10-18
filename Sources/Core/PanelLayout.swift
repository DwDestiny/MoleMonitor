// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts and the battery flag (docs/DESIGN_V3.md 3.3, 5).
// Output: A PanelLayoutPlan: the row order, the anomaly items, the exact panel height (all green, 6 items: 264 pt with the 64 pt headline block).
// Pos: Pure layout planning of the panel; the SwiftUI views only render the plan. Foundation only.
//      The height changes with the number of expanded problem rows (at most 3) and the battery flag. The hero height is read from PanelMetrics.hero.

import Foundation

enum PanelMetrics {
    // Widths (DESIGN_V2.md 2.2)
    static let width = 352.0, padding = 16.0, contentWidth = 320.0
    static let sidebarWidth = 320.0, sidebarPadding = 16.0, sidebarContentWidth = 287.0
    static let widthWithSidebar = 672.0
    static let windowRadius = 12.0
    // Heights (DESIGN_V3.md 3.3). `hero` and `heroGap` are owned by the hero package; the formula only reads them.
    static let topPadding = 12.0, hero = 64.0, heroGap = 8.0
    /// Problem row: 64 pt, 4 pt between two, at most 3 expanded (the fourth problem falls back to the quiet style).
    static let problemRow = 64.0, problemRowGap = 4.0, maxProblemRows = 3
    /// Quiet row: 28 pt, two columns.
    static let quietRow = 28.0, quietColumns = 2
    static let rowsToRecordGap = 12.0, recordRow = 28.0
    static let recordToFooterGap = 12.0, footer = 32.0, bottomPadding = 12.0
    // Row geometry (DESIGN_V3.md 5.1, 5.2)
    static let rowBackgroundWidth = 336.0
    /// Inset of the content inside a row: the dot starts here and the value ends here.
    static let rowInset = 16.0
    static let curveHeight = 16.0
    static let dotColumn = 8.0, dotGap = 8.0, textColumn = 120.0, valueColumn = 92.0
    // Footer (DESIGN_V3.md 5.4): the "..." button is 32 x 32, the primary button takes the rest of the 336 pt line.
    static let moreButtonWidth = 32.0, footerGap = 8.0
    static let primaryButtonWidth = rowBackgroundWidth - moreButtonWidth - footerGap
}

/// What the sidebar shows (DESIGN_V2.md 6): the 6 breakdown items and the anomaly log.
enum SidebarItem: String, Codable, CaseIterable {
    case cpu, memory, disk, network, battery, thermal
    case anomalyLog = "anomaly_log"

    /// Chinese name on the sidebar title.
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .network: return "网络"
        case .battery: return "电池"
        case .thermal: return "温度"
        case .anomalyLog: return "异常记录"
        }
    }

    /// The health item behind a breakdown row. Network and the anomaly log have none.
    var healthItem: HealthItem? {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .battery: return .power
        case .thermal: return .thermal
        case .network, .anomalyLog: return nil
        }
    }

    init(_ item: HealthItem) {
        switch item {
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .disk: self = .disk
        case .power: self = .battery
        case .thermal: self = .thermal
        }
    }

    /// The six breakdown rows in the fixed order of DESIGN_V2.md 5.2 rule 2.
    static let fixedRows: [SidebarItem] = [.cpu, .memory, .disk, .network, .battery, .thermal]
}

/// Side on which the sidebar opens (DESIGN_V2.md 10.4). It is fixed while the panel is open.
enum SidebarEdge: String, Equatable {
    case left, right
}

enum PanelSection: Equatable {
    case hero
    case rows
    case anomaly
    case footer
    // COMPAT: the v1 cases below are never produced. Only PanelRoot.swift (WP-C) still names them.
    // TODO(WP-C): remove these two cases and their PanelRoot switch arms.
    case problemCard(HealthItem, compact: Bool, evidenceHeight: Double)
    case problemRow(HealthItem, compact: Bool)
}

struct PanelLayoutInput: Equatable {
    var verdicts: [ItemVerdict]
    /// False for a desktop Mac: the battery row is left out (DESIGN_V2.md 5.3 rule 4).
    var hasBattery: Bool

    init(verdicts: [ItemVerdict], hasBattery: Bool = true) {
        self.verdicts = verdicts
        self.hasBattery = hasBattery
    }
}

struct PanelLayoutPlan: Equatable {
    /// Rows in display order (5 or 6 entries, never the anomaly log). The first `problemRowCount` entries use the problem style.
    var rows: [SidebarItem]
    /// Problem items in `ProblemOrder` order. All of them, also when more than 3.
    var anomalies: [HealthItem]
    var height: Double

    var quiet: Bool { anomalies.isEmpty }
    var sections: [PanelSection] { [.hero, .rows, .anomaly, .footer] }
    /// Number of expanded problem rows (0 to 3). Further problems keep their level shape and color in the quiet style.
    var problemRowCount: Int { min(PanelMetrics.maxProblemRows, anomalies.count) }
}

enum PanelLayout {
    /// Rows of the quiet grid for `count` items (two columns).
    static func quietGridRows(_ count: Int) -> Int {
        (max(0, count) + PanelMetrics.quietColumns - 1) / PanelMetrics.quietColumns
    }

    /// Height of the rows section (problem rows, then the quiet grid) for `itemCount` rows of which `problems` are anomalies.
    static func rowsHeight(itemCount: Int, problems: Int) -> Double {
        let expanded = min(PanelMetrics.maxProblemRows, max(0, problems), itemCount)
        let quietCount = itemCount - expanded
        var h = Double(quietGridRows(quietCount)) * PanelMetrics.quietRow
        if expanded > 0 {
            h += Double(expanded) * PanelMetrics.problemRow + Double(expanded - 1) * PanelMetrics.problemRowGap
        }
        return h
    }

    /// Total height of the panel in pt (DESIGN_V3.md 3.3). It changes with the number of expanded problem rows and the battery flag only.
    /// `hero` is a parameter so a test can check the formula for another hero height.
    static func height(hasBattery: Bool, problems: Int = 0, hero: Double = PanelMetrics.hero) -> Double {
        let items = hasBattery ? 6 : 5
        let parts: [Double] = [PanelMetrics.topPadding, hero, PanelMetrics.heroGap,
                               rowsHeight(itemCount: items, problems: problems),
                               PanelMetrics.rowsToRecordGap, PanelMetrics.recordRow,
                               PanelMetrics.recordToFooterGap, PanelMetrics.footer, PanelMetrics.bottomPadding]
        return parts.reduce(0, +)
    }

    /// The row order of DESIGN_V2.md 5.2: problem rows first (red before yellow, by `ProblemOrder`), then the normal
    /// rows in the fixed order CPU, memory, disk, network, battery, temperature.
    static func rowOrder(verdicts: [ItemVerdict], hasBattery: Bool) -> [SidebarItem] {
        var out = [SidebarItem]()
        for v in ProblemOrder.problems(verdicts) {
            let row = SidebarItem(v.item)
            if row == .battery && !hasBattery { continue }
            out.append(row)
        }
        for row in SidebarItem.fixedRows where !out.contains(row) {
            if row == .battery && !hasBattery { continue }
            out.append(row)
        }
        return out
    }

    /// Plan of the panel. The height depends only on the problem count and the battery flag.
    static func plan(_ input: PanelLayoutInput) -> PanelLayoutPlan {
        let anomalies = ProblemOrder.problems(input.verdicts).map { $0.item }.filter { item in
            item != .power || input.hasBattery
        }
        let rows = rowOrder(verdicts: input.verdicts, hasBattery: input.hasBattery)
        return PanelLayoutPlan(rows: rows, anomalies: anomalies,
                               height: height(hasBattery: input.hasBattery, problems: anomalies.count))
    }
}
