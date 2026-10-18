// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points, 5 minute rollup windows, disk points, current readings, app usage, interface rates and event records (docs/DESIGN_V2.md 6, 7.4).
// Output: SidebarRange, ChartData (one line or bars, anomaly bands, axis marks, live end point, readout text), SidebarStat and the
//         one-sentence summary, RankTable, RecordGroup, the 7 day record strip, the entrance offset and the footnotes of the sidebar.
// Pos: Pure content planning of the v3 sidebar (docs/DESIGN_V3.md 6, 6.1); the SwiftUI views only draw it. Foundation only. Owner P4.
//      One chart has one line. Only anomaly periods (event records, the disk trigger, an opened record) get bands. Interface strings
//      join parts with "，", never a middle dot. Missing, failed, stale and measured zero stay different: a missing value gives no point and
//      the text "—", never 0.

import Foundation

// MARK: - Ranges

enum SidebarRange: String, CaseIterable, Equatable {
    case h2, h24, d7, d30

    var label: String {
        switch self {
        case .h2: return "2 小时"
        case .h24: return "24 小时"
        case .d7: return "7 天"
        case .d30: return "30 天"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .h2: return 2 * 3600
        case .h24: return 24 * 3600
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }

    /// The ranges of the segmented control (DESIGN_V2.md 6.4).
    static func options(for item: SidebarItem) -> [SidebarRange] {
        switch item {
        case .disk: return [.h24, .d7, .d30]
        case .anomalyLog: return [.d7, .d30]
        default: return [.h2, .h24, .d7]
        }
    }

    static func defaultRange(for item: SidebarItem) -> SidebarRange {
        switch item {
        case .disk, .anomalyLog: return .d7
        default: return .h2
        }
    }

    /// The smallest range of `item` that holds a stretch starting at `start` (a click on an anomaly record).
    static func covering(start: Date, now: Date, item: SidebarItem) -> SidebarRange {
        let options = SidebarRange.options(for: item)
        let age = now.timeIntervalSince(start)
        return options.first(where: { $0.seconds >= age }) ?? options.last ?? .h2
    }
}

// MARK: - Chart data

struct ChartPoint: Equatable {
    var t: Date
    var v: Double
}

enum ChartStyle: Equatable { case line, area, step }

enum ChartUnit: Equatable { case percent, bytesPerSecond, gigabytes, thermal }

struct ChartLine: Equatable {
    var name: String
    var runs: [[ChartPoint]]
    var unit: ChartUnit
    /// Own value scale. Nil uses the chart domain.
    var scale: ClosedRange<Double>?

    var pointCount: Int { runs.reduce(0) { $0 + $1.count } }
}

struct ChartBar: Equatable {
    var start: Date
    var end: Date
    var bytes: Double
}

/// Kinds of time band. Only anomaly periods are banded (docs/DESIGN_V3.md 6): a yellow or red episode, and the record the user opened.
enum ChartBandKind: String, Equatable {
    case warning, critical, highlight
}

/// A number beside the plot, outside on the right (docs/DESIGN_V3.md 6): the zero line, the thresholds, or the scale ends.
struct ChartAxisMark: Equatable {
    /// Height in the plot, 0 at the bottom, 1 at the top.
    var y: Double
    var text: String
    /// True for a threshold: the plot draws a dashed line at it.
    var threshold: Bool
}

struct ChartTimeBand: Equatable {
    var from: Date
    var to: Date
    var kind: ChartBandKind
}

struct ChartData: Equatable {
    var item: SidebarItem
    var range: SidebarRange
    var window: ClosedRange<Date>
    var domain: ClosedRange<Double>
    var style: ChartStyle
    var lines: [ChartLine]
    var bars: [ChartBar]
    var bands: [ChartTimeBand]
    var thresholds: [Double]
    /// Earliest time with data in the window. Nil when the window has no data.
    var firstData: Date?
    var now: Date

    var isEmpty: Bool { lines.allSatisfy { $0.pointCount == 0 } && bars.isEmpty }

    /// The newest point of the line when it is at most 3 minutes old: the live dot sits on it (docs/DESIGN_V3.md 6).
    /// Nil for bar charts, for old data and for ranges longer than 24 hours.
    var liveEnd: ChartPoint? {
        guard bars.isEmpty, range == .h2 || range == .h24, let line = lines.first,
              let last = line.runs.last(where: { !$0.isEmpty })?.last else { return nil }
        let limit: TimeInterval = range == .h2 ? 180 : 660
        return now.timeIntervalSince(last.t) <= limit ? last : nil
    }

    /// Numbers beside the plot. Percent: the zero line and the thresholds (the top when there is no threshold).
    /// Thermal: the four level words. Other units: the bottom and the top of the scale.
    var axisMarks: [ChartAxisMark] {
        let unit = lines.first?.unit ?? .bytesPerSecond
        func text(_ v: Double) -> String {
            switch unit {
            case .percent: return String(format: "%.0f", v)
            case .gigabytes: return String(format: "%.0f GB", v)
            case .bytesPerSecond: return bars.isEmpty ? SidebarText.rate(v) : SidebarText.bytes(v)
            case .thermal: return SidebarText.valueText(v, unit: .thermal, label: nil)
            }
        }
        if unit == .thermal {
            return (0...3).map { ChartAxisMark(y: y(Double($0)), text: text(Double($0)), threshold: false) }
        }
        var out = [ChartAxisMark(y: 0, text: (unit == .bytesPerSecond) ? "0" : text(domain.lowerBound), threshold: false)]
        if unit == .percent && !thresholds.isEmpty {
            out += thresholds.map { ChartAxisMark(y: y($0), text: text($0), threshold: true) }
        } else {
            out.append(ChartAxisMark(y: 1, text: text(domain.upperBound), threshold: false))
        }
        return out
    }

