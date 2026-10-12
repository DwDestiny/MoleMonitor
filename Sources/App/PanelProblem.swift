// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData, the open problem item, the evidence height from the layout plan, and the copy state of the model.
// Output: The problem card (title, key figure, chart, evidence), the collapsed problem rows and the normal summary line.
// Pos: The largest block of the problem mode (docs/DESIGN.md 2.2, 2.3). The card carries the evidence, so the card has the most visual weight.

import SwiftUI

// MARK: - Key facts

struct ProblemFacts: Equatable {
    var value: String
    var unit: String
    var caption: String
}

enum ProblemFactsBuilder {
    static func facts(item: HealthItem, verdict: ItemVerdict, data: PanelData) -> ProblemFacts {
        let c = data.current
        switch item {
        case .cpu:
            let mean = c.cpuMean5m ?? c.cpuPercent
            return ProblemFacts(value: PanelFormat.percent(mean), unit: "", caption: "整机 5 分钟均值，阈值 70%")
        case .memory:
            return memoryFacts(c)
        case .thermal:
            var caption = "系统热状态"
            if let t = c.smcCPUTemperature { caption += String(format: " · CPU 传感器均值 %.0f°C", t) }
            return ProblemFacts(value: PanelFormat.thermalWord(c.thermal), unit: "", caption: caption)
        case .disk:
            return diskFacts(verdict: verdict, data: data)
        case .power:
            return powerFacts(verdict: verdict, data: data)
        }
    }

    private static func memoryFacts(_ c: CurrentReadings) -> ProblemFacts {
        let parts = PanelFormat.gbParts(c.swapUsed)
        var unit = parts.unit
        let arrow = PanelFormat.trendArrow(c.swapTrend)
        if !arrow.isEmpty { unit += " " + arrow }
        var caption = PanelFormat.pressureWord(c.pressure) + " · swap 已用"
        if let g = c.swapGrowth30m, g > 0 { caption = PanelFormat.pressureWord(c.pressure) + " · 近 30 分钟增加 " + PanelFormat.appMemory(g) }
        return ProblemFacts(value: parts.value, unit: unit, caption: caption)
    }

    private static func diskFacts(verdict: ItemVerdict, data: PanelData) -> ProblemFacts {
        let key = data.diskTrigger?.windowKey ?? "5d"
        let days = Int(key.dropLast()) ?? 5
        let growth = data.status?.items.disk.growth[key]
        guard let bytes = growth?.bytes else {
            return ProblemFacts(value: "—", unit: "", caption: "\(days) 天增长，数据不足")
        }
        let text = ByteText.gb(bytes)
        let pieces = text.split(separator: " ", maxSplits: 1).map(String.init)
        let value = "+" + (pieces.first ?? text)
        let unit = pieces.count == 2 ? pieces[1] : ""
        return ProblemFacts(value: value, unit: unit, caption: "\(days) 天增长，已排除快照与缓存")
    }

    private static func powerFacts(verdict: ItemVerdict, data: PanelData) -> ProblemFacts {
        if verdict.reasonCode.contains("sleep"), let rate = sleepRate(data.current.lastSleep) {
            return ProblemFacts(value: String(format: "%.1f", rate), unit: "%/小时", caption: "上次睡眠的掉电速率")
        }
        if let rate = data.current.awakeDrainPerHour {
            return ProblemFacts(value: String(format: "%.0f", rate), unit: "%/小时", caption: "近 60 分钟的掉电速率")
        }
        if let rate = sleepRate(data.current.lastSleep) {
            return ProblemFacts(value: String(format: "%.1f", rate), unit: "%/小时", caption: "上次睡眠的掉电速率")
        }
        return ProblemFacts(value: "—", unit: "", caption: "掉电速率")
    }

    /// Percent points per hour over the sleep. Nil when the sleep was shorter than a minute.
    static func sleepRate(_ s: SleepRecord?) -> Double? {
        guard let s else { return nil }
        let hours = s.wokeAt.timeIntervalSince(s.sleptAt) / 3600
        guard hours > 1.0 / 60 else { return nil }
        return (s.batteryBefore - s.batteryAfter) / hours
    }
}

