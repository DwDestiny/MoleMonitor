// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel and the item whose sidebar is open.
// Output: The sidebar column (320 pt wide, docs/DESIGN_V3.md 6, 6.1): title row (level shape, name, range control, × when pinned),
//         a one-sentence summary, the one-line chart, the capacity bar, the top 5 list, and the anomaly log with its 7 day strip.
// Pos: Right or left column of the panel. It is built only while the sidebar is open, so closing releases it. The content fades in
//      and rises from the hovered row's height (motion.move; motion.fade under Reduce Motion). No stat blocks, pills or legends.
//      Column grid (SidebarGrid, Fable round 1 #4): every row of the sidebar starts at the content edge with a 16 pt glyph column
//      (level shape, app icon or interface icon, left aligned), and every name starts 24 pt in. Hover fills start 8 pt left of the content
//      edge, the same 8 pt relation as the main column's tint blocks and their glyphs.
//      App icons in the top 5 list (RankIcon): 16 pt and desaturated. Reason: in this panel color means level (red, yellow) and nothing
//      else; a full color Chrome or Xcode icon next to a red level shape competes with it and makes a normal list loud. The shape of
//      an app icon stays recognizable in gray at 16 pt, and the name beside it carries the identity.
//      The 7 day strip marks today with a 1 pt tick in text.tertiary: the lightest element of the strip, lighter than any anomaly mark.

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
        image.size = NSSize(width: 18, height: 18)
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

// MARK: - Grid

/// The column grid of the sidebar rows (see the file header).
private enum SidebarGrid {
    /// Width of the glyph column: the 16 pt app icon, and the 8 pt level shapes left aligned in it.
    static let glyph: CGFloat = 16
    /// Gap between the glyph column and the name.
    static let gap: CGFloat = 8
    /// The x of every name and every ranking bar, from the content edge.
    static let name: CGFloat = glyph + gap
}

// MARK: - Header

/// The level shape before the title: ■ red, ▲ yellow, ✓ normal, gray dot for network. The anomaly log and unknown levels have none.
private struct SidebarLevelMark: View {
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    var body: some View {
        Group {
            if state.item == .anomalyLog {
                EmptyView()
            } else if state.item == .network {
                // Network has no health level: the gray dot of the main column, not a check mark.
                StatusDotView(dot: .normal)
            } else if state.level == .red {
                StatusDotView(dot: .red)
            } else if state.level == .yellow {
                StatusDotView(dot: .yellow)
            } else if state.level == .green {
                Image(systemName: "checkmark")
                    .font(.system(size: PanelRowGlyph.checkSize, weight: .semibold))
                    .foregroundStyle(tok.textTertiary)
                    .frame(width: PanelRowGlyph.column, height: PanelRowGlyph.column)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Title row (docs/DESIGN_V3.md 6): level shape, name in type.lead, the range control right aligned, and × only when pinned.
private struct SidebarHeader: View {
    @ObservedObject var model: PanelModel
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    private var pinned: Bool { model.pinnedItem == state.item }

    var body: some View {
        HStack(spacing: 0) {
            if state.item != .anomalyLog {
                SidebarLevelMark(state: state)
                    .frame(width: SidebarGrid.name, alignment: .leading)
            }
            Text(state.item.label)
                .font(PanelType.lead)
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("side.title")
                .uiTestFrame("side.title")
            Spacer(minLength: 8)
            SidebarRangeControl(model: model, state: state)
            if pinned {
                Spacer().frame(width: 8)
                Button(action: { model.userClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tok.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarPlainHover())
                .overlay(RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
                    .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .sidebarClose ? 1 : 0))
                .accessibilityLabel(Text("关闭侧栏"))
                .accessibilityIdentifier("btn.sideClose")
                .uiTestFrame("btn.sideClose")
            }
        }
        .frame(width: PanelMetrics.sidebarContentWidth, height: 28)
    }
}

/// A plain button with the hover and pressed fills of the panel (radius 8, motion.feedback).
private struct SidebarPlainHover: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarHoverBody(configuration: configuration)
    }
}

private struct SidebarHoverBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @State private var hover = false

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
                .fill(configuration.isPressed ? tok.fillSelected : (hover ? tok.fillHover : Color.clear)))
            .onHover { hover = $0 }
            .animation(PanelMotion.feedback, value: hover)
    }
}

