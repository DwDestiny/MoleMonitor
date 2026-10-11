// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData trend series, the problem start time, the disk series and the color tokens.
// Output: The trend strip (two neutral mini lines), the problem chart (2 hour, layered coarse and fine charts), and the 30 day disk chart.
// Pos: Every chart of the status card (docs/DESIGN.md 2.7). Swift Charts only. No Timer and no TimelineView: the charts redraw when new points arrive.

import Charts
import SwiftUI

// MARK: - Plot data (pure values, built outside the view bodies)

struct PlotPoint: Identifiable, Equatable {
    var id: Int
    /// Index of the unbroken run. A gap starts a new run, so the line does not connect across it.
    var seg: Int
    var t: Date
    var v: Double
}

struct PlotBand: Identifiable, Equatable {
    enum Kind: Equatable { case warning, danger, neutral }
    var id: Int
    var kind: Kind
    var x0: Date
    var x1: Date
    var y0: Double
    var y1: Double
}

enum PlotUnit: Equatable { case percent, gigabytes }

struct ProblemPlot: Equatable {
    var baseCoarse = [PlotPoint]()
    var hotCoarse = [PlotPoint]()
    var baseFine = [PlotPoint]()
    var hotFine = [PlotPoint]()
    var bands = [PlotBand]()
    var thresholds = [Double]()
    var domainX: ClosedRange<Date>
    var domainY: ClosedRange<Double>
    var last: PlotPoint?
    var lastIsHot = false
    var unit: PlotUnit = .percent

    var hasData: Bool { last != nil }

    /// All points in time order, for the hover lookup.
    var everyPoint: [PlotPoint] {
        let merged = baseCoarse + hotCoarse + baseFine + hotFine
        return merged.sorted { $0.t < $1.t }
    }
}

private struct PlotSample {
    var t: Date
    var v: Double
}

private struct PlotLayers {
    var baseCoarse = [PlotPoint]()
    var hotCoarse = [PlotPoint]()
    var baseFine = [PlotPoint]()
    var hotFine = [PlotPoint]()
    var nextId = 0

    mutating func add(_ s: PlotSample, seg: Int, fine: Bool, hot: Bool) {
        let p = PlotPoint(id: nextId, seg: seg, t: s.t, v: s.v)
        nextId += 1
        switch (fine, hot) {
        case (false, false): baseCoarse.append(p)
        case (false, true): hotCoarse.append(p)
        case (true, false): baseFine.append(p)
        case (true, true): hotFine.append(p)
        }
    }
}

private struct BandStyle: Equatable {
    var kind: PlotBand.Kind
    var heightPt: Double?
}

enum ProblemPlotBuilder {
    static let windowSeconds: TimeInterval = 7200
    static let fineSeconds: TimeInterval = 300

    static func value(_ item: HealthItem, _ p: TrendPoint) -> Double? {
        switch item {
        case .cpu, .thermal: return p.cpu
        case .memory: return p.swapUsed.map { Double($0) / 1e9 }
        case .power: return p.battery
        case .disk: return nil
        }
    }