    /// "已记录 N 小时" beside the range control when the history is shorter than the window. Nil when it covers the window.
    var recordedText: String? {
        guard let firstData else { return nil }
        let covered = now.timeIntervalSince(firstData)
        guard covered < range.seconds * 0.95 else { return nil }
        if covered < 3600 { return "已记录不到 1 小时" }
        if covered < 48 * 3600 { return "已记录 \(Int(covered / 3600)) 小时" }
        return "已记录 \(Int(covered / 86400)) 天"
    }

    /// Fraction of the window width (0 to 1) before the first data. The chart marks it "还没有数据".
    var emptyHead: Double {
        guard let firstData else { return 1 }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return 0 }
        return min(1, max(0, firstData.timeIntervalSince(window.lowerBound) / span))
    }

    /// X position (0 to 1) of a time in the window.
    func x(_ t: Date) -> Double {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return 0 }
        return min(1, max(0, t.timeIntervalSince(window.lowerBound) / span))
    }

    /// Y position (0 at the bottom, 1 at the top) of a value on the scale of a line.
    func y(_ v: Double, line: ChartLine? = nil) -> Double {
        let d = line?.scale ?? domain
        let span = d.upperBound - d.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (v - d.lowerBound) / span))
    }

    /// The point of the first line nearest to a time (the readout snaps to data points). Nil without points.
    func nearest(to t: Date) -> ChartPoint? {
        guard let line = lines.first(where: { $0.pointCount > 0 }) else { return nil }
        var best: ChartPoint?
        var bestDistance = Double.infinity
        for run in line.runs {
            for p in run {
                let d = abs(p.t.timeIntervalSince(t))
                if d < bestDistance { bestDistance = d; best = p }
            }
        }
        return best
    }

    /// The value of a line at the time of a point: the nearest point of that line within 3 sample steps. Nil in a gap.
    func value(of line: ChartLine, near t: Date, tolerance: TimeInterval) -> Double? {
        var best: Double?
        var bestDistance = Double.infinity
        for run in line.runs {
            for p in run {
                let d = abs(p.t.timeIntervalSince(t))
                if d < bestDistance { bestDistance = d; best = p.v }
            }
        }
        return bestDistance <= tolerance ? best : nil
    }

    /// Readout of the point nearest to `t`: "14:32，87%".
    func readout(at t: Date, timeZone: TimeZone) -> String? {
        if !bars.isEmpty {
            guard let bar = bars.min(by: { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }) else { return nil }
            return stamp(bar.start, timeZone) + "，" + SidebarText.bytes(bar.bytes)
        }
        guard let point = nearest(to: t) else { return nil }
        var parts = [String]()
        let tolerance = max(60, range.seconds / 120)
        for line in lines {
            guard let v = value(of: line, near: point.t, tolerance: tolerance) else { continue }
            parts.append(SidebarText.valueText(v, unit: line.unit, label: lines.count > 1 ? line.name : nil))
        }
        guard !parts.isEmpty else { return nil }
        return stamp(point.t, timeZone) + "，" + parts.joined(separator: " ")
    }

    private func stamp(_ t: Date, _ timeZone: TimeZone) -> String {
        range == .h2 || range == .h24 ? TextFormat.clock(t, timeZone: timeZone) : TextFormat.dateTime(t, timeZone: timeZone)
    }

    /// One sentence for VoiceOver (the AXChartDescriptor summary).
    func summary(timeZone: TimeZone) -> String {
        if isEmpty { return item.label + "图表，" + range.label + "内还没有数据" }
        var values = [Double]()
        for run in lines.first?.runs ?? [] { values.append(contentsOf: run.map { $0.v }) }
        guard let lo = values.min(), let hi = values.max(), let line = lines.first else {
            return item.label + "图表，" + range.label
        }
        return item.label + "图表，" + range.label + "，最低 " + SidebarText.valueText(lo, unit: line.unit, label: nil)
            + "，最高 " + SidebarText.valueText(hi, unit: line.unit, label: nil)
    }
}

// MARK: - Text helpers