/// Segmented range control: 28 pt high, 11 pt text. The selected segment uses fill.hover one step darker and primary text.
private struct SidebarRangeControl: View {
    @ObservedObject var model: PanelModel
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    var body: some View {
        let options = SidebarRange.options(for: state.item)
        HStack(spacing: 0) {
            ForEach(options, id: \.rawValue) { option in
                let selected = option == state.range
                Button(action: { model.setRange(option, for: state.item) }) {
                    Text(option.label)
                        .font(PanelType.rowNote)
                        .foregroundStyle(selected ? tok.textPrimary : tok.textSecondary)
                        .frame(width: 48, height: 28)
                        .background(RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
                            .fill(selected ? tok.fillSelected : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("时间范围 " + option.label))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("btn.range." + option.rawValue)
                .uiTestFrame("btn.range." + option.rawValue)
            }
        }
        .animation(PanelMotion.feedback, value: state.range)
        .overlay(RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
            .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .sidebarRange ? 1 : 0))
    }
}

// MARK: - Capacity

/// One neutral bar (used: chart.line, free: chart.fill) and one line of numbers (docs/DESIGN_V3.md 2.3 rule 5).
private struct CapacityArea: View {
    let cap: CapacityText
    @Environment(\.tok) private var tok

    private var usedFraction: CGFloat {
        let used = cap.segments.filter { $0.kind != .free && $0.kind != .purgeable }.reduce(0) { $0 + $1.fraction }
        return CGFloat(min(1, max(0, used)))
    }

    private var line: String {
        cap.isMissing ? "容量暂时读不到" : "已用 " + cap.used + "，可用 " + cap.available + "，共 " + cap.total
    }

    var body: some View {
        let width = PanelMetrics.sidebarContentWidth
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                if cap.isMissing {
                    Capsule().strokeBorder(tok.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    Capsule().fill(tok.chartFill)
                    Capsule().fill(tok.chartLine).frame(width: max(6, width * usedFraction))
                }
            }
            .frame(width: width, height: 6)
            .uiTestFrame("cap.bar")
            Text(line)
                .font(PanelType.rowNote)
                .monospacedDigit()
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .uiTestFrame("cap.line")
        }
        .frame(width: width, alignment: .topLeading)
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
        return "app.dashed"
    }

    var body: some View {
        Group {
            if !snapshot, let image = AppIconCache.icon(bundleID: row.bundleID) {
                // Desaturated: color in the panel means level only (see the file header).
                Image(nsImage: image).resizable().interpolation(.high).saturation(0)
            } else {
                Image(systemName: symbol).font(.system(size: 13, weight: .light)).foregroundStyle(tok.textTertiary)
            }
        }
        .frame(width: SidebarGrid.glyph, height: SidebarGrid.glyph)
        .accessibilityHidden(true)
    }
}

/// Top 5 list. Each row: icon, name, value, and a 4 pt bar that starts under the name. The footnotes show as the help text
/// of the title (on hover), not as body text (docs/DESIGN_V3.md 6).
private struct RankingView: View {
    let table: RankTable
    let footnotes: [String]
    @Environment(\.tok) private var tok

    private let nameInset: CGFloat = SidebarGrid.name