    /// Splits the 2 hour series into the coarse and the fine layer, and into the neutral part and the abnormal part.
    static func make(item: HealthItem, data: PanelData, since: Date?, plotHeight: Double) -> ProblemPlot {
        let end = data.now.addingTimeInterval(2)
        let start = data.now.addingTimeInterval(-windowSeconds)

        // Runs of points that have a value.
        var runs = [[PlotSample]]()
        var maxValue = 0.0
        for segment in data.trend.segments {
            var run = [PlotSample]()
            for p in segment where p.t >= start {
                if let v = value(item, p) {
                    run.append(PlotSample(t: p.t, v: v))
                    maxValue = max(maxValue, v)
                } else if !run.isEmpty {
                    runs.append(run)
                    run = []
                }
            }
            if !run.isEmpty { runs.append(run) }
        }

        let latest = data.trend.latest?.t ?? data.now
        let fineCut = latest.addingTimeInterval(-fineSeconds)
        var layers = PlotLayers()
        var lastSample: PlotSample?
        var lastHot = false
        for (segIndex, run) in runs.enumerated() {
            for (i, s) in run.enumerated() {
                let fine = s.t > fineCut
                var hot = false
                if let since { hot = s.t >= since }
                if i > 0 {
                    let prev = run[i - 1]
                    let prevFine = prev.t > fineCut
                    var prevHot = false
                    if let since { prevHot = prev.t >= since }
                    // When the layer or the color changes, the new part starts with the previous point, so the line stays continuous.
                    if fine != prevFine || hot != prevHot { layers.add(prev, seg: segIndex, fine: fine, hot: hot) }
                }
                layers.add(s, seg: segIndex, fine: fine, hot: hot)
                lastSample = s
                lastHot = hot
            }
        }

        var domainY: ClosedRange<Double> = 0...100
        var unit = PlotUnit.percent
        if item == .memory {
            domainY = 0...max(maxValue * 1.3, 1)
            unit = .gigabytes
        }
        var plot = ProblemPlot(domainX: start...end, domainY: domainY)
        plot.baseCoarse = layers.baseCoarse
        plot.hotCoarse = layers.hotCoarse
        plot.baseFine = layers.baseFine
        plot.hotFine = layers.hotFine
        plot.unit = unit
        plot.thresholds = item == .cpu ? [70, 90] : []
        if let lastSample {
            plot.last = PlotPoint(id: -1, seg: max(0, runs.count - 1), t: lastSample.t, v: lastSample.v)
            plot.lastIsHot = lastHot
        }
        plot.bands = bands(item: item, data: data, domainX: start...end, domainY: domainY, plotHeight: plotHeight)
        return plot
    }

    private static func style(_ item: HealthItem, _ p: TrendPoint) -> BandStyle? {
        switch item {
        case .memory:
            guard let pressure = p.pressure else { return nil }
            switch pressure {
            case .normal: return nil
            case .warning: return BandStyle(kind: .warning, heightPt: nil)
            case .critical: return BandStyle(kind: .danger, heightPt: nil)
            }
        case .thermal:
            guard let thermal = p.thermal else { return nil }
            switch thermal {
            case .nominal: return nil
            case .fair: return BandStyle(kind: .warning, heightPt: 2)
            case .serious: return BandStyle(kind: .danger, heightPt: 4)
            case .critical: return BandStyle(kind: .danger, heightPt: 6)
            }
        case .power:
            guard let source = p.power, source == .ac else { return nil }
            return BandStyle(kind: .neutral, heightPt: 2)
        default:
            return nil
        }
    }

    private static func bands(item: HealthItem, data: PanelData, domainX: ClosedRange<Date>,
                              domainY: ClosedRange<Double>, plotHeight: Double) -> [PlotBand] {
        guard item == .memory || item == .thermal || item == .power else { return [] }
        let span = domainY.upperBound - domainY.lowerBound
        var out = [PlotBand]()
        var nextId = 0
        for seg in data.trend.segments {
            var i = 0
            while i < seg.count {
                let current = style(item, seg[i])
                var j = i
                while j + 1 < seg.count && style(item, seg[j + 1]) == current { j += 1 }
                if let current, seg[j].t >= domainX.lowerBound {
                    let x0 = max(seg[i].t, domainX.lowerBound)
                    var x1 = seg[j].t.addingTimeInterval(TrendBuffer.coarseInterval)
                    if j + 1 < seg.count { x1 = seg[j + 1].t }
                    x1 = min(x1, domainX.upperBound)
                    var top = domainY.upperBound
                    if let h = current.heightPt { top = domainY.lowerBound + h / plotHeight * span }
                    out.append(PlotBand(id: nextId, kind: current.kind, x0: x0, x1: x1, y0: domainY.lowerBound, y1: top))
                    nextId += 1
                }
                i = j + 1
            }
        }
        return out
    }
}

