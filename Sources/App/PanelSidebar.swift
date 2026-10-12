// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel and the item whose sidebar is open.
// Output: The sidebar column (320 pt wide): header, range control, chart, stats, capacity area, ranking, footnotes, and the anomaly log.
// Pos: Right or left column of the panel (docs/DESIGN_V2.md 6). It is built only while the sidebar is open, so closing releases it.

import AppKit
import SwiftUI

// MARK: - Icons

/// App icons by bundle id, kept for the life of the process. Static renders skip the lookup, so previews stay the same everywhere.
enum AppIconCache {
    private static let lock = NSLock()
    private static var icons = [String: NSImage]()
    private static var missing = Set<String>()

    static func icon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = icons[bundleID] { return hit }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[bundleID] = image
        return image
    }
}

struct AppIconView: View {
    let app: AppUsage
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    private var symbol: String {
        if app.isSystem { return "gearshape" }
        return app.bundleID == nil ? "terminal" : "app"
    }

    var body: some View {
        Group {
            if !snapshot, let image = AppIconCache.icon(bundleID: app.bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tok.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Hatch

/// Diagonal lines at 45 degrees, 2 pt wide, for the purgeable part of the disk bar.
private struct HatchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        return p
    }
}

// MARK: - Header and controls

private struct SidebarHeader: View {
    @ObservedObject var model: PanelModel
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    private var levelTag: (String, Color)? {
        guard state.item != .anomalyLog else { return nil }
        switch state.level {
        case .red: return ("异常", tok.textDanger)
        case .yellow: return ("留意", tok.textWarning)
        case .green: return ("正常", tok.textSecondary)
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(state.item.label)
                .font(PanelType.sideTitle)
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("side.title")
                .uiTestFrame("side.title")
            if let tag = levelTag {
                Text(tag.0).font(PanelType.rowNote).foregroundStyle(tag.1)
            }
            if model.pinnedItem == state.item {
                Text("已固定").font(PanelType.rowNote).foregroundStyle(tok.textSecondary)
                    .accessibilityIdentifier("side.pinned")
            }
            Spacer(minLength: 0)
            Button(action: { model.unpinSidebar() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tok.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .sidebarClose ? 1 : 0))
            .accessibilityLabel(Text("关闭侧栏"))
            .accessibilityIdentifier("btn.sideClose")
            .uiTestFrame("btn.sideClose")
        }
        .frame(width: PanelMetrics.sidebarContentWidth, height: 44)
    }
}

private struct SidebarRangeControl: View {
    @ObservedObject var model: PanelModel
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    var body: some View {
        let options = SidebarRange.options(for: state.item)
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(options, id: \.rawValue) { option in
                    Button(action: { model.setRange(option, for: state.item) }) {
                        Text(option.label)
                            .font(PanelType.rowNote)
                            .foregroundStyle(option == state.range ? tok.accent : tok.textSecondary)
                            .frame(width: 58, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option == state.range ? tok.fillSelected : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("时间范围 " + option.label))
                    .accessibilityAddTraits(option == state.range ? .isSelected : [])
                    .accessibilityIdentifier("btn.range." + option.rawValue)
                    .uiTestFrame("btn.range." + option.rawValue)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tok.chartFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .sidebarRange ? 1 : 0))
            if let chart = state.chart, let text = chart.recordedText {
                Text(text)
                    .font(PanelType.sideStatLabel)
                    .foregroundStyle(tok.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("side.recorded")
            }
            Spacer(minLength: 0)
        }
        .frame(width: PanelMetrics.sidebarContentWidth, height: 28, alignment: .leading)
    }
}

// MARK: - Stats

private struct SidebarStatsRow: View {
    let stats: [SidebarStat]
    @Environment(\.tok) private var tok

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label)
                        .font(PanelType.sideStatLabel)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(1)
                    Text(stat.value)
                        .font(PanelType.sideStat)
                        .foregroundStyle(tok.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .uiTestFrame("side.stat.\(index)")
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: PanelMetrics.sidebarContentWidth, height: 44, alignment: .topLeading)
        .uiTestFrame("side.stats")
    }
}

// MARK: - Capacity

private struct CapacityArea: View {
    let cap: CapacityText
    let item: SidebarItem
    let level: HealthLevel
    @Environment(\.tok) private var tok

    private var problem: Bool { level == .red || level == .yellow }
    private var base: Color { tok.dark ? Color.white : Color.black }

    private func segmentColor(_ kind: CapacitySegment.Kind) -> Color {
        let hot: Color = level == .red ? tok.lampDanger : tok.lampWarning
        switch kind {
        case .used, .app: return problem ? hot : base.opacity(0.55)
        case .wired: return problem ? hot.opacity(0.7) : base.opacity(0.38)
        case .compressed: return problem ? hot.opacity(0.45) : base.opacity(0.24)
        case .purgeable: return base.opacity(0.24)
        case .free: return tok.chartFill
        }
    }

    private var bar: some View {
        let width = PanelMetrics.sidebarContentWidth
        return Group {
            if cap.isMissing {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tok.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(cap.segments.enumerated()), id: \.offset) { _, segment in
                        ZStack {
                            Rectangle().fill(segmentColor(segment.kind))
                            if segment.kind == .purgeable {
                                HatchShape().stroke(tok.textTertiary, lineWidth: 1).clipped()
                            }
                        }
                        .frame(width: max(0, CGFloat(segment.fraction) * width))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .frame(width: width, height: 8)
        .accessibilityHidden(true)
        .uiTestFrame("cap.bar")
    }

    private func column(_ label: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(PanelType.sideStatLabel).foregroundStyle(tok.textSecondary)
            Text(value)
                .font(PanelType.sideStat)
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 95, alignment: .leading)
                .uiTestFrame(id)
        }
        .frame(width: 95, alignment: .leading)
    }