    var body: some View {
        let barWidth = PanelMetrics.sidebarContentWidth - nameInset
        VStack(alignment: .leading, spacing: 0) {
            Text(table.title)
                .font(PanelType.section)
                .foregroundStyle(tok.textSecondary)
                .frame(height: 24, alignment: .leading)
                .help(footnotes.joined(separator: "\n"))
                .accessibilityHint(Text(footnotes.joined(separator: " ")))
                .accessibilityIdentifier("rank.title")
            if let empty = table.emptyText {
                Text(empty)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textTertiary)
                    .frame(height: 28, alignment: .leading)
                    .accessibilityIdentifier("rank.empty")
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: SidebarGrid.gap) {
                        RankIcon(row: row, table: table)
                        Text(row.name)
                            .font(PanelType.rowName)
                            .foregroundStyle(tok.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(row.quietValue ? PanelType.rowNote : PanelType.duration)
                            .foregroundStyle(row.quietValue ? tok.textSecondary : tok.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(height: 18)
                    if row.fraction >= 0.01 {
                        Capsule()
                            .fill(tok.chartLine.opacity(0.5))
                            .frame(width: max(4, barWidth * CGFloat(row.fraction)), height: 4)
                            .padding(.leading, nameInset)
                    }
                }
                .frame(width: PanelMetrics.sidebarContentWidth, height: 32, alignment: .topLeading)
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

/// The 7 (or 30) day strip: 4 pt high, anomaly periods in the level color, a 1 pt tick at today (docs/DESIGN_V3.md 6.1). The tick is
/// the lightest mark of the strip (text.tertiary), so a short anomaly segment always reads heavier than "today".
private struct RecordStripView: View {
    let rows: [RecordRow]
    let days: Int
    let now: Date
    @Environment(\.tok) private var tok

    var body: some View {
        // The band runs to the edge: its right end is now. The tick sits on that end and is thinner than any segment.
        let full = PanelMetrics.sidebarContentWidth
        let width = full
        let labels = RecordStrip.labels(days: days, now: now, timeZone: TimeZone.current)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(tok.chartFill).frame(width: width, height: 4)
                ForEach(Array(RecordStrip.segments(rows, days: days, now: now).enumerated()), id: \.offset) { _, seg in
                    Capsule()
                        .fill(seg.level == .red ? tok.lampDanger : tok.lampWarning)
                        .frame(width: max(3, CGFloat(seg.to - seg.from) * width), height: 4)
                        .offset(x: CGFloat(seg.from) * width)
                }
                Rectangle().fill(tok.textTertiary).frame(width: 1, height: 10).offset(x: full - 1)
                    .uiTestFrame("rec.today")
            }
            .frame(width: full, height: 10, alignment: .leading)
            HStack(spacing: 0) {
                Text(labels.0)
                Spacer(minLength: 0)
                Text(labels.1)
            }
            .font(PanelType.axis)
            .foregroundStyle(tok.textTertiary)
            .frame(width: full)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("近 \(days) 天有 \(rows.count) 条异常记录"))
        .accessibilityIdentifier("rec.strip")
        .uiTestFrame("rec.strip")
    }
}

/// Ongoing: a dashed 8 pt circle. Ended: a check mark. Status is a shape, not a color (docs/DESIGN_V3.md 2.3 rule 4).
private struct RecordStatusMark: View {
    let ongoing: Bool
    @Environment(\.tok) private var tok

    var body: some View {
        Group {
            if ongoing {
                Circle().strokeBorder(tok.textPrimary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.6]))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: PanelRowGlyph.checkSize, weight: .semibold))
                    .foregroundStyle(tok.textTertiary)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

private struct RecordRowView: View {
    @ObservedObject var model: PanelModel
    let row: RecordRow
    @Environment(\.tok) private var tok

    var body: some View {
        Button(action: { model.openRecord(row) }) {
            HStack(alignment: .top, spacing: SidebarGrid.gap) {
                StatusDotView(dot: row.level == .red ? .red : .yellow)
                    .frame(width: SidebarGrid.glyph, height: 16, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.title).font(PanelType.rowName).foregroundStyle(tok.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.duration).font(PanelType.duration).foregroundStyle(tok.textPrimary).lineLimit(1)
                    }
                    .frame(height: 16)
                    HStack(spacing: 6) {
                        Text(row.evidence).font(PanelType.rowNote).foregroundStyle(tok.textSecondary).lineLimit(1)
                        Spacer(minLength: 4)
                        RecordStatusMark(ongoing: row.ongoing)
                        Text(row.span)
                            .font(PanelType.rowNote)
                            .monospacedDigit()
                            .foregroundStyle(row.ongoing ? tok.textPrimary : tok.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(height: 14)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(width: PanelMetrics.sidebarContentWidth + 16, height: 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPlainHover())
        .padding(.horizontal, -8)
        .accessibilityLabel(Text("异常记录 " + row.title + "，" + row.evidence + "，" + row.span + "，" + row.duration))
        .accessibilityIdentifier("btn.record." + row.id)
    }
}

private struct RecordsView: View {
    @ObservedObject var model: PanelModel
    let state: SidebarContentState
    @Environment(\.tok) private var tok

    var body: some View {
        let days = state.range == .d30 ? 30 : 7
        let rows = state.groups.flatMap { $0.rows }
        VStack(alignment: .leading, spacing: 0) {
            RecordStripView(rows: rows, days: days, now: model.data.now)
                .padding(.bottom, 8)
            if state.groups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: PanelRowGlyph.checkSize, weight: .semibold))
                        .foregroundStyle(tok.textTertiary)
                    Text("近 \(days) 天没有异常记录").font(PanelType.rowName).foregroundStyle(tok.textSecondary)
                }
                .frame(width: PanelMetrics.sidebarContentWidth, height: 64)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rec.empty")
            }
            ForEach(state.groups) { group in
                Text(group.title)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .frame(height: 28, alignment: .bottomLeading)
                    .padding(.bottom, 4)
                ForEach(group.rows) { row in
                    RecordRowView(model: model, row: row)
                }
            }
        }
        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
    }
}

// MARK: - Entrance

/// Fade-and-rise of the sidebar content from the height of the hovered row (docs/DESIGN_V3.md 6, 7): motion.move, or a plain
/// 160 ms fade (motion.fade) under Reduce Motion. The window widening itself is the system animation of the window.
/// Static renders show the end state.
private struct SidebarRise: ViewModifier {
    let item: SidebarItem
    let offset: CGFloat
    @Environment(\.panelSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private static let fade = Animation.easeInOut(duration: 0.16)

    private func run() {
        guard !snapshot else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { shown = false }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? Self.fade : PanelMotion.move) { shown = true }
        }
    }

