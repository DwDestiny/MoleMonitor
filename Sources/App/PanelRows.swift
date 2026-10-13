// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (row states, mini curves, hover and selection state) and the tokens.
// Output: The six breakdown rows of the main column: state dot, name and note, right-aligned value, 80 x 24 mini curve.
// Pos: Section 2 of the main column (docs/DESIGN_V2.md 5). A row is 40 pt high. Columns: 8 + 8 + 120 + 92 + 12 + 80 = 320.
//      Line 1 holds the name (120 pt) and the value (92 pt, right-aligned, same baseline). Line 2 is the note over both columns (212 pt),
//      so the capacity line "已用 875 / 995 GB，可用 120 GB" fits at 11 pt.
//      Only these type sizes appear: 17, 13, 11 pt. The mini curve has no animation and no timer.

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
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tok.dotColor(.red)).frame(width: 8, height: 8)
            case .yellow:
                TriangleShape().fill(tok.dotColor(.yellow)).frame(width: 8, height: 8)
            case .normal:
                Circle().fill(tok.dotNeutral).frame(width: 6, height: 6)
            case .collecting:
                Circle().strokeBorder(tok.dotNeutral, lineWidth: 1.5).frame(width: 6, height: 6)
            case .stale:
                Circle().strokeBorder(tok.dotNeutral, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5])).frame(width: 6, height: 6)
            case .missing:
                RoundedRectangle(cornerRadius: 0.75, style: .continuous).fill(tok.dotNeutral).frame(width: 8, height: 1.5)
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

private struct SparkEndShape: Shape {
    let series: SparkSeries

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if let last = series.last {
            let q = SparkGeometry.point(last, series, rect)
            p.addEllipse(in: CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3))
        }
        return p
    }
}

enum SparkGeometry {
    /// Maps a point into the rect with a 2 pt inset, so the 1.5 pt line and the 3 pt end dot are not clipped.
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

/// An 80 x 24 mini curve. `dashed` draws the dashed baseline of the collecting state. A stale row draws every curve the same way:
/// the third-level text color, dashed, with a hollow end dot (all six rows end at the stale time, so they have the same length).
struct SparkView: View {
    let series: SparkSeries
    let color: Color
    var dashed = false
    var stale = false
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack {
            if dashed || series.isEmpty {
                Path { p in
                    p.move(to: CGPoint(x: 2, y: PanelMetrics.sparkHeight / 2))
                    p.addLine(to: CGPoint(x: PanelMetrics.sparkWidth - 2, y: PanelMetrics.sparkHeight / 2))
                }
                .stroke(tok.chartGrid, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if stale {
                SparkLineShape(series: series)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round, dash: [3, 2.5]))
                SparkEndRingShape(series: series).stroke(color, lineWidth: 1.25)
            } else {
                SparkLineShape(series: series)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                SparkEndShape(series: series).fill(color)
            }
        }
        .frame(width: PanelMetrics.sparkWidth, height: PanelMetrics.sparkHeight)
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

// MARK: - Row

struct BreakdownRowView: View {
    let row: PanelRowState
    let index: Int
    let spark: SparkSeries
    let selected: Bool
    /// Only the most severe row carries the tint. The other problem rows show their level in the symbol and the value.
    var tinted = false
    let hovered: Bool
    let focused: Bool
    @Environment(\.tok) private var tok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var id: String { row.item.rawValue }

    private var valueColor: Color {
        switch row.status {
        case .collecting: return tok.textTertiary
        case .stale: return tok.textSecondary
        case .missing: return tok.textSecondary
        case .measured: return row.isProblem ? tok.valueColor(row.level, problem: true) : tok.textSecondary
        }
    }

    private var sparkColor: Color {
        if row.status == .stale { return tok.textTertiary }
        if row.isProblem { return tok.chartHot(row.level) }
        return tok.chartLine
    }

    var body: some View {
        HStack(spacing: 0) {
            StatusDotView(dot: row.dot)
                .frame(width: PanelMetrics.dotColumn, height: PanelMetrics.dotColumn)
                .uiTestFrame("dot." + id)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.name)
                        .font(PanelType.rowName)
                        .foregroundStyle(tok.textPrimary)
                        .lineLimit(1)
                        .uiTestFrame("txt.row.name." + id)
                        .frame(width: PanelMetrics.textColumn, alignment: .leading)
                    valueView
                        .frame(width: PanelMetrics.valueColumn, alignment: .trailing)
                }
                Text(row.note)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .uiTestFrame("txt.row.note." + id)
                    .frame(width: PanelMetrics.noteColumn, alignment: .leading)
            }
            .frame(width: PanelMetrics.noteColumn, alignment: .leading)
            .padding(.leading, PanelMetrics.dotGap)
            SparkView(series: spark, color: sparkColor, dashed: row.status == .collecting, stale: row.status == .stale)
                .padding(.leading, PanelMetrics.sparkGap)
                .uiTestFrame("row." + id + ".spark")
        }
        .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.row)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tinted ? tok.rowTint(row.dot) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? tok.fillSelected : (hovered ? tok.fillHover : Color.clear)))
        .overlay(alignment: .leading) {
            Capsule().fill(tok.selectedBar).frame(width: 3, height: 24).opacity(selected ? 1 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(tok.accent, lineWidth: 1.5).opacity(focused ? 1 : 0))
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("row." + id)
        .uiTestFrame("row." + id)
        .uiTestFrame("row.\(index)")
    }

    private var valueView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let prefix = row.valuePrefix {
                Text(prefix)
                    .font(PanelType.rowPrefix)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
            }
            Text(row.value)
                .font(row.status == .collecting ? PanelType.rowName : (row.isProblem ? PanelType.rowValue : PanelType.rowValueQuiet))
                .foregroundStyle(row.status == .collecting ? tok.textTertiary : valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .numericChange(row.value)
        }
        .uiTestFrame("row." + id + ".value")
    }
}

// MARK: - Section

struct PanelRowsSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let rows = model.rows
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                BreakdownRowView(row: row, index: index, spark: model.spark(for: row.item),
                                 selected: model.sidebarItem == row.item,
                                 tinted: index == 0 && row.isProblem,
                                 hovered: model.hoverRow == row.item,
                                 focused: model.keyFocus == .row(row.item))
                    .hoverRegion(.row(row.item), model: model)
                    .onTapGesture { model.rowClicked(row.item) }
                    .accessibilityAction { model.rowClicked(row.item) }
            }
        }
        .frame(width: PanelMetrics.rowBackgroundWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.rows")
    }
}