// MARK: - Problem card

struct ProblemCard: View {
    @ObservedObject var model: PanelModel
    let item: HealthItem
    let compact: Bool
    let evidenceHeight: Double

    @Environment(\.tok) private var tok

    private var data: PanelData { model.data }

    var body: some View {
        if let verdict = data.verdict(item) {
            content(verdict)
        }
    }

    private func content(_ verdict: ItemVerdict) -> some View {
        let facts = ProblemFactsBuilder.facts(item: item, verdict: verdict, data: data)
        let duration = verdict.since.map { PanelFormat.duration(seconds: data.now.timeIntervalSince($0)) }
        return VStack(alignment: .leading, spacing: 0) {
            titleRow(verdict, duration: duration)
            figureRow(facts)
                .padding(.top, 8)
            chart(verdict)
                .padding(.top, 6)
            ProblemEvidence(model: model, item: item, verdict: verdict, height: evidenceHeight)
                .frame(height: evidenceHeight, alignment: .top)
                .padding(.top, 8)
        }
        .padding(PanelSize.cardPadding)
        .frame(width: PanelSize.contentWidth, alignment: .topLeading)
        .background(CardBackground(level: verdict.level))
        .uiTestFrame("card." + item.rawValue)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card." + item.rawValue)
        .accessibilityLabel(Text(accessibilityText(verdict, duration: duration)))
    }

    private func accessibilityText(_ verdict: ItemVerdict, duration: String?) -> String {
        var text = PanelFormat.titled(item, verdict.level) + "，" + verdict.headline
        if let duration { text += "，已持续 " + duration }
        return text
    }

    private func titleRow(_ verdict: ItemVerdict, duration: String?) -> some View {
        HStack(spacing: 6) {
            LampView(level: verdict.level, size: 10)
                .uiTestFrame("lamp." + item.rawValue + ".card")
            Text(item.label + " · " + PanelFormat.levelWord(verdict.level))
                .font(PanelFont.headline)
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .uiTestFrame("txt.card.title")
            Spacer(minLength: 4)
            if let duration {
                Text(duration)
                    .font(PanelFont.callout)
                    .monospacedDigit()
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .numericChange(duration)
                    .uiTestFrame("txt.card.duration")
            }
            CopyIconButton(model: model, target: .row(item), item: item)
        }
        .frame(height: 20)
    }

    private func figureRow(_ facts: ProblemFacts) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(facts.value)
                    .font(PanelFont.display)
                    .monospacedDigit()
                    .foregroundStyle(tok.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .numericChange(facts.value)
                    .uiTestFrame("txt.card.figure")
                if !facts.unit.isEmpty {
                    Text(facts.unit)
                        .font(PanelFont.headline)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Text(facts.caption)
                .font(PanelFont.footnote)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestFrame("txt.card.caption")
        }
        .frame(height: 34, alignment: .bottom)
    }

    @ViewBuilder
    private func chart(_ verdict: ItemVerdict) -> some View {
        if item == .disk {
            DiskChart(series: data.diskSeries, trigger: data.diskTrigger, level: verdict.level,
                      totalBytes: data.status?.items.disk.total.value, compact: compact)
        } else {
            let height = compact ? PanelSize.chartHeightCompact - ProblemChart.labelRowHeight : PanelSize.chartHeight - ProblemChart.labelRowHeight
            let plot = ProblemPlotBuilder.make(item: item, data: data, since: verdict.since, plotHeight: height)
            ProblemChart(item: item, plot: plot, level: verdict.level, compact: compact)
        }
    }
}

struct CardBackground: View {
    let level: HealthLevel
    @Environment(\.tok) private var tok

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelSize.cardRadius, style: .continuous)
        shape
            .fill(tok.tint(level))
            .overlay(shape.strokeBorder(tok.lamp(level).opacity(0.22), lineWidth: 0.5))
    }
}

