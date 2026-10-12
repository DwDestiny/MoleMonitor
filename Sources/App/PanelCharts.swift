// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Series data of the sidebar (C2) and small helpers shared by the panel.
// Output: The number transition modifier. The sidebar charts are added in C2.
// Pos: Charts of the v2 panel. They are drawn by hand with Path (no Swift Charts), so a static ImageRenderer render matches the live view
//      and the readout layer can change without a redraw of the main chart (gate W07).

import Accessibility
import SwiftUI

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
    /// Rolls the digits when the text changes. Direct replacement under Reduce Motion.
    func numericChange(_ value: String) -> some View {
        modifier(NumericChange(value: value))
    }
}

// MARK: - Probe (test only)

#if UITEST
/// Counts how often the main chart is evaluated, and keeps the live readout model for the synthetic drag of gate W07.
@MainActor
final class ChartProbe {
    static let shared = ChartProbe()
    var mainDraws = 0
    weak var readout: ChartReadout?
    func reset() { mainDraws = 0 }
}
#endif

/// Called from the body of the main chart. It does nothing in the release build.
@MainActor
enum ChartProbeHook {
    static func bodyEvaluated() {
        #if UITEST
        ChartProbe.shared.mainDraws += 1
        #endif
    }
}

// MARK: - Geometry

enum ChartMetrics {
    static let width: CGFloat = 287
    static let height: CGFloat = 160
    /// The plot area. The rest below holds the time axis (10 pt).
    static let plotHeight: CGFloat = 142
    static let axisHeight: CGFloat = 18
}

private func chartPoint(_ p: ChartPoint, in data: ChartData, line: ChartLine?) -> CGPoint {
    let x = CGFloat(data.x(p.t)) * ChartMetrics.width
    let y = ChartMetrics.plotHeight - CGFloat(data.y(p.v, line: line)) * ChartMetrics.plotHeight
    return CGPoint(x: x, y: y)
}

// MARK: - Shapes

private struct ChartLineShape: Shape {
    let data: ChartData
    let line: ChartLine
    let style: ChartStyle
    /// True: close the path down to the baseline (area fill).
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for run in line.runs where !run.isEmpty {
            let points = run.map { chartPoint($0, in: data, line: line) }
            if points.count == 1 {
                if !closed { p.addEllipse(in: CGRect(x: points[0].x - 1.5, y: points[0].y - 1.5, width: 3, height: 3)) }
                continue
            }
            p.move(to: points[0])
            for i in 1..<points.count {
                if style == .step {
                    p.addLine(to: CGPoint(x: points[i].x, y: points[i - 1].y))
                }
                p.addLine(to: points[i])
            }
            if closed {
                p.addLine(to: CGPoint(x: points[points.count - 1].x, y: ChartMetrics.plotHeight))
                p.addLine(to: CGPoint(x: points[0].x, y: ChartMetrics.plotHeight))
                p.closeSubpath()
            }
        }
        return p
    }
}

private struct ChartBarsShape: Shape {
    let data: ChartData

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for bar in data.bars {
            let x0 = CGFloat(data.x(bar.start)) * ChartMetrics.width
            let x1 = CGFloat(data.x(bar.end)) * ChartMetrics.width
            let h = CGFloat(data.y(bar.bytes)) * ChartMetrics.plotHeight
            p.addRect(CGRect(x: x0 + 0.5, y: ChartMetrics.plotHeight - h, width: max(1, x1 - x0 - 1), height: h))
        }
        return p
    }
}

private struct ChartHorizontalShape: Shape {
    let y: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: ChartMetrics.width, y: y))
        return p
    }
}

// MARK: - Main chart

/// The main chart. It is Equatable and sits inside `.equatable()`, so a readout move or a hover elsewhere does not evaluate it again (gate W07).
struct ChartMain: View, Equatable {
    let data: ChartData
    let level: HealthLevel
    @Environment(\.tok) private var tok

    static func == (a: ChartMain, b: ChartMain) -> Bool {
        a.data == b.data && a.level == b.level
    }

    private var lineColor: Color {
        level == .yellow || level == .red ? tok.chartHot(level) : tok.chartLine
    }

    private func bandColor(_ kind: ChartBandKind) -> Color {
        switch kind {
        case .acPower: return tok.fillSelected
        case .sleep: return tok.chartGrid
        case .pressureWarning: return tok.tintWarning
        case .pressureCritical: return tok.tintDanger
        case .highlight: return level == .yellow ? tok.tintWarning : tok.tintDanger
        }
    }

    private func axisLabels() -> [String] {
        let zone = TimeZone.current
        let from = data.window.lowerBound
        let to = data.window.upperBound
        let mid = from.addingTimeInterval(to.timeIntervalSince(from) / 2)
        func text(_ d: Date) -> String {
            if data.range == .h2 || data.range == .h24 { return TextFormat.clock(d, timeZone: zone) }
            return TextFormat.dateTime(d, timeZone: zone).components(separatedBy: " ").first ?? ""
        }
        return [text(from), text(mid), text(to)]
    }