enum SidebarText {
    /// "1.1 MB/s", "96 KB/s", "0 KB/s". Decimal units. Bytes per second in.
    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1e9 { return String(format: "%.1f GB/s", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        return String(format: "%.0f KB/s", v / 1e3)
    }

    /// "1.2 GB", "340 MB" for a byte total.
    static func bytes(_ value: Double) -> String {
        TextFormat.bytes(Int64(max(0, value)))
    }

    static func valueText(_ v: Double, unit: ChartUnit, label: String?) -> String {
        switch unit {
        case .percent:
            let text = TextFormat.percent(v)
            return label.map { $0 + " " + text } ?? text
        case .bytesPerSecond:
            let arrow = label == "下行" ? "\u{2193}" : (label == "上行" ? "\u{2191}" : "")
            return arrow + rate(v)
        case .gigabytes:
            return String(format: "%.0f GB", v)
        case .thermal:
            let rank = Int(v.rounded())
            let levels: [ThermalLevel] = [.nominal, .fair, .serious, .critical]
            let word = levels.indices.contains(rank) ? levels[rank].label : "—"
            return label.map { $0 + " " + word } ?? word
        }
    }
}

// MARK: - LTTB

enum ChartSampling {
    /// Largest-Triangle-Three-Buckets: keeps `limit` points that keep the shape (DESIGN_V2.md 6.2). The first and last point stay.
    static func lttb(_ points: [ChartPoint], limit: Int) -> [ChartPoint] {
        let n = points.count
        guard limit >= 3, n > limit else { return points }
        var out = [ChartPoint]()
        out.reserveCapacity(limit)
        out.append(points[0])
        let every = Double(n - 2) / Double(limit - 2)
        var a = 0
        for i in 0..<(limit - 2) {
            let nextStart = Int((Double(i + 1) * every).rounded(.down)) + 1
            let nextEnd = min(n, Int((Double(i + 2) * every).rounded(.down)) + 1)
            var avgX = 0.0, avgY = 0.0
            let count = max(1, nextEnd - nextStart)
            for j in nextStart..<max(nextStart + 1, nextEnd) where j < n {
                avgX += points[j].t.timeIntervalSince1970
                avgY += points[j].v
            }
            avgX /= Double(count)
            avgY /= Double(count)
            let start = Int((Double(i) * every).rounded(.down)) + 1
            let end = min(n - 1, Int((Double(i + 1) * every).rounded(.down)) + 1)
            let ax = points[a].t.timeIntervalSince1970, ay = points[a].v
            var bestArea = -1.0
            var bestIndex = start
            if start < end {
                for j in start..<end {
                    let area = abs((ax - avgX) * (points[j].v - ay) - (ax - points[j].t.timeIntervalSince1970) * (avgY - ay))
                    if area > bestArea { bestArea = area; bestIndex = j }
                }
            }
            out.append(points[bestIndex])
            a = bestIndex
        }
        out.append(points[n - 1])
        return out
    }