    func body(content: Content) -> some View {
        let on = snapshot || shown
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : offset)
            .onAppear { run() }
            .onChange(of: item) { _, _ in run() }
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
        VStack(alignment: .leading, spacing: 16) {
            if state.item == .anomalyLog {
                RecordsView(model: model, state: state)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(SidebarSummary.sentence(state.item, range: state.range, stats: state.stats))
                        .font(PanelFont.body)
                        .monospacedDigit()
                        .foregroundStyle(tok.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .leading)
                        .accessibilityIdentifier("side.summary")
                        .uiTestFrame("side.summary")
                    if let chart = state.chart {
                        ChartPanel(data: chart, level: state.level)
                    }
                }
                if let cap = state.capacity {
                    CapacityArea(cap: cap)
                }
                if let table = state.ranking {
                    RankingView(table: table, footnotes: state.footnotes)
                }
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(width: PanelMetrics.sidebarContentWidth, alignment: .topLeading)
    }

    var body: some View {
        let state = model.sidebarContent(for: item)
        let rise = CGFloat(SidebarEntrance.offset(item, plan: model.layoutPlan))
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(model: model, state: state)
            if snapshot {
                content(state)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) { content(state) }
            }
        }
        .modifier(SidebarRise(item: item, offset: rise))
        .padding(.top, 12)
        .padding(.horizontal, PanelMetrics.sidebarPadding)
        .frame(width: PanelMetrics.sidebarWidth, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }
}

/// The sidebar slot of the window (`PanelWindow(... sidebar:)`). It follows `model.sidebarItem`. During the fade-out the model has
/// no item any more, so the slot keeps the last one on screen.
struct PanelSidebar: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @State private var held: SidebarItem = .cpu

    var body: some View {
        let item = model.sidebarItem ?? held
        PanelSidebarView(model: model, item: item)
            .environment(\.tok, PanelTokens(scheme: scheme))
            .frame(width: PanelMetrics.sidebarWidth, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .hoverRegion(.sidebar, model: model)
            .uiTestFrame("sidebar")
            .onChange(of: model.sidebarItem) { _, new in
                if let new { held = new }
            }
            .onAppear { if let now = model.sidebarItem { held = now } }
    }
}
