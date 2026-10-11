// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: StatusFile, alerts, authorization, the 30 day disk series and the 60 second live snapshot from MonitorEngine.
// Output: SwiftUI status card (340 pt wide, no scrolling): header, disk trend card, live network and CPU card, traffic, alerts, authorization row, CLI hint, quit.
// Pos: Stage 1 status card (docs/PROJECT.md 4.2). No timers and no TimelineView: the only continuous motion is the live chart scroll, driven by new samples.

import AppKit
import Charts
import SwiftUI

/// How the card appears. `full` plays once per app start, `fade` is every later open, `none` is for static renders.
enum PanelEntrance {
    case full, fade, none
}

/// Remembers whether the full entrance has played since the app started.
enum PanelEntranceGate {
    private static var played = false

    static func next() -> PanelEntrance {
        if played { return .fade }
        played = true
        return .full
    }
}

/// Binds the engine to the pure `Panel`. Created on each popover open and released on close.
struct PanelContainer: View {
    @ObservedObject var engine: MonitorEngine
    var onQuit: () -> Void
    @State private var entrance = PanelEntranceGate.next()

    var body: some View {
        Panel(status: engine.status,
              alerts: engine.alerts,
              authorization: engine.authorization,
              diskSeries: engine.diskSeries,
              diskTrigger: engine.diskTrigger,
              live: engine.live,
              entrance: entrance,
              onEnableNotifications: { engine.requestNotificationAuthorization() },
              onQuit: onQuit)
    }
}

/// Pure view: all inputs are values, so the preview renderer needs no engine.
struct Panel: View {
    var status: StatusFile?
    var alerts: [AlertItem]
    var authorization: String
    var diskSeries: [DiskPoint] = []
    var diskTrigger: DiskTrigger?
    var live: LiveSnapshot = .empty
    var entrance: PanelEntrance = .none
    var onEnableNotifications: () -> Void
    var onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var revealed: Bool { shown || entrance == .none }
    private var level: HealthLevel { status?.overall.level ?? .unknown }
    private var smooth: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            staged(0) { header }
            staged(1) {
                DiskCard(status: status, series: diskSeries, trigger: diskTrigger, entrance: entrance)
                    .equatable()
            }
            staged(2) { LiveCard(live: live).uiTestFrame("card.live") }
            staged(3) {
                VStack(alignment: .leading, spacing: 6) {
                    trafficBlock
                    alertsBlock
                    authorizationBlock
                    footer
                }
            }
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .onAppear { shown = true }
    }

    /// Fades one block in. The index staggers the full entrance: the last block starts 90 ms in and ends by 290 ms.
    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content().modifier(StageModifier(index: index, revealed: revealed, entrance: entrance, reduceMotion: reduceMotion))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("MoleMonitor").font(.headline)
                Spacer()
                Text(PanelFormat.dataTime(status))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(PanelFormat.color(level))
                    .frame(width: 8, height: 8)
                    .animation(smooth, value: level)
                Text(status?.overall.summary ?? "正在统计")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("label.summary")
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Traffic

    private var trafficBlock: some View {
        let traffic = status?.items.network.traffic
        return VStack(alignment: .leading, spacing: 2) {
            trafficRow("今天流量", traffic?["today"])
            trafficRow("近 5 天流量", traffic?["5d"])
        }
        .padding(.horizontal, 2)
        .accessibilityIdentifier("block.traffic")
    }

    private func trafficRow(_ label: String, _ totals: TrafficTotals?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(PanelFormat.traffic(totals)).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    // MARK: Alerts

    @ViewBuilder
    private var alertsBlock: some View {
        if alerts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bell").font(.caption).foregroundStyle(.tertiary)
                Text("当前没有提醒").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("block.alerts")
        } else {
            let tint = PanelFormat.color(alerts.map { $0.level }.max { $0.severity < $1.severity } ?? .unknown)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<min(alerts.count, 2), id: \.self) { index in
                    alertRow(alerts[index])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
            .animation(smooth, value: alerts.count)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("提醒")
            .accessibilityIdentifier("block.alerts")
        }
    }

    private func alertRow(_ alert: AlertItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(PanelFormat.color(alert.level)).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.message)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("开始于 \(PanelFormat.dateTime(alert.since))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Notification authorization

    @ViewBuilder
    private var authorizationBlock: some View {
        switch authorization {
        case "not_determined":
            HStack(alignment: .center, spacing: 10) {
                Text("MoleMonitor 在磁盘异常增长等情况下发送系统通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onEnableNotifications) { Text("开启通知") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .uiTestFrame("btn.enableNotifications")
                    .accessibilityIdentifier("btn.enableNotifications")
                    .accessibilityLabel("开启通知")
            }
            .padding(.horizontal, 2)
        case "denied":
            authorizationNote("通知已关闭，可在系统设置 > 通知中打开")
        case "unavailable":
            authorizationNote("此环境无法发送通知，提醒只显示在这里")
        default:
            EmptyView()
        }
    }

    private func authorizationNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .uiTestFrame("label.authorization")
            .accessibilityIdentifier("label.authorization")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center) {
            Text(verbatim: "molemonitor-cli --status --brief")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("命令行读取状态：molemonitor-cli --status --brief")
            Spacer()
            Button(action: onQuit) { Text("退出") }
                .buttonStyle(PillButtonStyle())
                .uiTestFrame("btn.quit")
                .accessibilityIdentifier("btn.quit")
                .accessibilityLabel("退出 MoleMonitor")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Entrance

/// Opacity and a 6 pt rise. Reduce Motion removes the rise. A static render shows the end state at once.
private struct StageModifier: ViewModifier {
    var index: Int
    var revealed: Bool
    var entrance: PanelEntrance
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: (revealed || entrance != .full || reduceMotion) ? 0 : 6)
            .animation(animation, value: revealed)
    }

    private var animation: Animation? {
        switch entrance {
        case .none: return nil
        case .fade: return .easeOut(duration: 0.15)
        case .full:
            if reduceMotion { return .easeOut(duration: 0.15) }
            return .easeOut(duration: 0.20).delay(0.03 * Double(index))
        }
    }
}