    /// Cuts a time ordered list of optional points into runs. A missing value or a gap longer than `gap` ends a run.
    static func runs(_ samples: [(t: Date, v: Double?)], gap: TimeInterval, limit: Int) -> [[ChartPoint]] {
        var out = [[ChartPoint]]()
        var run = [ChartPoint]()
        var last: Date?
        func flush() {
            if !run.isEmpty { out.append(lttb(run, limit: limit)) }
            run = []
        }
        for s in samples {
            if let last, s.t.timeIntervalSince(last) > gap { flush() }
            last = s.t
            if let v = s.v, v.isFinite {
                run.append(ChartPoint(t: s.t, v: v))
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

// MARK: - Inputs


/// One app with the bytes it wrote to disk in the last 5 minutes (DESIGN_V2.md 6.5). The engine feeds it from `AppDiskWriteTracker`.
struct DiskWriterRow: Equatable {
    var key: String
    var name: String
    var bundleID: String?
    var bytes: Int64
    var isSystem: Bool
}

struct SidebarInput {
    var item: SidebarItem
    var range: SidebarRange
    var trend: TrendSeries
    var rollups: [RollupWindow]
    var diskSeries: [DiskPoint]
    var diskTrigger: DiskTrigger?
    var sleeps: [SleepRecord]
    var current: CurrentReadings
    var verdicts: [ItemVerdict]
    var status: StatusFile?
    var now: Date
    var timeZone: TimeZone = TimeZone.current
}

// MARK: - Chart builder

enum SidebarChart {
    static let fineGap: TimeInterval = 120
    static let rollupGap: TimeInterval = 660

    /// `events` are the anomaly records. Their yellow and red periods become the bands of every item except disk, which bands its
    /// growth trigger (docs/DESIGN_V3.md 6: only anomaly periods take the level color).
    static func make(_ input: SidebarInput, events: [EventRecord] = []) -> ChartData {
        let end = input.now
        let start = end.addingTimeInterval(-input.range.seconds)
        let window = start...end
        var data = ChartData(item: input.item, range: input.range, window: window, domain: 0...100, style: .line, lines: [],
                             bars: [], bands: [], thresholds: [], firstData: nil, now: end)
        switch input.item {
        case .cpu: cpu(input, &data)
        case .memory: memory(input, &data)
        case .disk: disk(input, &data)
        case .network: network(input, &data)
        case .battery: battery(input, &data)
        case .thermal: thermal(input, &data)
        case .anomalyLog: break
        }
        if input.item != .disk, let health = input.item.healthItem {
            data.bands += eventBands(events.filter { $0.item == health }, window: window)
        }
        var first: Date?
        for line in data.lines { for run in line.runs { if let t = run.first?.t, first == nil || t < first! { first = t } } }
        for bar in data.bars where first == nil || bar.start < first! { first = bar.start }
        data.firstData = first
        return data
    }

    /// Points of the 2 hour range from the trend, newest segments last.
    private static func trendPoints(_ input: SidebarInput) -> [TrendPoint] {
        let start = input.now.addingTimeInterval(-input.range.seconds)
        return input.trend.segments.flatMap { $0 }.filter { $0.t >= start && $0.t <= input.now }.sorted { $0.t < $1.t }
    }

    private static func windows(_ input: SidebarInput) -> [RollupWindow] {
        let start = input.now.addingTimeInterval(-input.range.seconds)
        return input.rollups.filter { $0.end >= start && $0.end <= input.now }.sorted { $0.end < $1.end }
    }

    private static func line(_ name: String, _ samples: [(t: Date, v: Double?)], unit: ChartUnit, fine: Bool) -> ChartLine {
        let gap = fine ? fineGap : rollupGap
        let limit = fine ? 240 : 360
        return ChartLine(name: name, runs: ChartSampling.runs(samples, gap: gap, limit: limit), unit: unit, scale: nil)
    }

    private static func cpu(_ input: SidebarInput, _ d: inout ChartData) {
        d.thresholds = [70, 90]
        if input.range == .h2 {
            let s = trendPoints(input).map { (t: $0.t, v: $0.cpu) }
            d.lines = [line("CPU", s, unit: .percent, fine: true)]
        } else {
            let s = windows(input).map { (t: $0.end, v: $0.cpuMean) }
            d.lines = [line("CPU", s, unit: .percent, fine: false)]
        }
    }

    /// Memory pressure only. Swap is not a second series: it goes into the summary sentence (docs/DESIGN_V3.md 6).
    private static func memory(_ input: SidebarInput, _ d: inout ChartData) {
        if input.range == .h2 {
            let pts = trendPoints(input)
            d.lines = [line("压力", pts.map { (t: $0.t, v: $0.pressurePercent.map { Double($0) }) }, unit: .percent, fine: true)]
        } else {
            let ws = windows(input)
            d.lines = [line("压力", ws.map { (t: $0.end, v: $0.pressureMean) }, unit: .percent, fine: false)]
        }
    }

    /// The yellow and red periods of the records, clipped to the window, merged per kind. An ongoing record runs to the window end.
    static func eventBands(_ events: [EventRecord], window: ClosedRange<Date>) -> [ChartTimeBand] {
        var out = [ChartTimeBand]()
        for kind in [ChartBandKind.warning, .critical] {
            let level: HealthLevel = kind == .warning ? .yellow : .red
            let spans = events.filter { $0.peak == level }
                .map { (max($0.start, window.lowerBound), min($0.end ?? window.upperBound, window.upperBound)) }
                .filter { $0.0 < $0.1 }
                .sorted { $0.0 < $1.0 }
            var merged = [(Date, Date)]()
            for span in spans {
                if let last = merged.last, span.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, span.1)
                } else {
                    merged.append(span)
                }
            }
            out += merged.map { ChartTimeBand(from: $0.0, to: $0.1, kind: kind) }
        }
        return out
    }

    private static func disk(_ input: SidebarInput, _ d: inout ChartData) {
        d.style = .area
        let start = input.now.addingTimeInterval(-input.range.seconds)
        let pts = input.diskSeries.filter { $0.t >= start && $0.t <= input.now }.sorted { $0.t < $1.t }
        let gap = 2 * DiskSeries.bucketSeconds
        d.lines = [ChartLine(name: "已用", runs: ChartSampling.runs(pts.map { (t: $0.t, v: Optional($0.gb)) }, gap: gap, limit: 360),
                             unit: .gigabytes, scale: nil)]
        let values = pts.map { $0.gb }
        let low = values.min() ?? 0
        let high = values.max() ?? 10
        let span = max(10, (high - low) * 1.2)
        let mid = (high + low) / 2
        d.domain = (mid - span / 2)...(mid + span / 2)
        if let trigger = input.diskTrigger, trigger.level == .red || trigger.level == .yellow {
            d.bands = [ChartTimeBand(from: max(start, trigger.from), to: input.now, kind: trigger.level == .red ? .critical : .warning)]
        }
    }

    private static func network(_ input: SidebarInput, _ d: inout ChartData) {
        if input.range == .h2 {
            let pts = trendPoints(input)
            // One line: download plus upload. A point with a missing side is missing, not a half sum.
            let total = pts.map { p -> (t: Date, v: Double?) in
                guard let rx = p.rx, let tx = p.tx else { return (t: p.t, v: nil) }
                return (t: p.t, v: rx + tx)
            }
            let top = max(1_000_000, total.compactMap { $0.v }.max() ?? 0)
            d.domain = 0...(top * 1.1)
            d.lines = [line("流量", total, unit: .bytesPerSecond, fine: true)]
            return
        }
        let bucket: TimeInterval = input.range == .h24 ? 3600 : 86400
        let start = input.now.addingTimeInterval(-input.range.seconds)
        var sums = [Int: Double]()
        for w in windows(input) {
            guard let rx = w.rxKBps, let tx = w.txKBps else { continue }
            let index = Int(w.end.timeIntervalSince(start) / bucket)
            sums[index, default: 0] += (rx + tx) * 1000 * RollupStore.windowSeconds
        }
        var bars = [ChartBar]()
        for index in sums.keys.sorted() {
            let from = start.addingTimeInterval(Double(index) * bucket)
            bars.append(ChartBar(start: from, end: from.addingTimeInterval(bucket), bytes: sums[index] ?? 0))
        }
        d.bars = bars
        let top = bars.map { $0.bytes }.max() ?? 1
        d.domain = 0...max(1, top * 1.1)
    }

    /// Charge only. Power source and sleep periods are not banded: they are not anomalies (docs/DESIGN_V3.md 6).
    private static func battery(_ input: SidebarInput, _ d: inout ChartData) {
        if input.range == .h2 {
            let pts = trendPoints(input)
            d.lines = [line("电量", pts.map { (t: $0.t, v: $0.battery) }, unit: .percent, fine: true)]
        } else {
            let ws = windows(input)
            d.lines = [line("电量", ws.map { (t: $0.end, v: $0.batteryPercent) }, unit: .percent, fine: false)]
        }
    }

    private static func thermal(_ input: SidebarInput, _ d: inout ChartData) {
        d.style = .step
        d.domain = 0...3
        if input.range == .h2 {
            let pts = trendPoints(input)
            d.lines = [line("热状态", pts.map { (t: $0.t, v: $0.thermal.map { Double($0.rank) }) }, unit: .thermal, fine: true)]
        } else {
            let ws = windows(input)
            d.lines = [line("热状态", ws.map { (t: $0.end, v: $0.thermal.map { Double($0.rank) }) }, unit: .thermal, fine: false)]
        }
    }
}

// MARK: - Stats

struct SidebarStat: Equatable {
    var label: String
    var value: String
}

enum SidebarStats {
    private static let dash = "\u{2014}"

    static func make(_ input: SidebarInput, events: [EventRecord] = [], recordDays: Int = 7) -> [SidebarStat] {
        let c = input.current
        switch input.item {
        case .cpu:
            let (mean, peak) = cpuMeanPeak(input)
            return [SidebarStat(label: "当前", value: TextFormat.percent(c.cpuPercent)),
                    SidebarStat(label: "均值", value: TextFormat.percent(mean)),
                    SidebarStat(label: "峰值", value: TextFormat.percent(peak))]
        case .memory:
            return [SidebarStat(label: "压力", value: c.memoryPressurePercent.map { String($0) + "%" } ?? dash),
                    SidebarStat(label: "swap", value: TextFormat.bytes(c.swapUsed)),
                    SidebarStat(label: "30 分钟变化", value: TextFormat.signedBytes(c.swapGrowth30m))]
        case .disk:
            let growth = input.status?.items.disk.growth ?? [:]
            func g(_ key: String) -> String { growth[key]?.bytes.map { TextFormat.signedDiskGB($0) } ?? dash }
            return [SidebarStat(label: "1 天增长", value: g("1d")), SidebarStat(label: "5 天增长", value: g("5d")),
                    SidebarStat(label: "30 天增长", value: g("30d"))]
        case .network:
            return networkStats(input)
        case .battery:
            let source: String
            switch c.powerSource {
            case .ac?: source = "接电源"
            case .battery?: source = "电池"
            case nil: source = dash
            }
            var drop = dash
            if let s = c.lastSleep { drop = String(format: "%.0f%%", max(0, s.batteryBefore - s.batteryAfter)) }
            return [SidebarStat(label: "电量", value: TextFormat.percent(c.batteryPercent)),
                    SidebarStat(label: "电源", value: source),
                    SidebarStat(label: "上次睡眠掉电", value: drop)]
        case .thermal:
            let verdict = input.verdicts.first { $0.item == .thermal }
            var lasting = dash
            if let since = verdict?.since, verdict?.level == .yellow || verdict?.level == .red {
                lasting = TextFormat.duration(since: since, now: input.now)
            }
            let temperature = c.smcCPUTemperature.map { String(format: "%.0f \u{00B0}C", $0) } ?? dash
            return [SidebarStat(label: "热状态", value: c.thermal?.label ?? dash), SidebarStat(label: "已持续", value: lasting),
                    SidebarStat(label: "SMC 温度（参考）", value: temperature)]
        case .anomalyLog:
            return recordStats(events, now: input.now, days: recordDays)
        }
    }

    private static func cpuMeanPeak(_ input: SidebarInput) -> (Double?, Double?) {
        let start = input.now.addingTimeInterval(-input.range.seconds)
        if input.range == .h2 {
            let values = input.trend.segments.flatMap { $0 }.filter { $0.t >= start && $0.t <= input.now }.compactMap { $0.cpu }
            guard !values.isEmpty else { return (nil, nil) }
            return (values.reduce(0, +) / Double(values.count), values.max())
        }
        let ws = input.rollups.filter { $0.end >= start && $0.end <= input.now }
        let means = ws.compactMap { $0.cpuMean }
        let peaks = ws.compactMap { $0.cpuPeak }
        guard !means.isEmpty else { return (nil, nil) }
        return (means.reduce(0, +) / Double(means.count), peaks.max())
    }

    /// Traffic of today, yesterday and the last 30 days from the rollup windows (local days).
    private static func networkStats(_ input: SidebarInput) -> [SidebarStat] {
        let shift = Double(input.timeZone.secondsFromGMT(for: input.now))
        let nowLocal = input.now.timeIntervalSince1970 + shift
        let today0 = (nowLocal / 86400).rounded(.down) * 86400
        var today = 0.0, yesterday = 0.0, month = 0.0
        var haveToday = false, haveYesterday = false
        var earliest: Date?
        for w in input.rollups {
            guard let rx = w.rxKBps, let tx = w.txKBps else { continue }
            let bytes = (rx + tx) * 1000 * RollupStore.windowSeconds
            let local = w.end.timeIntervalSince1970 + shift
            if w.end > input.now || w.end < input.now.addingTimeInterval(-30 * 86400) { continue }
            month += bytes
            if earliest == nil || w.end < earliest! { earliest = w.end }
            if local >= today0 { today += bytes; haveToday = true } else if local >= today0 - 86400 { yesterday += bytes; haveYesterday = true }
        }
        var monthText = earliest == nil ? dash : SidebarText.bytes(month)
        if let earliest, input.now.timeIntervalSince(earliest) < 29 * 86400 { monthText = "至少 " + monthText }
        return [SidebarStat(label: "今天", value: haveToday ? SidebarText.bytes(today) : dash),
                SidebarStat(label: "昨天", value: haveYesterday ? SidebarText.bytes(yesterday) : dash),
                SidebarStat(label: "近 30 天", value: monthText)]
    }

    private static func recordStats(_ events: [EventRecord], now: Date, days: Int) -> [SidebarStat] {
        let inRange = events.filter { $0.start >= now.addingTimeInterval(-Double(days) * 86400) }
        guard !inRange.isEmpty else {
            return [SidebarStat(label: "记录条数", value: "0"), SidebarStat(label: "最长一次", value: dash),
                    SidebarStat(label: "最常见分项", value: dash)]
        }
        let longest = inRange.map { ($0.end ?? now).timeIntervalSince($0.start) }.max() ?? 0
        var counts = [HealthItem: Int]()
        for e in inRange { counts[e.item, default: 0] += 1 }
        let common = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key.fixedPriority > b.key.fixedPriority }
        let name = common.map { SidebarItem($0.key).label } ?? dash
        return [SidebarStat(label: "记录条数", value: String(inRange.count)),
                SidebarStat(label: "最长一次", value: TextFormat.span(seconds: longest)), SidebarStat(label: "最常见分项", value: name)]
    }
}

// MARK: - Ranking

struct RankRow: Equatable, Identifiable {
    var id: String
    var name: String
    var bundleID: String?
    var isSystem: Bool
    /// Value text, right aligned.
    var value: String
    /// Bar length, 0 to 1 of the largest row.
    var fraction: Double
    /// Spoken detail that does not fit the row.
    var detail: String?
    /// True when the value is a label (a sleep blocker kind), not a measured number: it is drawn small and in secondary color.
    var quietValue: Bool = false
}

struct RankTable: Equatable {
    var title: String
    var rows: [RankRow]
    /// Text for an empty list. Nil when the list has rows.
    var emptyText: String?
    /// True when the rows are interface rows or assertion rows (no app icon).
    var plain: Bool = false
}

enum SidebarRanking {
    static func make(_ item: SidebarItem, apps: [AppUsage], interfaces: [InterfaceRate]?, blockers: [SleepBlocker]?,
                     diskWriters: [DiskWriterRow]? = nil) -> RankTable? {
        switch item {
        case .cpu: return cpuTable(apps, title: "CPU 占用前 5")
        case .thermal: return cpuTable(apps, title: "CPU 占用前 5（可能的热源）")
        case .memory: return memoryTable(apps)
        case .disk: return diskTable(diskWriters)
        case .network: return networkTable(interfaces)
        case .battery: return batteryTable(blockers)
        case .anomalyLog: return nil
        }
    }