    private func topLabel() -> String? {
        guard let line = data.lines.first else { return nil }
        switch line.unit {
        case .percent: return String(format: "%.0f%%", data.domain.upperBound)
        case .gigabytes: return String(format: "%.0f GB", data.domain.upperBound)
        case .bytesPerSecond: return SidebarText.rate(data.domain.upperBound)
        case .thermal: return nil
        }
    }

    private func bottomLabel() -> String? {
        guard let line = data.lines.first else { return nil }
        switch line.unit {
        case .percent: return String(format: "%.0f%%", data.domain.lowerBound)
        case .gigabytes: return String(format: "%.0f GB", data.domain.lowerBound)
        case .bytesPerSecond: return "0"
        case .thermal: return nil
        }
    }

    var body: some View {
        let _ = ChartProbeHook.bodyEvaluated()
        let headWidth = CGFloat(data.emptyHead) * ChartMetrics.width
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tok.plotBackground)
                .frame(width: ChartMetrics.width, height: ChartMetrics.plotHeight)
            ForEach(0..<3, id: \.self) { i in
                ChartHorizontalShape(y: ChartMetrics.plotHeight * CGFloat(i) / 2)
                    .stroke(tok.chartGrid, lineWidth: 0.5)
            }
            ForEach(Array(data.bands.enumerated()), id: \.offset) { _, band in
                Rectangle().fill(bandColor(band.kind))
                    .frame(width: max(1, CGFloat(data.x(band.to) - data.x(band.from)) * ChartMetrics.width), height: ChartMetrics.plotHeight)
                    .offset(x: CGFloat(data.x(band.from)) * ChartMetrics.width)
            }
            if headWidth > 1 {
                Rectangle().fill(tok.chartFill).frame(width: headWidth, height: ChartMetrics.plotHeight)
                if data.isEmpty || headWidth > 90 {
                    Text("还没有数据")
                        .font(PanelType.rowNote)
                        .foregroundStyle(tok.textTertiary)
                        .frame(width: headWidth, height: ChartMetrics.plotHeight)
                }
            }
            ForEach(Array(data.thresholds.enumerated()), id: \.offset) { _, value in
                ChartHorizontalShape(y: ChartMetrics.plotHeight - CGFloat(data.y(value)) * ChartMetrics.plotHeight)
                    .stroke(tok.chartThreshold, style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            }
            ChartBarsShape(data: data).fill(lineColor.opacity(0.7))
            ForEach(Array(data.lines.enumerated()), id: \.offset) { _, line in
                if line.secondary {
                    ChartLineShape(data: data, line: line, style: .line, closed: false)
                        .stroke(tok.textTertiary, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                } else {
                    if data.style == .area {
                        ChartLineShape(data: data, line: line, style: .area, closed: true).fill(tok.chartFill)
                    }
                    ChartLineShape(data: data, line: line, style: data.style, closed: false)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            if let top = topLabel(), let bottom = bottomLabel(), data.isEmpty == false {
                Text(top).font(PanelType.axis).foregroundStyle(tok.textSecondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tok.labelPlate))
                    .offset(x: 3, y: 3)
                Text(bottom).font(PanelType.axis).foregroundStyle(tok.textSecondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tok.labelPlate))
                    .offset(x: 3, y: ChartMetrics.plotHeight - 17)
            }
            HStack(spacing: 0) {
                ForEach(Array(axisLabels().enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(PanelType.axis)
                        .foregroundStyle(tok.textTertiary)
                        .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : (index == 1 ? .center : .trailing))
                }
            }
            .frame(width: ChartMetrics.width, height: ChartMetrics.axisHeight)
            .offset(y: ChartMetrics.plotHeight + 2)
        }
        .frame(width: ChartMetrics.width, height: ChartMetrics.height, alignment: .topLeading)
    }
}

// MARK: - Readout

/// The state of the readout layer. It changes with the pointer. The main chart never reads it.
@MainActor
final class ChartReadout: ObservableObject {
    @Published private(set) var x: Double?
    @Published private(set) var y: Double?
    @Published private(set) var text: String?
    /// How many moves changed the readout. The synthetic drag of gate W07 counts it.
    private(set) var updates = 0
    private var snapped: Date?

    /// The pointer is at `fraction` (0 to 1) of the chart width. The readout snaps to the nearest data point.
    func move(to fraction: Double, in data: ChartData, timeZone: TimeZone) {
        let span = data.window.upperBound.timeIntervalSince(data.window.lowerBound)
        let t = data.window.lowerBound.addingTimeInterval(min(1, max(0, fraction)) * span)
        if !data.bars.isEmpty {
            guard let bar = data.bars.min(by: { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }) else { return clear() }
            if snapped == bar.start { return }
            snapped = bar.start
            x = data.x(bar.start.addingTimeInterval(bar.end.timeIntervalSince(bar.start) / 2))
            y = data.y(bar.bytes)
            text = data.readout(at: bar.start, timeZone: timeZone)
            updates += 1
            return
        }
        guard let point = data.nearest(to: t) else { return clear() }
        if snapped == point.t { return }
        snapped = point.t
        x = data.x(point.t)
        y = data.y(point.v, line: data.lines.first)
        text = data.readout(at: point.t, timeZone: timeZone)
        updates += 1
    }