// MARK: - UI regression hook

#if UITEST
extension View {
    /// Test only: reports the frame (hosting view space, y down) to UITestFrameStore, as a fallback for the accessibility tree.
    func uiTestFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { UITestFrameStore.shared.set(id, proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in UITestFrameStore.shared.set(id, frame) }
        })
    }
}
#else
extension View {
    /// Release build: no effect.
    @inline(__always)
    func uiTestFrame(_ id: String) -> some View { self }
}
#endif

// MARK: - Shared look

private extension View {
    /// Rounded card on a system semantic fill. The popover supplies the blur behind it.
    func cardBackground() -> some View {
        background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// Pure SwiftUI button look (hover and pressed states), so the same view also renders in ImageRenderer.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if prominent {
            return Color.accentColor.opacity(configuration.isPressed ? 0.75 : (hovering ? 0.92 : 1))
        }
        return Color.primary.opacity(configuration.isPressed ? 0.20 : (hovering ? 0.13 : 0.08))
    }
}

// MARK: - Disk card

/// Disk card. Compared by data only, so a live tick every 2 seconds does not rebuild the chart.
private struct DiskCard: View, Equatable {
    var status: StatusFile?
    var series: [DiskPoint]
    var trigger: DiskTrigger?
    var entrance: PanelEntrance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: DiskCard, b: DiskCard) -> Bool {
        a.status?.writtenAt == b.status?.writtenAt && a.series == b.series && a.trigger == b.trigger
            && a.entrance == b.entrance
    }

    private var disk: DiskItem? { status?.items.disk }
    private var level: HealthLevel { disk?.level ?? .unknown }
    private var smooth: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            DiskTrendChart(series: series, trigger: trigger, level: level, totalBytes: disk?.total.value, entrance: entrance)
                .uiTestFrame("chart.disk")
            HStack(spacing: 0) {
                ForEach(PanelFormat.windows) { window in
                    growthColumn(window)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.disk")
        .accessibilityLabel("磁盘")
    }

    private var topRow: some View {
        let parts = PanelFormat.gbParts(disk?.used)
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("已用").font(.subheadline).foregroundStyle(.secondary)
                Text(parts.value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(smooth, value: parts.value)
                Text(parts.unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("已用 \(parts.value) \(parts.unit)")
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 6) {
                Text("共 \(PanelFormat.bytes(disk?.total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(PanelFormat.levelText(level))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PanelFormat.color(level))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PanelFormat.color(level).opacity(0.15)))
                    .animation(smooth, value: level)
                    .accessibilityLabel("磁盘状态 \(PanelFormat.levelText(level))")
            }
        }
    }

    private func growthColumn(_ window: PanelFormat.Window) -> some View {
        let shown = PanelFormat.growth(disk?.growth[window.key])
        let highlighted = trigger?.windowKey == window.key
        let spoken = shown.note.map { shown.text + "，" + $0 } ?? shown.text
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(window.label)增长").font(.caption2).foregroundStyle(.secondary)
            Text(shown.text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(highlighted ? PanelFormat.color(trigger?.level ?? .unknown) : Color.primary)
                .contentTransition(.numericText())
                .animation(smooth, value: shown.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label)增长 \(spoken)")
        .help(shown.note ?? "")
    }
}

/// 30 day area chart with catmullRom smoothing, the trigger segment in the level color, a line for today and a hover tip.
private struct DiskTrendChart: View {
    var series: [DiskPoint]
    var trigger: DiskTrigger?
    var level: HealthLevel
    /// Capacity of the volume. The vertical range is never narrower than 6% of it, so small noise stays small.
    var totalBytes: Int64?
    var entrance: PanelEntrance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: DiskPoint?
    @State private var drawn = false

    private var now: Date { series.last?.t ?? Date() }
    /// Points under the blue area: all of them, or only those before the trigger start (the segment has its own area).
    private var baseArea: [DiskPoint] {
        guard let trigger else { return series }
        return series.filter { $0.t <= trigger.from } + [DiskPoint(t: trigger.from, used: trigger.fromUsed)]
    }
    private var segment: [DiskPoint] {
        guard let trigger else { return [] }
        return DiskSeries.triggerPoints(series: series, trigger: trigger)
    }
    /// The reveal runs only in the first open after the app start, and never with Reduce Motion.
    private var isDrawn: Bool { drawn || entrance != .full || reduceMotion }
    private var domainX: ClosedRange<Date> {
        let first = series.first?.t ?? now
        let start = min(first, now.addingTimeInterval(-86400))
        let span = now.timeIntervalSince(start)
        return start...now.addingTimeInterval(span * 0.04)
    }
    private var domainY: ClosedRange<Double> {
        var values = series.map { $0.gb }
        if let trigger { values.append(Double(trigger.fromUsed) / 1e9) }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.18, 0.5)
        var low = lo - pad
        var high = hi + pad
        if let totalBytes, totalBytes > 0 {
            let minSpan = Double(totalBytes) / 1e9 * 0.06
            if high - low < minSpan {
                let mid = (high + low) / 2
                low = max(0, mid - minSpan / 2)
                high = low + minSpan
            }
        }
        return low...high
    }

    var body: some View {
        let yRange = domainY
        let tint = PanelFormat.color(trigger?.level ?? level)
        Chart {
            ForEach(baseArea) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("基线", yRange.lowerBound), yEnd: .value("已用", p.gb),
                         series: .value("区", "base"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(series) { p in
                LineMark(x: .value("时间", p.t), y: .value("已用", p.gb), series: .value("线", "base"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            ForEach(segment) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("基线", yRange.lowerBound), yEnd: .value("已用", p.gb),
                         series: .value("区", "trigger"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(segment) { p in
                LineMark(x: .value("时间", p.t), y: .value("已用", p.gb), series: .value("线", "trigger"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            RuleMark(x: .value("今天", now))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            if let last = series.last {
                PointMark(x: .value("时间", last.t), y: .value("已用", last.gb))
                    .symbolSize(34)
                    .foregroundStyle(PanelFormat.color(level))
            }
            if let h = hovered {
                RuleMark(x: .value("时间", h.t))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(h)
                    }
                PointMark(x: .value("时间", h.t), y: .value("已用", h.gb))
                    .symbolSize(40)
                    .foregroundStyle(Color.primary)
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: yRange)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { hovered = nil; return }
                            let x = location.x - geo[frame].origin.x
                            if let date: Date = proxy.value(atX: x) { hovered = nearest(to: date) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: 54)
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: isDrawn ? 1 : 0.001, anchor: .leading)
        }
        .overlay {
            if series.count < 2 {
                Text("历史数据积累中").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            guard entrance == .full, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) { drawn = true }
        }
        .accessibilityIdentifier("chart.disk")
        .accessibilityLabel("磁盘近 30 天已用空间趋势图")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let first = series.first, let last = series.last else { return "暂无数据" }
        return "从 \(Int(first.gb.rounded())) GB 到 \(Int(last.gb.rounded())) GB"
    }

    private func nearest(to date: Date) -> DiskPoint? {
        series.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
    }

    private func tooltip(_ p: DiskPoint) -> some View {
        VStack(spacing: 0) {
            Text(PanelFormat.dateTime(p.t)).font(.caption2).foregroundStyle(.secondary)
            Text(ByteText.gb(p.used)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
    }
}

// MARK: - Live card

/// Network and CPU lines over the last 60 seconds. Data exists only while the panel is open.
private struct LiveCard: View {
    var live: LiveSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let downColor = Color.blue
    private static let upColor = Color.purple
    private static let cpuColor = Color.teal

    private var smooth: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }
    /// Chart animation: about as long as one sample interval, so the scroll looks continuous.
    private var scroll: Animation? { reduceMotion ? nil : .smooth(duration: 1.0) }
    private var windowEnd: Date { live.latest ?? Date() }
    private var domainX: ClosedRange<Date> { windowEnd.addingTimeInterval(-LiveSnapshot.windowSeconds)...windowEnd }

    var body: some View {
        VStack(spacing: 6) {
            netRow
            cpuRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.live")
        .accessibilityLabel("实时")
    }

    // MARK: Network

    private var netRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                rateLine(symbol: "arrow.down", color: Self.downColor, value: live.rx, name: "下行")
                rateLine(symbol: "arrow.up", color: Self.upColor, value: live.tx, name: "上行")
            }
            .frame(width: 112, alignment: .leading)
            netChart
        }
    }

    private func rateLine(symbol: String, color: Color, value: Double?, name: String) -> some View {
        let parts = value.map { RateText.parts($0) }
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 10)
            Text(parts?.value ?? "—")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(smooth, value: parts?.value)
            Text(parts?.unit ?? "").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(RateText.text(value))")
    }

    private var netChart: some View {
        let peak = live.net.map { max($0.rx, $0.tx) }.max() ?? 0
        let yMax = max(peak * 1.25, 20_000)
        return Chart {
            ForEach(live.net) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("零", 0), yEnd: .value("下行", p.rx), series: .value("区", "down"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Self.downColor.opacity(0.28), Self.downColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(live.net) { p in
                LineMark(x: .value("时间", p.t), y: .value("下行", p.rx), series: .value("线", "down"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Self.downColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(live.net) { p in
                LineMark(x: .value("时间", p.t), y: .value("上行", p.tx), series: .value("线", "up"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Self.upColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plotLook(plot) }
        .frame(height: 34)
        .uiTestFrame("chart.net")
        .overlay { if live.net.count < 2 { waiting } }
        .animation(scroll, value: live.net.last?.t)
        .accessibilityIdentifier("chart.net")
        .accessibilityLabel("网速折线图，最近 60 秒")
        .accessibilityValue("下行 \(RateText.text(live.rx))，上行 \(RateText.text(live.tx))")
    }

    // MARK: CPU

    private var cpuRow: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("CPU").font(.caption2).foregroundStyle(.secondary)
                Text(RateText.percent(live.cpuPercent))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(smooth, value: RateText.percent(live.cpuPercent))
                    .accessibilityLabel("CPU 使用率 \(RateText.percent(live.cpuPercent))")
            }
            .frame(width: 112, alignment: .leading)
            cpuChart
        }
    }

    private var cpuChart: some View {
        Chart {
            ForEach(live.cpu) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("零", 0), yEnd: .value("CPU", p.percent))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Self.cpuColor.opacity(0.28), Self.cpuColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(live.cpu) { p in
                LineMark(x: .value("时间", p.t), y: .value("CPU", p.percent))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Self.cpuColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: 0.0...100.0)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plotLook(plot) }
        .frame(height: 34)
        .uiTestFrame("chart.cpu")
        .overlay { if live.cpu.count < 2 { waiting } }
        .animation(scroll, value: live.cpu.last?.t)
        .accessibilityIdentifier("chart.cpu")
        .accessibilityLabel("CPU 使用率折线图，最近 60 秒")
        .accessibilityValue(RateText.percent(live.cpuPercent))
    }

    private func plotLook(_ plot: ChartPlotContent) -> some View {
        plot
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var waiting: some View {
        Text("采样中").font(.caption2).foregroundStyle(.tertiary)
    }
}

// MARK: - Text and color helpers

/// Missing values give a dash or "统计中", never 0.
enum PanelFormat {
    struct Window: Identifiable {
        var key: String
        var label: String
        var id: String { key }
    }

    static let windows = [Window(key: "1d", label: "1 天"), Window(key: "5d", label: "5 天"),
                          Window(key: "30d", label: "30 天")]

    // Fixed format and locale, so output does not depend on the user's region settings.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func dateTime(_ d: Date) -> String { dateTimeFormatter.string(from: d) }

    static func dataTime(_ status: StatusFile?) -> String {
        guard let status else { return "尚无数据" }
        let age = Date().timeIntervalSince(status.writtenAt)
        let stamp = "数据 \(timeFormatter.string(from: status.writtenAt))"
        return age > StatusStore.freshSeconds ? stamp + "（已过期）" : stamp
    }

    static func color(_ level: HealthLevel) -> Color {
        switch level {
        case .green: return Color.green
        case .yellow: return Color.orange
        case .red: return Color.red
        default: return Color.gray
        }
    }

    static func levelText(_ level: HealthLevel) -> String {
        switch level {
        case .green: return "正常"
        case .yellow: return "需留意"
        case .red: return "异常"
        case .stale: return "数据过期"
        case .unknown, .notApplicable: return "统计中"
        }
    }

    static func bytes(_ m: Measured<Int64>?) -> String {
        guard let m, m.status == .ok, let v = m.value else { return "—" }
        return ByteText.gb(v)
    }

    /// "583" and "GB" for the large number. A missing value gives a dash and no unit.
    static func gbParts(_ m: Measured<Int64>?) -> (value: String, unit: String) {
        guard let m, m.status == .ok, let v = m.value else { return ("—", "") }
        let pieces = ByteText.gb(v).split(separator: " ", maxSplits: 1).map(String.init)
        return pieces.count == 2 ? (pieces[0], pieces[1]) : (pieces.first ?? "—", "")
    }

    /// "已记录 N 小时" under one day, otherwise "已记录 N.N 天".
    static func recorded(hours: Double) -> String {
        if hours < 1 { return "已记录不足 1 小时" }
        if hours < 24 { return "已记录 \(Int(hours)) 小时" }
        return String(format: "已记录 %.1f 天", hours / 24)
    }

    static func growth(_ g: DiskGrowth?) -> (text: String, note: String?) {
        guard let g else { return ("统计中", nil) }
        switch g.status {
        case .ok:
            if let b = g.bytes { return ("+" + ByteText.gb(b), nil) }
            return ("—", nil)
        case .insufficientWindow, .collecting:
            let note: String? = g.coveredHours > 0 ? recorded(hours: g.coveredHours) : nil
            if let b = g.bytes { return ("至少 +" + ByteText.gb(b), note) }
            return ("统计中", note)
        default:
            return ("—", nil)
        }
    }

    static func trafficBytes(_ v: Int64) -> String {
        if v >= 1_000_000_000 { return ByteText.gb(v) }
        if v >= 1_000_000 { return String(format: "%.0f MB", Double(v) / 1e6) }
        return String(format: "%.0f KB", Double(v) / 1e3)
    }

    static func traffic(_ t: TrafficTotals?) -> String {
        guard let t, let rx = t.rx, let tx = t.tx else { return "统计中" }
        let prefix = (t.status == .ok) ? "" : "至少 "
        return "\(prefix)下行 \(trafficBytes(rx)) · 上行 \(trafficBytes(tx))"
    }
}

// MARK: - Preview data

/// Invented data for `--preview`, built by Core's PreviewScenario. It does not touch the engine or the data directory.
@MainActor
enum PanelSample {
    static func panel(level: PreviewLevel, now: Date = Date()) -> Panel {
        let (result, samples) = PreviewScenario.result(level, now: now)
        let authorization: String
        switch level {
        case .red: authorization = "not_determined"
        case .yellow: authorization = "denied"
        case .green: authorization = "authorized"
        }
        let status = StatusFile(appVersion: AppInfo.version, writtenAt: now, writerPid: 0,
                                overall: result.overall, items: result.items, activeAlerts: result.activeAlerts,
                                notifications: .init(authorization: authorization))
        return Panel(status: status, alerts: result.activeAlerts, authorization: authorization,
                     diskSeries: DiskSeries.downsample(samples: samples, now: now),
                     diskTrigger: DiskSeries.trigger(verdict: result.verdict, samples: samples),
                     live: PreviewScenario.live(now: now),
                     entrance: .none,
                     onEnableNotifications: {}, onQuit: {})
    }
}
