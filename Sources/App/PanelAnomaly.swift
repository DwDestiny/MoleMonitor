// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (area state, authorization, sidebar and focus state).
// Output: The record row of the main column, 28 pt: with problems only the entry "近 7 天 N 条记录 ›", without problems
//         "✓ 没有异常" on the left and the same entry on the right. Empty while collecting.
// Pos: Section 3 of the main column (docs/DESIGN_V3.md 5.3). There is no summary line and no fold: the problem rows above carry
//      the items, their values and their duration. The entry opens the anomaly log in the sidebar.

import SwiftUI

struct PanelAnomalySection: View {
    @ObservedObject var model: PanelModel
    @Environment(\.tok) private var tok

    var body: some View {
        let state = model.areaState
        HStack(spacing: 0) {
            switch state {
            case .quiet(let records):
                quietMark
                Spacer(minLength: 8)
                rightLink(records: records)
            case .anomalies(let records):
                rightLink(records: records)
                Spacer(minLength: 8)
            case .collecting:
                Spacer(minLength: 0)
            case .stale:
                plainText(state.text)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, PanelMetrics.rowInset - Self.entryPadding)
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.recordRow, alignment: .top)
        .hoverRegion(.neutral, model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.anomaly")
    }

    /// The entry has 8 pt of inner padding for its hit area. The row takes that off its own inset, so the text starts at the row inset.
    private static let entryPadding = 8.0

    private func plainText(_ text: String) -> some View {
        Text(text)
            .font(PanelType.rowNote)
            .foregroundStyle(tok.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Self.entryPadding)
            .uiTestFrame("txt.anomaly.quiet")
    }

    /// "✓ 没有异常": the check mark is the same gray as the check marks of the quiet rows.
    private var quietMark: some View {
        HStack(spacing: PanelMetrics.dotGap) {
            Image(systemName: "checkmark")
                .font(.system(size: PanelRowGlyph.checkSize, weight: .semibold))
                .foregroundStyle(tok.textTertiary)
                .frame(width: PanelRowGlyph.column)
                .accessibilityHidden(true)
            Text("没有异常")
                .font(PanelType.rowNote)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .uiTestFrame("txt.anomaly.quiet")
        }
        .padding(.horizontal, Self.entryPadding)
    }

    @ViewBuilder
    private func rightLink(records: Int?) -> some View {
        if model.authorization != "authorized" && model.layoutPlan.quiet {
            EntryLink(text: "开启通知 \u{203A}", label: "开启通知", identifier: "btn.notifyAuth", open: false, focused: false,
                      action: { model.onEnableNotifications() })
                .uiTestFrame("btn.notifyAuth")
        } else if let records, records > 0 {
            let text = PanelAreaState.recordsText(records) + " \u{203A}"
            EntryLink(text: text, label: "异常记录，" + PanelAreaState.recordsText(records), identifier: "btn.records",
                      open: model.sidebarItem == .anomalyLog, focused: model.keyFocus == .records,
                      action: { model.userOpen(.anomalyLog) })
                .uiTestFrame("btn.records")
        } else {
            Text(PanelAreaState.recordsText(records ?? 0))
                .font(PanelType.rowNote)
                .foregroundStyle(tok.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, Self.entryPadding)
                .uiTestFrame("txt.records.none")
        }
    }
}

/// A text entry of the record row: 11 pt secondary, primary on hover, `fillRowActive` while its sidebar is open.
private struct EntryLink: View {
    let text: String
    let label: String
    let identifier: String
    let open: Bool
    let focused: Bool
    let action: () -> Void
    @Environment(\.tok) private var tok
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        Button(action: action) {
            Text(text)
                .font(PanelType.rowNote)
                .foregroundStyle(hovering || open ? tok.textPrimary : tok.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: PanelMetrics.recordRow)
                .background(shape.fill(open ? tok.fillRowActive : Color.clear))
                .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(focused ? 1 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
        .onHover { hovering = $0 }
        .animation(PanelMotion.hover, value: hovering)
    }
}
