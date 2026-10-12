// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts and the battery flag (docs/DESIGN_V2.md 2.2, 2.3, 5.2, 7.2).
// Output: A PanelLayoutPlan: the row order, the anomaly rows, the exact panel height (524, 560, 604, 648 pt; desktop 40 pt less).
// Pos: Pure layout planning of the v2 panel; the SwiftUI views only render the plan. Foundation only. Owner WP-C.
//      The height depends on the number of anomalies and the battery flag only. Numbers never change it.

import Foundation

enum PanelMetrics {
    // Widths (DESIGN_V2.md 2.2)
    static let width = 352.0, padding = 16.0, contentWidth = 320.0
    static let sidebarWidth = 320.0, sidebarPadding = 16.0, sidebarContentWidth = 287.0
    static let widthWithSidebar = 672.0
    static let windowRadius = 12.0
    // Heights (DESIGN_V2.md 2.3)
    static let topPadding = 12.0, hero = 152.0, heroGap = 8.0
    static let row = 40.0, rowsToAnomalyGap = 12.0
    static let anomalyQuiet = 36.0, anomalyTitle = 28.0, anomalyItem = 44.0, anomalyMaxItems = 3
    static let anomalyToFooterGap = 12.0, footer = 40.0, bottomPadding = 12.0
    // Row columns (DESIGN_V2.md 5.1): 8 + 8 + 120 + 92 + 12 + 80 = 320
    static let dotColumn = 8.0, dotGap = 8.0, textColumn = 120.0, valueColumn = 92.0, sparkGap = 12.0
    static let sparkWidth = 80.0, sparkHeight = 24.0
    static let rowBackgroundWidth = 336.0
    // Footer (DESIGN_V2.md 8.1)
    static let primaryButtonWidth = 276.0, moreButtonWidth = 36.0, footerGap = 8.0
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
    // COMPAT: the v1 cases below are never produced. UITestBitmapChecks.swift (WP-D) still names them.
    // TODO(WP-D): remove these two cases after UITestBitmapChecks.swift drops M21 and M22.
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
    /// Rows in display order (5 or 6 entries, never the anomaly log).
    var rows: [SidebarItem]
    /// Problem items in `ProblemOrder` order. All of them, also when more than 3.
    var anomalies: [HealthItem]
    var height: Double

    var quiet: Bool { anomalies.isEmpty }
    /// Anomaly rows drawn: at most 3 (DESIGN_V2.md 7.2 rule 2).
    var anomalyRowCount: Int { min(anomalies.count, PanelMetrics.anomalyMaxItems) }
    /// More than 3 anomalies: the third row becomes "另有 N 项 ›", N = count - 2. Zero otherwise.
    var overflowCount: Int { anomalies.count > PanelMetrics.anomalyMaxItems ? anomalies.count - 2 : 0 }
    /// Anomaly rows that show an anomaly (the overflow row replaces the third).
    var shownAnomalies: [HealthItem] { overflowCount > 0 ? Array(anomalies.prefix(2)) : anomalies }
    var sections: [PanelSection] { [.hero, .rows, .anomaly, .footer] }
}

enum PanelLayout {
    /// Height of the anomaly area (DESIGN_V2.md 2.3).
    static func anomalyHeight(count: Int) -> Double {
        if count <= 0 { return PanelMetrics.anomalyQuiet }
        return PanelMetrics.anomalyTitle + PanelMetrics.anomalyItem * Double(min(count, PanelMetrics.anomalyMaxItems))
    }

    /// Total height of the panel in pt. The formula of DESIGN_V2.md 2.3.
    static func height(anomalyCount: Int, hasBattery: Bool) -> Double {
        let rows = Double(hasBattery ? 6 : 5) * PanelMetrics.row
        let parts: [Double] = [PanelMetrics.topPadding, PanelMetrics.hero, PanelMetrics.heroGap, rows,
                               PanelMetrics.rowsToAnomalyGap, anomalyHeight(count: anomalyCount),
                               PanelMetrics.anomalyToFooterGap, PanelMetrics.footer, PanelMetrics.bottomPadding]
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

    /// Plan of the panel. The height depends only on the anomaly count and the battery flag.
    static func plan(_ input: PanelLayoutInput) -> PanelLayoutPlan {
        let anomalies = ProblemOrder.problems(input.verdicts).map { $0.item }.filter { item in
            item != .power || input.hasBattery
        }
        let rows = rowOrder(verdicts: input.verdicts, hasBattery: input.hasBattery)
        return PanelLayoutPlan(rows: rows, anomalies: anomalies,
                               height: height(anomalyCount: anomalies.count, hasBattery: input.hasBattery))
    }
}