// MARK: - Problem chart (two layered charts)

/// The 2 hour chart of a problem card. The coarse chart draws the old points and redraws only for a new coarse point.
/// The fine chart on top draws the last 5 minutes and redraws every 2 seconds (docs/DESIGN.md 2.7).
struct ProblemChart: View {
    let item: HealthItem
    let plot: ProblemPlot
    let level: HealthLevel
    let compact: Bool

    @Environment(\.tok) private var tok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelSnapshot) private var snapshot
    @State private var hovered: PlotPoint?

    static let labelRowHeight = 14.0

    private var plotHeight: Double { compact ? PanelSize.chartHeightCompact - Self.labelRowHeight : PanelSize.chartHeight - Self.labelRowHeight }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CoarseLayer(plot: plot, level: level, tok: tok, snapshot: snapshot, hovered: $hovered)
                    .equatable()
                if plot.hasData {
                    FineLayer(plot: plot, level: level, tok: tok, hovered: hovered, reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                } else {
                    EmptyTrendHint()
                }
            }
            .frame(height: plotHeight)
            .uiTestFrame("chart.problem")
            HStack {
                Text("2 小时前")
                Spacer()
                Text("现在")
            }
            .font(PanelFont.caption)
            .foregroundStyle(tok.textSecondary)
            .frame(height: Self.labelRowHeight, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chart.problem")
        .accessibilityLabel(Text("\(item.label)近 2 小时趋势图"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let last = plot.last else { return "暂无数据" }
        return valueText(last.v)
    }

    private func valueText(_ v: Double) -> String {
        switch plot.unit {
        case .percent: return String(format: "%.0f%%", v)
        case .gigabytes: return String(format: "%.1f GB", v)
        }
    }
}

private struct EmptyTrendHint: View {
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack {
            DashedBaseline()
                .stroke(tok.textSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text("趋势从现在开始记录，30 秒一个点")
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
                .uiTestFrame("txt.chart.empty")
        }
    }
}

struct DashedBaseline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
        return p
    }
}

private struct CoarseLayer: View, Equatable {
    let plot: ProblemPlot
    let level: HealthLevel
    let tok: PanelTokens
    let snapshot: Bool
    @Binding var hovered: PlotPoint?

    static func == (a: CoarseLayer, b: CoarseLayer) -> Bool {
        a.plot.baseCoarse == b.plot.baseCoarse && a.plot.hotCoarse == b.plot.hotCoarse && a.plot.bands == b.plot.bands
            && a.plot.domainX == b.plot.domainX && a.plot.domainY == b.plot.domainY && a.level == b.level
            && a.tok.dark == b.tok.dark
    }

    private func bandColor(_ kind: PlotBand.Kind) -> Color {
        switch kind {
        case .warning: return tok.lampWarning.opacity(0.10)
        case .danger: return tok.lampDanger.opacity(0.14)
        case .neutral: return tok.chartNeutral
        }
    }

    var body: some View {
        let hotColor = tok.lamp(level)
        let hotLine = tok.chartHot(level)
        let neutral = tok.chartNeutral
        let floor = plot.domainY.lowerBound
        Chart {
            ForEach(plot.bands) { b in
                RectangleMark(xStart: .value("起", b.x0), xEnd: .value("止", b.x1),
                              yStart: .value("下", b.y0), yEnd: .value("上", b.y1))
                    .foregroundStyle(bandColor(b.kind))
            }
            ForEach(plot.thresholds, id: \.self) { th in
                RuleMark(y: .value("阈值", th))
                    .foregroundStyle(tok.textSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 0) {
                        // Only the warning threshold has a label. The higher one would touch it.
                        Text(th == plot.thresholds.first ? String(format: "%.0f", th) : "")
                            .font(PanelFont.caption)
                            .foregroundStyle(tok.textSecondary)
                    }
            }
            ForEach(plot.hotCoarse) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("下", floor), yEnd: .value("值", p.v),
                         series: .value("区", "a\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(hotColor.opacity(0.15))
            }
            ForEach(plot.baseCoarse) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "b\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            ForEach(plot.hotCoarse) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "h\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(hotLine)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: plot.domainX)
        .chartYScale(domain: plot.domainY)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { area in
            area
                .background(tok.plotBackground)
                .clipShape(RoundedRectangle(cornerRadius: PanelSize.chartRadius, style: .continuous))
        }
        .chartOverlay { proxy in hoverLayer(proxy) }
    }

