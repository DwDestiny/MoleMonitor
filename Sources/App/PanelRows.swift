// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (row states, mini curves, hover and selection state, the layout plan) and the tokens.
// Output: The rows section of the main column: up to 3 problem rows (64 pt, level tint, value, plain-words note, full-width curve)
//         and the quiet grid (28 pt rows, two columns, check mark, name, value, no curve).
// Pos: Section 2 of the main column (docs/DESIGN_V3.md 3.3, 5.1, 5.2). Problem rows are the only rows with a tint, a curve, a 17 pt value
//      and a duration. The fourth and later problems use the quiet style and keep their level shape and level text color.
//      A row is hovered or selected: the background is `fillHover` / `fillRowActive`. No blue, no divider. Radius: 8 pt only.
//      Only these type sizes appear: 17, 13, 11 pt. The mini curve has no timer. Reorder moves with `PanelMotion.move` (fade under Reduce Motion).

import SwiftUI

// MARK: - Dot

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The state dot (DESIGN_V2.md 3.5). The shape tells the state. The color repeats it.
struct StatusDotView: View {
    let dot: PanelDot
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack {
            switch dot {
            case .red:
                Rectangle().fill(tok.dotColor(.red)).frame(width: 8, height: 8)
            case .yellow:
                TriangleShape().fill(tok.dotColor(.yellow)).frame(width: 8, height: 8)
            case .normal:
                Circle().fill(tok.dotNeutral).frame(width: 6, height: 6)
            case .collecting:
                Circle().strokeBorder(tok.dotNeutral, lineWidth: 1.5).frame(width: 6, height: 6)
            case .stale:
                Circle().strokeBorder(tok.dotNeutral, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5])).frame(width: 6, height: 6)
            case .missing:
                Rectangle().fill(tok.dotNeutral).frame(width: 8, height: 1.5)
            case .failed:
                ZStack {
                    Circle().strokeBorder(tok.dotNeutral, lineWidth: 1.5)
                    Rectangle().fill(tok.dotNeutral).frame(width: 1.5, height: 3).offset(y: -0.5)
                }
                .frame(width: 8, height: 8)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Mini curve

private struct SparkLineShape: Shape {
    let series: SparkSeries

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for run in series.runs where run.count >= 2 {
            for (i, point) in run.enumerated() {
                let q = SparkGeometry.point(point, series, rect)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
        }
        return p
    }
}

/// The area under each run, down to the bottom of the rect (10 % of the line color, DESIGN_V3.md 5.1).
private struct SparkAreaShape: Shape {
    let series: SparkSeries

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for run in series.runs where run.count >= 2 {
            let points = run.map { SparkGeometry.point($0, series, rect) }
            guard let first = points.first, let last = points.last else { continue }
            p.move(to: CGPoint(x: first.x, y: rect.maxY))
            for q in points { p.addLine(to: q) }
            p.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

private struct SparkEndShape: Shape {
    let series: SparkSeries

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if let last = series.last {
            let q = SparkGeometry.point(last, series, rect)
            p.addEllipse(in: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4))
        }
        return p
    }
}

enum SparkGeometry {
    /// Maps a point into the rect with a 2 pt inset, so the 1.5 pt line and the end dot are not clipped.
    static func point(_ p: SparkPoint, _ s: SparkSeries, _ rect: CGRect) -> CGPoint {
        let inner = rect.insetBy(dx: 2, dy: 2)
        let spanT = s.window.upperBound.timeIntervalSince(s.window.lowerBound)
        let fx = spanT > 0 ? p.t.timeIntervalSince(s.window.lowerBound) / spanT : 1
        let spanV = s.domain.upperBound - s.domain.lowerBound
        let fy = spanV > 0 ? (p.v - s.domain.lowerBound) / spanV : 0
        let x = inner.minX + CGFloat(min(1, max(0, fx))) * inner.width
        let y = inner.maxY - CGFloat(min(1, max(0, fy))) * inner.height
        return CGPoint(x: x, y: y)
    }
}

/// The end dot of a stale curve: a ring, so the line reads as "stopped here" and not as a live value.
private struct SparkEndRingShape: Shape {
    let series: SparkSeries

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if let last = series.last {
            let q = SparkGeometry.point(last, series, rect)
            p.addEllipse(in: CGRect(x: q.x - 1.75, y: q.y - 1.75, width: 3.5, height: 3.5))
        }
        return p
    }
}

