// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData, the "更多" state of the layout plan (includes the apps list and the authorization row when they were merged).
// Output: The "更多" disclosure row and its expanded content: disk 30 day chart, network chart, traffic, battery, sensors.
// Pos: Holds what is not a problem right now (docs/DESIGN.md 2.3, 2.14). Expanding it never changes the panel height; the middle area scrolls.

import SwiftUI

enum PanelMoreBattery {
    /// The engine has no power verdict on a Mac without a battery. A fixture or an old status can mark it not applicable.
    static func exists(_ data: PanelData) -> Bool {
        guard let v = data.verdict(.power) else { return false }
        return v.level != .notApplicable
    }
}

struct MoreDisclosure: View {
    @ObservedObject var model: PanelModel
    let expanded: Bool
    let includesApps: Bool
    let includesAuthorization: Bool
    let compact: Bool

    private var data: PanelData { model.data }
    private var isQuiet: Bool { model.layoutPlan.quiet }

    private func problemLevel(_ item: HealthItem) -> Bool {
        data.problems.contains { $0.item == item }
    }

    private var availableText: String {
        "磁盘可用 " + PanelFormat.bytes(data.status?.items.disk.availableImportant)
    }

    private var todayText: String? {
        guard let t = data.status?.items.network.traffic["today"], let rx = t.rx, let tx = t.tx else { return nil }
        return "今天 " + PanelFormat.trafficBytes(rx + tx)
    }

    /// A desktop Mac has no battery: the power item is not applicable and the row does not mention it.
    private var hasBattery: Bool { PanelMoreBattery.exists(data) }

    private var preview: String {
        if data.isCollecting { return "统计中" }
        var parts = [String]()
        if isQuiet {
            parts.append(availableText)
            if let today = todayText { parts.append(today) }
            return parts.joined(separator: " · ")
        }
        if includesApps { parts.append("占用 App") }
        if !problemLevel(.disk) { parts.append(availableText) }
        parts.append("网速")
        parts.append("流量")
        if !problemLevel(.power) && hasBattery { parts.append("电池") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            DisclosureRow(title: "更多", preview: preview, expanded: expanded, compact: compact, id: "more") {
                model.setMore(expanded: !expanded)
            }
            if expanded {
                MoreContent(model: model, includesApps: includesApps, includesAuthorization: includesAuthorization)
                    .transition(.opacity)
            }
        }
        .id("more")
    }
}