// MARK: - Evidence

private struct ProblemEvidence: View {
    @ObservedObject var model: PanelModel
    let item: HealthItem
    let verdict: ItemVerdict
    let height: Double

    var body: some View {
        switch item {
        case .cpu, .thermal:
            AppEvidence(apps: model.topApps(by: .cpu), sort: .cpu, height: height, isReading: model.data.apps.isEmpty,
                        basis: model.data.appsBasis)
        case .memory:
            AppEvidence(apps: model.topApps(by: .memory), sort: .memory, height: height, isReading: model.data.apps.isEmpty,
                        basis: model.data.appsBasis)
        case .disk:
            DiskEvidence(data: model.data, height: height)
        case .power:
            PowerEvidence(verdict: verdict, data: model.data, height: height)
        }
    }
}

private struct DiskEvidence: View {
    let data: PanelData
    let height: Double
    @Environment(\.tok) private var tok

    private func growthText(_ key: String) -> String {
        guard let bytes = data.status?.items.disk.growth[key]?.bytes else { return "—" }
        return (bytes >= 0 ? "+" : "") + ByteText.gb(bytes)
    }

    private func column(_ title: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
            Text(growthText(key))
                .font(PanelFont.headline)
                .monospacedDigit()
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .uiTestFrame("txt.disk.growth." + key)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availableText: String {
        let disk = data.status?.items.disk
        let avail = PanelFormat.bytes(disk?.availableImportant)
        let total = PanelFormat.bytes(disk?.total)
        return "可用 " + avail + "，共 " + total
    }

    /// The gaps share the height that the plan gives beyond the 68 pt minimum, so the card has no empty strip.
    private var gap: CGFloat { 4 + CGFloat(max(0, height - PanelMetrics.evidenceMin)) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: 8) {
                column("1 天增长", "1d")
                column("5 天增长", "5d")
                column("30 天增长", "30d")
            }
            Text(availableText)
                .font(PanelFont.footnote)
                .foregroundStyle(tok.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .uiTestFrame("txt.disk.available")
            Text("快照与系统缓存不计入已用")
                .font(PanelFont.footnote)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct PowerEvidence: View {
    let verdict: ItemVerdict
    let data: PanelData
    let height: Double
    @Environment(\.tok) private var tok

    private var isSleepRule: Bool { verdict.reasonCode.contains("sleep") }

    private var batteryText: String {
        let level = PanelFormat.percent(data.current.batteryPercent)
        var source = ""
        if let s = data.current.powerSource { source = s == .battery ? " · 电池供电" : " · 接电源" }
        return level + source
    }

    private var sleepText: String {
        guard let s = data.current.lastSleep else { return "—" }
        let length = PanelFormat.duration(seconds: s.wokeAt.timeIntervalSince(s.sleptAt))
        return length + String(format: " · %.0f%% → %.0f%%", s.batteryBefore, s.batteryAfter)
    }

    private var windowText: String {
        guard let rate = data.current.awakeDrainPerHour else { return "—" }
        return String(format: "近 60 分钟 −%.0f%%", rate)
    }

    private var thresholdText: String {
        isSleepRule ? "黄 ≥ 3%/小时 · 红 ≥ 6%/小时" : "黄 ≥ 30%/小时 · 红 ≥ 45%/小时"
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(PanelFont.footnote)
                .foregroundStyle(tok.textSecondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(PanelFont.footnote)
                .monospacedDigit()
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .uiTestFrame("txt.power." + title)
        }
        .frame(height: 16)
    }

    private var gap: CGFloat { 4 + CGFloat(max(0, height - PanelMetrics.evidenceMin)) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            line("电量", batteryText)
            line(isSleepRule ? "睡眠" : "窗口", isSleepRule ? sleepText : windowText)
            line("阈值", thresholdText)
        }
    }
}

// MARK: - Problem row

/// A collapsed problem item. A click opens it as the card and folds the old card into a row.
struct ProblemRow: View {
    @ObservedObject var model: PanelModel
    let item: HealthItem
    let compact: Bool

    @Environment(\.tok) private var tok

    var body: some View {
        if let verdict = model.data.verdict(item) {
            content(verdict)
        }
    }

    private func content(_ verdict: ItemVerdict) -> some View {
        let duration = verdict.since.map { PanelFormat.duration(seconds: model.data.now.timeIntervalSince($0)) }
        let height = compact ? PanelMetrics.problemRowCompact : PanelMetrics.problemRow
        return ZStack(alignment: .trailing) {
            Button(action: { model.toggleProblem(item) }) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        LampView(level: verdict.level, size: 10)
                        Text(item.label + " · " + PanelFormat.levelWord(verdict.level))
                            .font(PanelFont.headline)
                            .foregroundStyle(tok.textPrimary)
                            .lineLimit(1)
                            .uiTestFrame("txt.row.title." + item.rawValue)
                        Spacer(minLength: 4)
                        if let duration {
                            Text(duration)
                                .font(PanelFont.callout)
                                .monospacedDigit()
                                .foregroundStyle(tok.textSecondary)
                                .lineLimit(1)
                                .numericChange(duration)
                        }
                    }
                    Text(verdict.headline)
                        .font(PanelFont.footnote)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(1)
                        .padding(.leading, 16)
                        .uiTestFrame("txt.row.detail." + item.rawValue)
                }
                .padding(.leading, 12)
                .padding(.trailing, 64)
                .frame(width: PanelSize.contentWidth, height: height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ProblemRowButtonStyle(level: verdict.level))
            .accessibilityIdentifier("row." + item.rawValue)
            .accessibilityLabel(Text(PanelFormat.titled(item, verdict.level) + "，" + verdict.headline + "，展开"))

            HStack(spacing: 4) {
                CopyIconButton(model: model, target: .row(item), item: item)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tok.textSecondary)
                    .frame(width: 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, 10)
        }
        .frame(width: PanelSize.contentWidth, height: height)
        .uiTestFrame("row." + item.rawValue)
    }
}

