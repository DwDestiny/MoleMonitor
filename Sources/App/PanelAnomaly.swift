// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (area state, anomaly bars, authorization).
// Output: The anomaly area of the main column: one 36 pt line (quiet, collecting, stale, or the anomaly summary).
// Pos: Section 3 of the main column (docs/DESIGN_V2.md 7). Always 36 pt. The anomaly line names the count and the longest
//      duration. It does not list the items: the rows above show them. Each item's duration and start are in its sidebar header.

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
                anomalyLine
            }
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelLayout.anomalyHeight, alignment: .top)
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
            Button(action: { model.onEnableNotifications() }) {
                Text("开启通知 \u{203A}")
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.accent)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("开启通知"))
            .accessibilityIdentifier("btn.notifyAuth")
            .uiTestFrame("btn.notifyAuth")
        } else if let records, records > 0 {
            Button(action: { model.userOpen(.anomalyLog) }) {
                Text(PanelAreaState.recordsText(records) + " \u{203A}")
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tok.accent, lineWidth: 1.5).padding(-3)
                        .opacity(model.keyFocus == .records ? 1 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("异常记录，" + PanelAreaState.recordsText(records)))
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

    /// One line for all anomalies. The rows above already show each item, its level and its value (DESIGN_V2.md 7.2).
    /// The whole line opens the anomaly log.
    private var anomalyLine: some View {
        let summary = model.anomalySummary
        return Button(action: { model.userOpen(.anomalyLog) }) {
            HStack(spacing: 0) {
                Text(summary)
                    .font(PanelType.anomalyTitle)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .uiTestFrame("txt.anomaly.count")
                Spacer(minLength: 8)
                Text("记录 \u{203A}")
                    .font(PanelType.rowNote)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.anomalyLine)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.sidebarItem == .anomalyLog ? tok.fillSelected : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tok.accent, lineWidth: 1.5).opacity(model.keyFocus == .records ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(summary + "，打开异常记录"))
        .accessibilityIdentifier("btn.records")
        .uiTestFrame("btn.records")
    }
}