/// The curve at the bottom of a problem row: full row width, 16 pt high, a 1.5 pt line, a 10 % area and a solid end dot.
/// A stale series draws dashed in the third-level text color with a hollow end dot.
struct SparkView: View {
    let series: SparkSeries
    let color: Color
    var size = CGSize(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.curveHeight)
    var stale = false
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack {
            if series.isEmpty {
                Path { p in
                    p.move(to: CGPoint(x: 2, y: size.height - 3))
                    p.addLine(to: CGPoint(x: size.width - 2, y: size.height - 3))
                }
                .stroke(tok.chartGrid, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if stale {
                SparkLineShape(series: series)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round, dash: [3, 2.5]))
                SparkEndRingShape(series: series).stroke(color, lineWidth: 1.25)
            } else {
                SparkAreaShape(series: series).fill(color.opacity(0.10))
                SparkLineShape(series: series)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                SparkEndShape(series: series).fill(color)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Hover reporting

extension View {
    /// Reports the pointer to the model. The model feeds HoverIntent.
    func hoverRegion(_ region: HoverRegion, model: PanelModel) -> some View {
        onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { model.pointerMoved(region, at: point) }
        }
    }
}

// MARK: - Shared row pieces

/// Everything a row view needs besides the row itself.
struct RowContext {
    let index: Int
    let selected: Bool
    let hovered: Bool
    let focused: Bool
}

private extension PanelRowState {
    /// Color of the value: the level color for a problem, the primary gray for a measured quiet value.
    func valueColor(_ tok: PanelTokens) -> Color {
        switch status {
        case .collecting: return tok.textTertiary
        case .stale, .missing: return tok.textSecondary
        case .measured: return isProblem ? tok.valueColor(level, problem: true) : tok.textPrimary
        }
    }
}

private extension View {
    /// The shared look of a row: hover and selection background, the keyboard focus ring and the accessibility traits.
    func rowChrome(_ row: PanelRowState, _ ctx: RowContext, tok: PanelTokens, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        return self
            .frame(width: width, height: height)
            .background(shape.fill(ctx.selected ? tok.fillRowActive : (ctx.hovered ? tok.fillHover : Color.clear)))
            .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(ctx.focused ? 1 : 0))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.accessibilityLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("row." + row.id)
            .uiTestFrame("row." + row.id)
            .uiTestFrame("row.\(ctx.index)")
    }
}

// MARK: - Problem row

/// A problem row (DESIGN_V3.md 5.1): the level tint on the whole row, name and 17 pt value on line 1, the plain-words note on line 2,
/// the curve along the bottom edge. Every problem row of one level looks the same.
struct ProblemRowView: View {
    let row: PanelRowState
    let spark: SparkSeries
    let context: RowContext
    @Environment(\.tok) private var tok

    private var id: String { row.id }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(tok.rowTint(row.dot))
            SparkView(series: spark, color: tok.chartHot(row.level), stale: row.status == .stale)
                .uiTestFrame("row." + id + ".spark")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PanelMetrics.dotGap) {
                    StatusDotView(dot: row.dot)
                        .uiTestFrame("dot." + id)
                    Text(row.name)
                        .font(PanelType.rowName)
                        .foregroundStyle(tok.textPrimary)
                        .lineLimit(1)
                        .uiTestFrame("txt.row.name." + id)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(PanelType.rowValue)
                        .foregroundStyle(row.valueColor(tok))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .numericChange(row.value)
                        .uiTestFrame("row." + id + ".value")
                }
                Text(row.problemNote ?? row.note)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .numericChange(row.problemNote ?? row.note)
                    .padding(.leading, PanelMetrics.dotColumn + PanelMetrics.dotGap)
                    .uiTestFrame("txt.row.note." + id)
            }
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.problemRow)
        .clipShape(shape)
        .rowChrome(row, context, tok: tok, width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.problemRow)
    }
}