    @ViewBuilder
    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        if snapshot {
            Color.clear
        } else {
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
    }

    private func nearest(to date: Date) -> PlotPoint? {
        plot.everyPoint.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
    }
}

private struct FineLayer: View {
    let plot: ProblemPlot
    let level: HealthLevel
    let tok: PanelTokens
    let hovered: PlotPoint?
    let reduceMotion: Bool

    private func tooltipText(_ p: PlotPoint) -> String {
        let value: String
        switch plot.unit {
        case .percent: value = String(format: "%.0f%%", p.v)
        case .gigabytes: value = String(format: "%.1f GB", p.v)
        }
        return PanelFormat.clock(p.t) + " · " + value
    }

    var body: some View {
        let hotColor = tok.lamp(level)
        let hotLine = tok.chartHot(level)
        let neutral = tok.chartNeutral
        let dotColor = plot.lastIsHot ? hotLine : neutral
        Chart {
            ForEach(plot.hotFine) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("下", plot.domainY.lowerBound), yEnd: .value("值", p.v),
                         series: .value("区", "fa\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(hotColor.opacity(0.15))
            }
            ForEach(plot.baseFine) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "fb\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            ForEach(plot.hotFine) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "fh\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(hotLine)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let last = plot.last {
                PointMark(x: .value("时间", last.t), y: .value("值", last.v))
                    .symbolSize(25)
                    .foregroundStyle(dotColor)
            }
            if let h = hovered {
                RuleMark(x: .value("时间", h.t))
                    .foregroundStyle(tok.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(tooltipText(h))
                            .font(PanelFont.caption)
                            .monospacedDigit()
                            .foregroundStyle(tok.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
                    }
                PointMark(x: .value("时间", h.t), y: .value("值", h.v))
                    .symbolSize(30)
                    .foregroundStyle(tok.textPrimary)
            }
        }
        .chartXScale(domain: plot.domainX)
        .chartYScale(domain: plot.domainY)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.25), value: plot.last?.t)
    }
}

// MARK: - Mini lines (trend strip, neutral only)

struct MiniLine: View {
    let primary: [PlotPoint]
    var secondary = [PlotPoint]()
    let domainX: ClosedRange<Date>
    let domainY: ClosedRange<Double>
    @Environment(\.tok) private var tok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let neutral = tok.chartNeutral
        let floor = domainY.lowerBound
        Chart {
            ForEach(primary) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("下", floor), yEnd: .value("值", p.v),
                         series: .value("区", "a\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tok.chartNeutralFill)
            }
            ForEach(primary) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "p\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            ForEach(secondary) { p in
                LineMark(x: .value("时间", p.t), y: .value("值", p.v), series: .value("线", "q\(p.seg)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [2, 2]))
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: domainY)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { area in
            area.background(tok.plotBackground).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.25), value: primary.last?.t)
    }
}

enum MiniPlot {
    /// Keeps about one point per 30 seconds (the coarse part). Falls back to all points when that leaves fewer than two.
    static func coarse(_ points: [TrendPoint]) -> [TrendPoint] {
        var kept = [TrendPoint]()
        var lastKept: Date?
        for p in points {
            if let l = lastKept, p.t.timeIntervalSince(l) < 25 { continue }
            kept.append(p)
            lastKept = p.t
        }
        return kept.count >= 2 ? kept : points
    }