    private static func row(_ app: AppUsage, value: String, fraction: Double) -> RankRow {
        RankRow(id: app.key, name: app.name, bundleID: app.bundleID, isSystem: app.isSystem, value: value, fraction: fraction, detail: nil)
    }

    private static func cpuTable(_ apps: [AppUsage], title: String) -> RankTable {
        let top = AppRanking.top(apps, by: .cpu, count: 5).filter { ($0.cpuPercent ?? 0) >= AppRanking.minimumCPU }
        let most = max(100, top.compactMap { $0.cpuPercent }.max() ?? 100)
        let rows = top.map { row($0, value: TextFormat.percent($0.cpuPercent), fraction: min(1, ($0.cpuPercent ?? 0) / most)) }
        return RankTable(title: title, rows: rows, emptyText: rows.isEmpty ? "没有 App 在占用 CPU" : nil)
    }

    private static func memoryTable(_ apps: [AppUsage]) -> RankTable {
        let top = AppRanking.top(apps, by: .memory, count: 5).filter { ($0.memoryBytes ?? 0) >= AppRanking.minimumMemory }
        let most = Double(top.compactMap { $0.memoryBytes }.max() ?? 1)
        let rows = top.map { row($0, value: TextFormat.bytes($0.memoryBytes), fraction: Double($0.memoryBytes ?? 0) / most) }
        return RankTable(title: "内存占用前 5", rows: rows, emptyText: rows.isEmpty ? "没有读到 App 内存" : nil)
    }