// MARK: - Quiet row

/// A quiet row (DESIGN_V3.md 5.2): one line of 13 pt, a check mark (the network row a gray dot), the name and the value.
/// A problem past the third keeps its level shape and its level text color.
struct QuietRowView: View {
    let row: PanelRowState
    let context: RowContext
    @Environment(\.tok) private var tok

    private var id: String { row.id }
    static let width = CGFloat(PanelMetrics.rowBackgroundWidth) / CGFloat(PanelMetrics.quietColumns)

    /// The check mark marks a measured healthy item. Network has no health level, so it keeps a gray dot.
    private var showsCheck: Bool { row.dot == .normal && row.item != .network }

    var body: some View {
        HStack(spacing: PanelMetrics.dotGap) {
            ZStack {
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: PanelRowGlyph.checkSize, weight: .semibold))
                        .foregroundStyle(tok.textTertiary)
                } else {
                    StatusDotView(dot: row.dot)
                }
            }
            .frame(width: PanelRowGlyph.column, height: PanelRowGlyph.column)
            .accessibilityHidden(true)
            .uiTestFrame("dot." + id)
            Text(row.name)
                .font(PanelType.anomalyTitle)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .uiTestFrame("txt.row.name." + id)
            Spacer(minLength: 4)
            Text(row.status == .collecting ? PanelRows.dash : row.quietValue)
                .font(PanelType.quietValue)
                .foregroundStyle(row.valueColor(tok))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .numericChange(row.quietValue)
                .uiTestFrame("row." + id + ".value")
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .rowChrome(row, context, tok: tok, width: Self.width, height: PanelMetrics.quietRow)
    }
}

// MARK: - Section

private struct IndexedRow {
    let offset: Int
    let element: PanelRowState
}

struct PanelRowsSection: View {
    @ObservedObject var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func context(_ index: Int, _ row: PanelRowState) -> RowContext {
        RowContext(index: index, selected: model.sidebarItem == row.item, hovered: model.hoverRow == row.item,
                   focused: model.keyFocus == .row(row.item))
    }

    private func interactive<Content: View>(_ row: PanelRowState, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .hoverRegion(.row(row.item), model: model)
            .onTapGesture { model.rowClicked(row.item) }
            .accessibilityAction { model.rowClicked(row.item) }
    }

    /// The rows after the problem rows, cut into lines of `quietColumns`. `offset` is the index in the whole list.
    private static func quietLines(_ rows: [PanelRowState], after expanded: Int) -> [[IndexedRow]] {
        var indexed = [IndexedRow]()
        for (offset, row) in rows.enumerated() where offset >= expanded { indexed.append(IndexedRow(offset: offset, element: row)) }
        var lines = [[IndexedRow]]()
        var start = 0
        while start < indexed.count {
            let end = min(start + PanelMetrics.quietColumns, indexed.count)
            lines.append(Array(indexed[start..<end]))
            start = end
        }
        return lines
    }

    var body: some View {
        let rows = model.rows
        let expanded = min(model.layoutPlan.problemRowCount, rows.filter { $0.isProblem }.count)
        let lines = Self.quietLines(rows, after: expanded)
        VStack(spacing: 0) {
            if expanded > 0 {
                VStack(spacing: PanelMetrics.problemRowGap) {
                    ForEach(Array(rows.prefix(expanded).enumerated()), id: \.element.id) { index, row in
                        interactive(row) {
                            ProblemRowView(row: row, spark: model.spark(for: row.item), context: context(index, row))
                        }
                    }
                }
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    ForEach(line, id: \.element.id) { entry in
                        interactive(entry.element) {
                            QuietRowView(row: entry.element, context: context(entry.offset, entry.element))
                        }
                    }
                    if line.count < PanelMetrics.quietColumns { Spacer(minLength: 0) }
                }
                .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.quietRow, alignment: .leading)
            }
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, alignment: .top)
        .animation(reduceMotion ? PanelMotion.fade : PanelMotion.move, value: rows.map { $0.id })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.rows")
    }
}