    static func points(_ series: TrendSeries, from start: Date, value: (TrendPoint) -> Double?) -> [PlotPoint] {
        var out = [PlotPoint]()
        var nextId = 0
        var seg = 0
        for segment in series.segments {
            var openRun = false
            for p in coarse(segment) where p.t >= start {
                if let v = value(p) {
                    out.append(PlotPoint(id: nextId, seg: seg, t: p.t, v: v))
                    nextId += 1
                    openRun = true
                } else if openRun {
                    seg += 1
                    openRun = false
                }
            }
            seg += 1
        }
        return out
    }
}

/// The trend strip of the quiet mode: CPU and network, 2 hours, both neutral.
struct TrendStrip: View {
    let data: PanelData
    @Environment(\.tok) private var tok

    private var domainX: ClosedRange<Date> {
        data.now.addingTimeInterval(-ProblemPlotBuilder.windowSeconds)...data.now.addingTimeInterval(2)
    }

    var body: some View {
        let start = domainX.lowerBound
        // A restored trend shows while the first readings are still collected (docs/DESIGN.md D5). Without a trend the strip shows a hint.
        let cpu: [PlotPoint] = MiniPlot.points(data.trend, from: start) { $0.cpu }
        let rx: [PlotPoint] = MiniPlot.points(data.trend, from: start) { $0.rx }
        let tx: [PlotPoint] = MiniPlot.points(data.trend, from: start) { $0.tx }
        let netMax = max(rx.map { $0.v }.max() ?? 0, tx.map { $0.v }.max() ?? 0)
        let cpuMax = cpu.map { $0.v }.max() ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                column(title: "CPU · 2 小时", value: PanelFormat.percent(data.current.cpuPercent), id: "cpu") {
                    MiniLine(primary: cpu, domainX: domainX, domainY: 0...max(30, cpuMax * 1.25))
                }
                column(title: "网速 · 2 小时", value: downloadText, id: "net") {
                    MiniLine(primary: rx, secondary: tx, domainX: domainX, domainY: 0...max(netMax * 1.2, 100_000))
                }
            }
            if cpu.isEmpty && rx.isEmpty {
                Text("趋势从现在开始记录，30 秒一个点")
                    .font(PanelFont.caption)
                    .foregroundStyle(tok.textSecondary)
                    .padding(.top, 4)
                    .uiTestFrame("txt.trend.empty")
            }
        }
        .frame(height: PanelMetrics.trendStrip, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.trend")
    }

    private var downloadText: String {
        guard let rx = data.current.rx else { return "—" }
        return "↓ " + RateText.text(rx)
    }

    private func column<Plot: View>(title: String, value: String, id: String,
                                    @ViewBuilder chart: () -> Plot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(PanelFont.caption)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value)
                    .font(PanelFont.callout)
                    .monospacedDigit()
                    .foregroundStyle(tok.textPrimary)
                    .lineLimit(1)
                    .numericChange(value)
            }
            .frame(height: 16)
            chart()
                .frame(height: PanelSize.miniChartHeight)
                .uiTestFrame("chart." + id)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("chart." + id)
                .accessibilityLabel(Text(title + "趋势图"))
                .accessibilityValue(Text(value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Disk 30 day chart

/// Capacity-neutral 30 day used-space chart. The base line is neutral. The trigger segment takes the level color.
struct DiskChart: View {
    let series: [DiskPoint]
    let trigger: DiskTrigger?
    let level: HealthLevel
    let totalBytes: Int64?
    let compact: Bool

    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot
    @State private var hovered: DiskPoint?

    private var plotHeight: Double { (compact ? PanelSize.chartHeightCompact : PanelSize.chartHeight) - ProblemChart.labelRowHeight }
    private var now: Date { series.last?.t ?? Date() }

    private var baseArea: [DiskPoint] {
        guard let trigger else { return series }
        return series.filter { $0.t <= trigger.from } + [DiskPoint(t: trigger.from, used: trigger.fromUsed)]
    }

    private var segment: [DiskPoint] {
        guard let trigger else { return [] }
        return DiskSeries.triggerPoints(series: series, trigger: trigger)
    }

    private var domainX: ClosedRange<Date> {
        let first = series.first?.t ?? now
        let start = min(first, now.addingTimeInterval(-86400))
        let span = now.timeIntervalSince(start)
        return start...now.addingTimeInterval(span * 0.04)
    }

    /// The vertical range is never narrower than 6% of the capacity, so small noise stays small.
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
        VStack(spacing: 0) {
            ZStack {
                if series.count < 2 {
                    EmptyDiskHint()
                } else {
                    chart
                }
            }
            .frame(height: plotHeight)
            .uiTestFrame("chart.disk")
            HStack {
                Text("30 天前")
                Spacer()
                Text("今天")
            }
            .font(PanelFont.caption)
            .foregroundStyle(tok.textSecondary)
            .frame(height: ProblemChart.labelRowHeight, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chart.disk")
        .accessibilityLabel(Text("磁盘近 30 天已用空间趋势图"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let first = series.first, let last = series.last else { return "暂无数据" }
        return "从 \(Int(first.gb.rounded())) GB 到 \(Int(last.gb.rounded())) GB"
    }

    private var chart: some View {
        let yRange = domainY
        let tint = tok.lamp(trigger?.level ?? level)
        let hotLine = tok.chartHot(trigger?.level ?? level)
        let neutral = tok.chartNeutral
        return Chart {
            ForEach(baseArea) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("基线", yRange.lowerBound), yEnd: .value("已用", p.gb),
                         series: .value("区", "base"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tok.chartNeutralFill)
            }
            ForEach(series) { p in
                LineMark(x: .value("时间", p.t), y: .value("已用", p.gb), series: .value("线", "base"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            ForEach(segment) { p in
                AreaMark(x: .value("时间", p.t), yStart: .value("基线", yRange.lowerBound), yEnd: .value("已用", p.gb),
                         series: .value("区", "trigger"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint.opacity(0.15))
            }
            ForEach(segment) { p in
                LineMark(x: .value("时间", p.t), y: .value("已用", p.gb), series: .value("线", "trigger"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(hotLine)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let last = series.last {
                PointMark(x: .value("时间", last.t), y: .value("已用", last.gb))
                    .symbolSize(25)
                    .foregroundStyle(trigger == nil ? neutral : hotLine)
            }
            if let h = hovered {
                RuleMark(x: .value("时间", h.t))
                    .foregroundStyle(tok.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(h)
                    }
                PointMark(x: .value("时间", h.t), y: .value("已用", h.gb))
                    .symbolSize(30)
                    .foregroundStyle(tok.textPrimary)
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: yRange)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { area in
            area
                .background(tok.plotBackground)
                .clipShape(RoundedRectangle(cornerRadius: PanelSize.chartRadius, style: .continuous))
        }
        .chartOverlay { proxy in hoverLayer(proxy) }
    }

    @ViewBuilder
    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        if snapshot {
            Color.clear
        } else {
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
    }

    private func nearest(to date: Date) -> DiskPoint? {
        series.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
    }

    private func tooltip(_ p: DiskPoint) -> some View {
        VStack(spacing: 0) {
            Text(PanelFormat.dateTime(p.t)).font(PanelFont.caption).foregroundStyle(tok.textSecondary)
            Text(ByteText.gb(p.used)).font(PanelFont.footnote).monospacedDigit().foregroundStyle(tok.textPrimary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
    }
}

private struct EmptyDiskHint: View {
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack {
            DashedBaseline()
                .stroke(tok.textSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text("历史数据积累中")
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
        }
    }
}

// MARK: - Number transition

private struct NumericChange: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.numericText())
            .animation(reduceMotion ? nil : PanelMotion.quick, value: value)
    }
}

extension View {
    /// Rolls the digits when the text changes (docs/DESIGN.md 5.3). Direct replacement under Reduce Motion.
    func numericChange(_ value: String) -> some View {
        modifier(NumericChange(value: value))
    }
}