    private static func diskTable(_ writers: [DiskWriterRow]?) -> RankTable {
        let title = "磁盘写入前 5（近 5 分钟）"
        guard let writers else { return RankTable(title: title, rows: [], emptyText: "\u{2014} 还没有写入数据") }
        let sorted = writers.filter { $0.bytes > 0 }.sorted { a, b in
            a.bytes != b.bytes ? a.bytes > b.bytes : (a.name != b.name ? a.name < b.name : a.key < b.key)
        }
        let top = Array(sorted.prefix(5))
        let most = Double(top.first?.bytes ?? 1)
        let rows = top.map { w in
            RankRow(id: w.key, name: w.name, bundleID: w.bundleID, isSystem: w.isSystem, value: TextFormat.bytes(w.bytes),
                    fraction: Double(w.bytes) / most, detail: nil)
        }
        return RankTable(title: title, rows: rows, emptyText: rows.isEmpty ? "近 5 分钟没有明显写入" : nil)
    }

    private static func networkTable(_ interfaces: [InterfaceRate]?) -> RankTable {
        let title = "网卡（按当前速率）"
        guard let interfaces else { return RankTable(title: title, rows: [], emptyText: "\u{2014} 没有读到网卡数据", plain: true) }
        let physical = interfaces.filter { NetworkFilter.isPhysical($0.name) }
        let sorted = physical.sorted { a, b in
            let x = (a.downBytesPerSec ?? 0) + (a.upBytesPerSec ?? 0), y = (b.downBytesPerSec ?? 0) + (b.upBytesPerSec ?? 0)
            return x != y ? x > y : a.name < b.name
        }
        let most = max(1, (sorted.first.map { ($0.downBytesPerSec ?? 0) + ($0.upBytesPerSec ?? 0) }) ?? 1)
        let rows = sorted.prefix(5).map { i -> RankRow in
            let total = (i.downBytesPerSec ?? 0) + (i.upBytesPerSec ?? 0)
            var value = "\u{2014}"
            if let rx = i.downBytesPerSec, let tx = i.upBytesPerSec { value = "\u{2193}" + SidebarText.rate(rx) + " \u{2191}" + SidebarText.rate(tx) }
            let detail: String? = "开机以来 下行 " + TextFormat.bytes(i.totalDown) + "，上行 " + TextFormat.bytes(i.totalUp)
            return RankRow(id: i.name, name: i.displayName, bundleID: nil, isSystem: false, value: value,
                           fraction: min(1, total / most), detail: detail)
        }
        return RankTable(title: title, rows: Array(rows), emptyText: rows.isEmpty ? "\u{2014} 没有读到物理网卡" : nil, plain: true)
    }

