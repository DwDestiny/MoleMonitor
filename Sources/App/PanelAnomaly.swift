// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (area state, authorization, sidebar and focus state).
// Output: The record row of the main column, 28 pt: only the entry "近 7 天 N 条记录 ›", left aligned, with and without problems
//         and when stale (the age is in the headline). Empty while collecting. All green has no "✓ 没有异常": it repeated the headline
//         (FABLE round 1, item 6). The entry's hover background starts at the block edge (x 8), its text at the headline x (16).
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
            case .quiet(let records), .anomalies(let records), .stale(_, let records):
                rightLink(records: records)
                Spacer(minLength: 8)
            case .collecting:
                Spacer(minLength: 0)
            }
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.recordRow, alignment: .top)
        .hoverRegion(.neutral, model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.anomaly")
    }

    /// The entry has 8 pt of inner padding for its hit area. The row starts at the block edge (x 8), so the text starts at x 16.
    private static let entryPadding = PanelMetrics.textInset

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
                .padding(.horizontal, PanelMetrics.textInset)
                .frame(height: PanelMetrics.recordRow)
                .background(shape.fill(open ? tok.fillRowActive : Color.clear))
                .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(focused ? 1 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label.isEmpty ? "异常记录" : label))
        .accessibilityIdentifier(identifier)
        .onHover { hovering = $0 }
        .animation(PanelMotion.hover, value: hovering)
    }
}
