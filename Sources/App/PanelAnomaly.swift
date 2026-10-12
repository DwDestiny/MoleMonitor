// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (area state, anomaly bars, authorization).
// Output: The anomaly area of the main column: one quiet line, or the title and up to three anomaly bars.
// Pos: Section 3 of the main column (docs/DESIGN_V2.md 7). Quiet: 36 pt. Anomalies: 28 pt title + 44 pt per bar (3 bars at most).
//      A bar shows the item, the level word, a reason word, the duration and the start time. It shows no measured value (7.3).

import SwiftUI

struct PanelAnomalySection: View {
    @ObservedObject var model: PanelModel
    @Environment(\.tok) private var tok

    var body: some View {
        let state = model.areaState
        VStack(spacing: 0) {
            switch state {
            case .quiet(let records):
                quietLine(records: records)
            case .collecting:
                plainLine(PanelAreaState.collecting.text)
            case .stale:
                plainLine(state.text)
            case .anomalies:
                anomalyList
            }
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelLayout.anomalyHeight(count: model.layoutPlan.anomalies.count), alignment: .top)
        .hoverRegion(.neutral, model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.anomaly")
    }

    // MARK: Quiet

    private func plainLine(_ text: String) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(PanelType.anomalyTitle)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .uiTestFrame("txt.anomaly.quiet")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyQuiet)
    }

    private func quietLine(records: Int?) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tok.textOK)
                    .accessibilityHidden(true)
                Text("没有异常")
                    .font(PanelType.anomalyTitle)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.quiet")
            }
            Spacer(minLength: 8)
            rightLink(records: records)
        }
        .padding(.horizontal, 8)
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyQuiet)
    }

    @ViewBuilder
    private func rightLink(records: Int?) -> some View {
        if model.authorization != "authorized" {
            Text("开启通知 \u{203A}")
                .font(PanelType.rowNote)
                .foregroundStyle(tok.accent)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { model.onEnableNotifications() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("开启通知"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onEnableNotifications() }
                .accessibilityIdentifier("btn.notifyAuth")
                .uiTestFrame("btn.notifyAuth")
        } else if let records, records > 0 {
            Text(PanelAreaState.recordsText(records) + " \u{203A}")
                .font(PanelType.rowNote)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tok.accent, lineWidth: 1.5).padding(-3)
                    .opacity(model.keyFocus == .records ? 1 : 0))
                .contentShape(Rectangle())
                .onTapGesture { model.pinSidebar(.anomalyLog) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(PanelAreaState.recordsText(records)))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.pinSidebar(.anomalyLog) }
                .accessibilityIdentifier("btn.records")
                .uiTestFrame("btn.records")
        } else {
            Text(PanelAreaState.recordsText(records ?? 0))
                .font(PanelType.rowNote)
                .foregroundStyle(tok.textTertiary)
                .lineLimit(1)
                .uiTestFrame("txt.records.none")
        }
    }

    // MARK: Anomalies

    private var anomalyList: some View {
        let plan = model.layoutPlan
        let bars = model.anomalyBars
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("异常 \u{00B7} \(plan.anomalies.count)")
                    .font(PanelType.section)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.count")
                Spacer(minLength: 8)
                Text("记录 \u{203A}")
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture { model.pinSidebar(.anomalyLog) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("异常记录"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.pinSidebar(.anomalyLog) }
                    .accessibilityIdentifier("btn.records")
                    .uiTestFrame("btn.records")
            }
            .padding(.horizontal, 8)
            .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyTitle)
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                AnomalyBarView(bar: bar, index: index, selected: model.sidebarItem == bar.sidebar,
                               focused: model.keyFocus == .anomaly(index))
                    .hoverRegion(.row(bar.sidebar), model: model)
                    .onTapGesture { model.rowClicked(bar.sidebar) }
                    .accessibilityAction { model.rowClicked(bar.sidebar) }
            }
            if plan.overflowCount > 0 {
                overflowRow(count: plan.overflowCount, index: bars.count)
            }
        }
    }

    private func overflowRow(count: Int, index: Int) -> some View {
        HStack(spacing: 0) {
            Text("另有 \(count) 项 \u{203A}")
                .font(PanelType.anomalyTitle)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyItem)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .anomaly(index) ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.pinSidebar(.anomalyLog) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("另有 \(count) 项异常"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.pinSidebar(.anomalyLog) }
        .accessibilityIdentifier("anomaly.overflow")
        .uiTestFrame("anomaly.overflow")
    }
}

struct AnomalyBarView: View {
    let bar: AnomalyBar
    let index: Int
    let selected: Bool
    let focused: Bool
    @Environment(\.tok) private var tok

    private var dot: PanelDot { bar.level == .red ? .red : .yellow }
    private var titleColor: Color { bar.level == .red ? tok.textDanger : tok.textWarning }

    var body: some View {
        HStack(spacing: 0) {
            StatusDotView(dot: dot).frame(width: PanelMetrics.dotColumn)
                .uiTestFrame("dot.anomaly.\(index)")
            VStack(alignment: .leading, spacing: 1) {
                Text(bar.title)
                    .font(PanelType.anomalyTitle)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.title.\(index)")
                Text(bar.reason)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.reason.\(index)")
            }
            .padding(.leading, PanelMetrics.dotGap)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(bar.duration)
                    .font(PanelType.duration)
                    .foregroundStyle(tok.textPrimary)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.duration.\(index)")
                Text(bar.start)
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.anomaly.start.\(index)")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyItem)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? tok.fillSelected : tok.rowTint(dot)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(tok.accent, lineWidth: 1.5).opacity(focused ? 1 : 0))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bar.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("anomaly.\(index)")
        .uiTestFrame("anomaly.\(index)")
    }
}