    private static func batteryTable(_ blockers: [SleepBlocker]?) -> RankTable {
        let title = "阻止睡眠的 App"
        guard let blockers else { return RankTable(title: title, rows: [], emptyText: "\u{2014} 没有读到睡眠断言", plain: true) }
        let rows = blockers.prefix(5).map { b in
            RankRow(id: b.name, name: b.name, bundleID: nil, isSystem: false, value: b.kindText, fraction: 0, detail: nil, quietValue: true)
        }
        return RankTable(title: title, rows: Array(rows), emptyText: rows.isEmpty ? "没有 App 阻止睡眠" : nil)
    }
}

// MARK: - Footnotes

enum SidebarFootnote {
    static func lines(_ item: SidebarItem, current: CurrentReadings) -> [String] {
        switch item {
        case .cpu:
            return ["单个 App 以单核满载为 100%，多核可超过 100%。"]
        case .memory:
            return ["压力百分比是近似读数，颜色以系统压力档位为准。", "已用 = App 内存 + 联动内存 + 压缩内存，与活动监视器口径相近。"]
        case .disk:
            var out = [String]()
            let cap = CapacityFormat.disk(current)
            if cap.isMissing {
                out.append("磁盘容量暂时读不到。")
            } else if let purge = cap.purgeable {
                out.append("可用含 " + purge + " 可清除空间。系统需要时会自动释放它。")
            }
            out.append("写入量不等于磁盘增长。删除和覆盖也算写入。")
            return out
        case .network:
            return ["macOS 不开放每 App 网络数据，所以这里按网卡分列。只计物理网卡，不重复计入 VPN。"]
        case .battery:
            return ["这不是耗电排行。macOS 不提供可靠的每应用耗电数据。"]
        case .thermal:
            return ["SMC 温度只作参考，等级以系统热状态为准。"]
        case .anomalyLog:
            return []
        }
    }
}

// MARK: - Anomaly records

struct RecordRow: Equatable, Identifiable {
    var id: String
    var item: HealthItem
    var level: HealthLevel
    var title: String
    var evidence: String
    /// "10:52–14:04", or "10:52 起，进行中" for an ongoing record.
    var span: String
    /// "3 小时 12 分", with "约" in front when the end is an estimate.
    var duration: String
    var ongoing: Bool
    var start: Date
    var end: Date?
}

struct RecordGroup: Equatable, Identifiable {
    var title: String
    var rows: [RecordRow]
    var id: String { title }
}

enum SidebarRecords {
    private static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    static func dayTitle(_ day: Int64, today: Int64) -> String {
        if day == today { return "今天" }
        if day == today - 1 { return "昨天" }
        let c = UTCTime.civil(fromDayIndex: day)
        let weekday = weekdays[Int(((day + 3) % 7 + 7) % 7)]
        return "\(c.month)月\(c.day)日 " + weekday
    }

    private static func dayIndex(_ date: Date, _ tz: TimeZone) -> Int64 {
        let local = date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))
        return Int64((local / 86400).rounded(.down))
    }

    static func groups(_ events: [EventRecord], days: Int, now: Date, timeZone: TimeZone) -> [RecordGroup] {
        let today = dayIndex(now, timeZone)
        let from = now.addingTimeInterval(-Double(days) * 86400)
        let list = events.filter { ($0.end ?? now) >= from }.sorted { $0.start > $1.start }
        var order = [Int64]()
        var byDay = [Int64: [RecordRow]]()
        for e in list {
            let day = dayIndex(e.start, timeZone)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row(e, now: now, tz: timeZone))
        }
        return order.map { RecordGroup(title: dayTitle($0, today: today), rows: byDay[$0] ?? []) }
    }

    static func row(_ e: EventRecord, now: Date, tz: TimeZone) -> RecordRow {
        let ongoing = e.end == nil
        let startText = TextFormat.clock(e.start, timeZone: tz)

        var duration = TextFormat.span(seconds: (e.end ?? now).timeIntervalSince(e.start))
        if e.endEstimated && !ongoing { duration = "约 " + duration }
        var evidence = PanelAnomalies.reasonWord(item: e.item, code: e.reasonCode)
        if let v = e.peakValue, v.isFinite {
            let unit = e.unit ?? ""
            let number = String(format: "%.0f", v)
            if unit == "%" {
                evidence += " " + number + "%"
            } else if unit.isEmpty {
                evidence += " " + number
            } else {
                evidence += " " + number + " " + unit
            }
        }
        if let app = e.app, !app.isEmpty { evidence += "，" + app }
        let id = "\(e.item.rawValue)-\(Int(e.start.timeIntervalSince1970))"
        var span = startText + " 起，进行中"
        if let end = e.end { span = startText + "\u{2013}" + TextFormat.clock(end, timeZone: tz) }
        return RecordRow(id: id, item: e.item, level: e.peak, title: SidebarItem(e.item).label, evidence: evidence,
                         span: span, duration: duration, ongoing: ongoing, start: e.start, end: e.end)
    }
}