    private func swatch(_ kind: CapacitySegment.Kind, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(segmentColor(kind)).frame(width: 8, height: 8)
            Text(text).font(PanelType.sideStatLabel).foregroundStyle(tok.textSecondary).lineLimit(1)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            if item == .disk {
                swatch(.used, "已用")
                swatch(.purgeable, cap.purgeable.map { "可清除 " + $0 } ?? "可清除")
                swatch(.free, "立即可用")
            } else {
                swatch(.app, "App")
                swatch(.wired, "联动")
                swatch(.compressed, "压缩")
                swatch(.free, "可用")
            }
            Spacer(minLength: 0)
        }
        .opacity(cap.isMissing ? 0 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            HStack(spacing: 1) {
                column("总容量", cap.total, id: "cap.total")
                column("已用", cap.used, id: "cap.used")
                column("可用", cap.available, id: "cap.available")
            }
            legend
        }
        .frame(width: PanelMetrics.sidebarContentWidth, height: 76, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(cap.accessibilityText))
        .accessibilityIdentifier("cap.area")
        .uiTestFrame("cap.area")
    }
}

// MARK: - Ranking

private struct RankIcon: View {
    let row: RankRow
    let table: RankTable
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    private var symbol: String {
        if table.plain && row.bundleID == nil && table.title.hasPrefix("网卡") { return "network" }
        if row.isSystem { return "gearshape" }
        return row.bundleID == nil ? "app" : "app.fill"
    }

    var body: some View {
        Group {
            if !snapshot, let image = AppIconCache.icon(bundleID: row.bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tok.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct RankingView: View {
    let table: RankTable
    @Environment(\.tok) private var tok

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(table.title)
                .font(PanelType.section)
                .foregroundStyle(tok.textSecondary)
                .frame(height: 24, alignment: .leading)
                .accessibilityIdentifier("rank.title")
            if let empty = table.emptyText {
                Text(empty)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textTertiary)
                    .frame(height: 28, alignment: .leading)
                    .accessibilityIdentifier("rank.empty")
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 8) {
                    RankIcon(row: row, table: table)
                    Text(row.name)
                        .font(PanelType.rowName)
                        .foregroundStyle(tok.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.value)
                        .font(PanelType.duration)
                        .foregroundStyle(tok.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: PanelMetrics.sidebarContentWidth, height: 28)
                .overlay(alignment: .bottomLeading) {
                    if row.fraction > 0 {
                        Capsule().fill(tok.chartLine.opacity(0.5))
                            .frame(width: max(2, PanelMetrics.sidebarContentWidth * CGFloat(row.fraction)), height: 2)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(row.name + "，" + row.value + (row.detail.map { "，" + $0 } ?? "")))
                .accessibilityIdentifier("rank.\(index)")
                .uiTestFrame("rank.\(index)")
            }
        }
        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
        .uiTestFrame("side.rank")
    }
}

// MARK: - Anomaly log

private struct RecordsView: View {
    @ObservedObject var model: PanelModel
    let groups: [RecordGroup]
    @Environment(\.tok) private var tok

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pawprint").font(.system(size: 20)).foregroundStyle(tok.textTertiary)
                    Text("近 7 天没有异常记录").font(PanelType.rowName).foregroundStyle(tok.textTertiary)
                }
                .frame(width: PanelMetrics.sidebarContentWidth, height: 120)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rec.empty")
            }
            ForEach(groups) { group in
                Text(group.title).font(PanelType.section).foregroundStyle(tok.textSecondary).frame(height: 20, alignment: .leading)
                ForEach(group.rows) { row in
                    Button(action: { model.openRecord(row) }) {
                        HStack(spacing: 8) {
                            StatusDotView(dot: row.level == .red ? .red : .yellow).frame(width: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(PanelType.rowName).foregroundStyle(tok.textPrimary).lineLimit(1)
                                Text(row.evidence).font(PanelType.rowNote).foregroundStyle(tok.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(row.span).font(PanelType.rowNote).foregroundStyle(row.ongoing ? tok.accent : tok.textSecondary).lineLimit(1)
                                Text(row.duration).font(PanelType.rowNote).foregroundStyle(tok.textSecondary).lineLimit(1)
                            }
                        }
                        .frame(width: PanelMetrics.sidebarContentWidth, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("异常记录 " + row.title + "，" + row.evidence + "，" + row.span + "，" + row.duration))
                    .accessibilityIdentifier("btn.record." + row.id)
                }
            }
        }
        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
    }
}

// MARK: - Sidebar

struct PanelSidebarView: View {
    @ObservedObject var model: PanelModel
    let item: SidebarItem
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    @ViewBuilder
    private func content(_ state: SidebarContentState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let chart = state.chart {
                ChartPanel(data: chart, level: state.level)
            }
            if state.item != .anomalyLog {
                SidebarStatsRow(stats: state.stats)
            } else {
                SidebarStatsRow(stats: state.stats)
                RecordsView(model: model, groups: state.groups)
            }
            if let cap = state.capacity {
                CapacityArea(cap: cap, item: state.item, level: state.level)
            }
            if let table = state.ranking {
                RankingView(table: table)
            }
            if !state.footnotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(state.footnotes.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(PanelType.rowNote)
                            .foregroundStyle(tok.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
                .accessibilityIdentifier("side.footnote")
                .uiTestFrame("side.footnote")
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
    }

    var body: some View {
        let state = model.sidebarContent(for: item)
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(model: model, state: state)
            SidebarRangeControl(model: model, state: state)
            if snapshot {
                content(state)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) { content(state) }
            }
        }
        .padding(.horizontal, PanelMetrics.sidebarPadding)
        .frame(width: PanelMetrics.sidebarWidth, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }
}