private struct MoreBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.tok) private var tok

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MoreContent: View {
    @ObservedObject var model: PanelModel
    let includesApps: Bool
    let includesAuthorization: Bool
    @Environment(\.tok) private var tok

    private var data: PanelData { model.data }

    private func isProblem(_ item: HealthItem) -> Bool {
        data.problems.contains { $0.item == item }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if includesAuthorization {
                AuthorizationRow(model: model)
            }
            if includesApps {
                AppsExpanded(model: model)
            }
            if !isProblem(.disk) {
                diskBlock
            }
            if !model.layoutPlan.quiet {
                networkBlock
            }
            trafficBlock
            if !isProblem(.power) && PanelMoreBattery.exists(data) {
                batteryBlock
            }
            sensorBlock
        }
        .padding(8)
        .frame(width: PanelSize.contentWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tok.plotBackground))
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list.more")
    }

    private var diskBlock: some View {
        MoreBlock(title: "磁盘 · 近 30 天已用") {
            DiskChart(series: data.diskSeries, trigger: data.diskTrigger, level: data.verdict(.disk)?.level ?? .green,
                      totalBytes: data.status?.items.disk.total.value, compact: true)
            Text(growthLine)
                .font(PanelFont.footnote)
                .monospacedDigit()
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
        }
    }

    private var growthLine: String {
        func part(_ title: String, _ key: String) -> String {
            guard let bytes = data.status?.items.disk.growth[key]?.bytes else { return title + " —" }
            return title + " " + (bytes >= 0 ? "+" : "") + ByteText.gb(bytes)
        }
        return part("1 天", "1d") + " · " + part("5 天", "5d") + " · " + part("30 天", "30d")
    }

    private var networkBlock: some View {
        let start = data.now.addingTimeInterval(-ProblemPlotBuilder.windowSeconds)
        let rx = MiniPlot.points(data.trend, from: start) { $0.rx }
        let tx = MiniPlot.points(data.trend, from: start) { $0.tx }
        let top = max(rx.map { $0.v }.max() ?? 0, tx.map { $0.v }.max() ?? 0)
        return MoreBlock(title: "网速 · 2 小时") {
            MiniLine(primary: rx, secondary: tx, domainX: start...data.now.addingTimeInterval(2),
                     domainY: 0...max(top * 1.2, 100_000))
                .frame(height: 40)
                .uiTestFrame("chart.net.more")
            HStack {
                Text(data.current.rx.map { "↓ " + RateText.text($0) } ?? "—")
                Spacer()
                Text(data.current.tx.map { "↑ " + RateText.text($0) } ?? "—")
            }
            .font(PanelFont.footnote)
            .monospacedDigit()
            .foregroundStyle(tok.textPrimary)
        }
    }

    private var trafficBlock: some View {
        let traffic = data.status?.items.network.traffic
        return MoreBlock(title: "流量 · 物理网卡合计") {
            trafficLine("今天", traffic?["today"])
            trafficLine("近 5 天", traffic?["5d"])
        }
    }

    private func trafficLine(_ title: String, _ totals: TrafficTotals?) -> some View {
        HStack {
            Text(title).foregroundStyle(tok.textSecondary)
            Spacer()
            Text(PanelFormat.traffic(totals)).monospacedDigit().foregroundStyle(tok.textPrimary)
        }
        .font(PanelFont.footnote)
    }

    private var batteryBlock: some View {
        let c = data.current
        var source = "—"
        if let s = c.powerSource { source = s == .battery ? "电池供电" : "接电源" }
        var sleepText = "—"
        let recent: SleepRecord? = c.lastSleep ?? data.sleeps.max(by: { $0.wokeAt < $1.wokeAt })
        if let s = recent {
            sleepText = PanelFormat.duration(seconds: s.wokeAt.timeIntervalSince(s.sleptAt))
                + String(format: " · %.0f%% → %.0f%%", s.batteryBefore, s.batteryAfter)
        }
        return MoreBlock(title: "电池") {
            HStack {
                Text("电量").foregroundStyle(tok.textSecondary)
                Spacer()
                Text(PanelFormat.percent(c.batteryPercent) + " · " + source).monospacedDigit().foregroundStyle(tok.textPrimary)
            }
            .font(PanelFont.footnote)
            HStack {
                Text("上次睡眠").foregroundStyle(tok.textSecondary)
                Spacer()
                Text(sleepText).monospacedDigit().foregroundStyle(tok.textPrimary)
            }
            .font(PanelFont.footnote)
        }
    }

    private var sensorBlock: some View {
        let c = data.current
        var temperature = "—"
        if let t = c.smcCPUTemperature { temperature = String(format: "%.0f°C", t) }
        var fans = "—"
        if let rpm = c.fanRPMs, !rpm.isEmpty {
            fans = rpm.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " 转/分"
        }
        return MoreBlock(title: "传感器 · 参考，不参与判定") {
            HStack {
                Text("CPU 传感器均值").foregroundStyle(tok.textSecondary)
                Spacer()
                Text(temperature).monospacedDigit().foregroundStyle(tok.textPrimary)
            }
            .font(PanelFont.footnote)
            HStack {
                Text("风扇").foregroundStyle(tok.textSecondary)
                Spacer()
                Text(fans).monospacedDigit().foregroundStyle(tok.textPrimary)
            }
            .font(PanelFont.footnote)
        }
    }
}