// MARK: - Record strip

/// One anomaly period on the strip above the record list, as fractions of the strip width (docs/DESIGN_V3.md 6.1).
struct RecordStripSegment: Equatable {
    var from: Double
    var to: Double
    var level: HealthLevel
}

enum RecordStrip {
    /// The periods of the rows that overlap the last `days` days. Yellow first, so red draws on top.
    /// A period shorter than `minFraction` is widened to it, so a 10 minute record stays visible on a 7 day strip.
    static func segments(_ rows: [RecordRow], days: Int, now: Date, minFraction: Double = 0.008) -> [RecordStripSegment] {
        let span = Double(days) * 86400
        guard span > 0 else { return [] }
        let from = now.addingTimeInterval(-span)
        var out = [RecordStripSegment]()
        for row in rows {
            let end = row.end ?? now
            guard end > from, row.start < now else { continue }
            var a = max(0, row.start.timeIntervalSince(from) / span)
            var b = min(1, end.timeIntervalSince(from) / span)
            if b - a < minFraction {
                b = min(1, a + minFraction)
                a = max(0, b - minFraction)
            }
            out.append(RecordStripSegment(from: a, to: b, level: row.level))
        }
        return out.sorted { ($0.level == .red ? 1 : 0, $0.from) < ($1.level == .red ? 1 : 0, $1.from) }
    }

    /// Labels under the strip: the first day ("10月12日") and "今天".
    static func labels(days: Int, now: Date, timeZone: TimeZone) -> (String, String) {
        let start = now.addingTimeInterval(-Double(days - 1) * 86400)
        let local = start.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: start))
        let c = UTCTime.civil(fromDayIndex: Int64((local / 86400).rounded(.down)))
        return ("\(c.month)月\(c.day)日", "今天")
    }
}

// MARK: - Summary sentence

/// The statistics as one sentence in body type (docs/DESIGN_V3.md 6: no stat blocks).
/// Example: "当前 74%，2 小时均值 56%，峰值 81%". A part whose value is missing ("—") is left out.
enum SidebarSummary {
    private static let dash = "\u{2014}"

    static func sentence(_ item: SidebarItem, range: SidebarRange, stats: [SidebarStat]) -> String {
        func value(_ i: Int) -> String? {
            guard stats.indices.contains(i) else { return nil }
            let v = stats[i].value
            return v.isEmpty || v == dash ? nil : v
        }
        var parts = [String]()
        func add(_ i: Int, _ make: (String) -> String) { if let v = value(i) { parts.append(make(v)) } }
        switch item {
        case .cpu:
            add(0) { "当前 " + $0 }
            add(1) { range.label + "均值 " + $0 }
            add(2) { "峰值 " + $0 }
        case .memory:
            add(0) { "压力 " + $0 }
            add(1) { "swap " + $0 }
            add(2) { "30 分钟变化 " + $0 }
        case .disk:
            add(0) { "1 天 " + $0 }
            add(1) { "5 天 " + $0 }
            add(2) { "30 天 " + $0 }
        case .network:
            // Yesterday is left out: the sentence stays on one line.
            add(0) { "今天 " + $0 }
            add(2) { "近 30 天" + ($0.hasPrefix("至少") ? $0 : " " + $0) }
        case .battery:
            add(0) { "电量 " + $0 }
            add(1) { $0 == "接电源" ? "已接电源" : "用" + $0 }
            add(2) { "上次睡眠掉电 " + $0 }
        case .thermal:
            add(0) { "热状态" + $0 }
            add(1) { "已持续 " + $0 }
            add(2) { "SMC 温度 " + $0 + "（仅参考）" }
        case .anomalyLog:
            return ""
        }
        if parts.isEmpty { return "还没有读数" }
        return parts.joined(separator: "，")
    }
}

// MARK: - Entrance

/// Where the sidebar content starts its fade-and-rise (docs/DESIGN_V3.md 6, motion.move): from the height of the row the pointer is on.
/// The distance is a quarter of the row's distance from the panel top, between 8 and 40 pt, so a low row does not throw the content
/// across the whole window.
enum SidebarEntrance {
    /// Top of the row of `item` in the main column, in pt from the panel top. Nil when the item has no row.
    static func rowTop(_ item: SidebarItem, plan: PanelLayoutPlan) -> Double? {
        let base = PanelMetrics.topPadding + PanelMetrics.hero + PanelMetrics.heroGap
        if item == .anomalyLog {
            return base + PanelLayout.rowsHeight(itemCount: plan.rows.count, problems: plan.anomalies.count) + PanelMetrics.rowsToRecordGap
        }
        guard let index = plan.rows.firstIndex(of: item) else { return nil }
        let expanded = plan.problemRowCount
        if index < expanded { return base + Double(index) * (PanelMetrics.problemRow + PanelMetrics.problemRowGap) }
        var top = base
        if expanded > 0 { top += Double(expanded) * PanelMetrics.problemRow + Double(expanded - 1) * PanelMetrics.problemRowGap }
        let quiet = index - expanded
        return top + Double(quiet / PanelMetrics.quietColumns) * PanelMetrics.quietRow
    }

    /// Start offset (pt, downward) of the content for the fade-and-rise.
    static func offset(_ item: SidebarItem, plan: PanelLayoutPlan) -> Double {
        guard let top = rowTop(item, plan: plan) else { return 8 }
        return min(40, max(8, (top - PanelMetrics.topPadding) / 4))
    }
}