    func clear() {
        snapped = nil
        if x != nil { x = nil }
        if y != nil { y = nil }
        if text != nil { text = nil }
    }
}

/// The vertical line, the dot and the reading. A separate view: only this layer changes during a drag.
struct ChartReadoutLayer: View {
    @ObservedObject var readout: ChartReadout
    @Environment(\.tok) private var tok

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let x = readout.x, let y = readout.y, let text = readout.text {
                let px = CGFloat(x) * ChartMetrics.width
                let py = ChartMetrics.plotHeight - CGFloat(y) * ChartMetrics.plotHeight
                Rectangle().fill(tok.textTertiary).frame(width: 0.5, height: ChartMetrics.plotHeight).offset(x: px)
                Circle().fill(tok.accent).frame(width: 6, height: 6).offset(x: px - 3, y: py - 3)
                Text(text)
                    .font(PanelType.readout)
                    .foregroundStyle(tok.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PanelTokens.surface(dark: tok.dark)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tok.separator, lineWidth: 0.5))
                    .fixedSize()
                    .frame(width: ChartMetrics.width, alignment: x < 0.5 ? .leading : .trailing)
                    .padding(.leading, x < 0.5 ? px + 6 : 0)
                    .padding(.trailing, x < 0.5 ? 0 : ChartMetrics.width - px + 6)
                    .offset(y: 4)
                    .accessibilityHidden(true)
                    .uiTestFrame("chart.readout")
            }
        }
        .frame(width: ChartMetrics.width, height: ChartMetrics.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Accessibility

/// The data series for VoiceOver (DESIGN_V2.md 10.10). At most 60 points.
struct ChartDescriptorProvider: AXChartDescriptorRepresentable {
    let data: ChartData
    let timeZone: TimeZone

    func makeChartDescriptor() -> AXChartDescriptor {
        let minutes = data.range.seconds / 60
        let xAxis = AXNumericDataAxisDescriptor(title: "时间", range: 0...minutes, gridlinePositions: []) { value in
            let ago = Int((minutes - value).rounded())
            return ago <= 0 ? "现在" : (ago < 120 ? "\(ago) 分钟前" : "\(ago / 60) 小时前")
        }
        let unit = data.lines.first?.unit ?? .percent
        let yAxis = AXNumericDataAxisDescriptor(title: data.item.label, range: data.domain, gridlinePositions: []) { value in
            SidebarText.valueText(value, unit: unit, label: nil)
        }
        var series = [AXDataSeriesDescriptor]()
        for line in data.lines where !line.secondary {
            let all = line.runs.flatMap { $0 }
            let sampled = ChartSampling.lttb(all, limit: 60)
            let points = sampled.map { p in
                AXDataPoint(x: p.t.timeIntervalSince(data.window.lowerBound) / 60, y: p.v)
            }
            series.append(AXDataSeriesDescriptor(name: line.name, isContinuous: true, dataPoints: points))
        }
        if series.isEmpty {
            let points = data.bars.map { AXDataPoint(x: $0.start.timeIntervalSince(data.window.lowerBound) / 60, y: $0.bytes) }
            series.append(AXDataSeriesDescriptor(name: "流量", isContinuous: false, dataPoints: points))
        }
        return AXChartDescriptor(title: data.item.label, summary: data.summary(timeZone: timeZone), xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.summary = data.summary(timeZone: timeZone)
    }
}

// MARK: - Interactive chart

/// The chart with the readout. The pointer or a drag moves the readout layer only.
struct ChartPanel: View {
    let data: ChartData
    let level: HealthLevel
    @StateObject private var readout = ChartReadout()

    private func handle(_ x: CGFloat) {
        readout.move(to: Double(x / ChartMetrics.width), in: data, timeZone: TimeZone.current)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ChartMain(data: data, level: level).equatable()
            ChartReadoutLayer(readout: readout)
        }
        .frame(width: ChartMetrics.width, height: ChartMetrics.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): handle(point.x)
            case .ended: readout.clear()
            }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in handle(value.location.x) }
            .onEnded { _ in readout.clear() })
        .onAppear {
            #if UITEST
            ChartProbe.shared.readout = readout
            #endif
        }
        .onChange(of: data) { _, _ in readout.clear() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(data.summary(timeZone: TimeZone.current)))
        .accessibilityChartDescriptor(ChartDescriptorProvider(data: data, timeZone: TimeZone.current))
        .accessibilityIdentifier("chart.main")
        .uiTestFrame("chart.main")
    }
}