/// The button style of a collapsed problem row. Light scheme: a gray fill and a 3 pt bar in the level color at the left edge (no tinted
/// fill, so only the first card has color, DESIGN.md 2.6). Dark scheme: the level tint, as the shared row style (PanelFooter.swift).
struct ProblemRowButtonStyle: ButtonStyle {
    var level: HealthLevel

    func makeBody(configuration: Configuration) -> some View {
        ProblemRowButtonBody(configuration: configuration, level: level)
    }
}

private struct ProblemRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let level: HealthLevel
    @Environment(\.tok) private var tok
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// The fill and the bar, cut together by the rounded corners.
    private func rowBackground(_ shape: RoundedRectangle) -> some View {
        ZStack(alignment: .leading) {
            shape.fill(tok.rowBackground(level))
            if let bar = tok.rowBar(level) {
                Rectangle().fill(bar).frame(width: 3)
            }
        }
        .clipShape(shape)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .background(rowBackground(shape))
            .overlay(shape.fill(hovering || configuration.isPressed ? tok.fillHover : Color.clear))
            .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : PanelMotion.quick, value: configuration.isPressed)
    }
}

// MARK: - Normal summary

struct NormalSummary: View {
    let items: [HealthItem]
    @Environment(\.tok) private var tok

    private var names: [String] {
        let shown: Set<HealthItem> = [.thermal, .memory, .cpu]
        let focused = items.filter { shown.contains($0) }
        return (focused.isEmpty ? items : focused).map { $0.label }
    }

    var body: some View {
        let text = "其余正常：" + names.joined(separator: "、")
        Text(text)
            .font(PanelFont.footnote)
            .foregroundStyle(tok.textSecondary)
            .lineLimit(1)
            .padding(.leading, 4)
            .frame(width: PanelSize.contentWidth, height: PanelMetrics.normalSummary, alignment: .leading)
            .uiTestFrame("txt.summary")
            .accessibilityIdentifier("label.normalSummary")
    }
}
