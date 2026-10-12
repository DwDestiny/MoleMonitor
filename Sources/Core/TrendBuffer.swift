// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points from the engine (one per 30 s coarse, one per 2 s fine while the card is open).
// Output: TrendSeries split at gaps, the 2 hour CPU summary, and window helpers for the health rules (docs/DESIGN.md 6.3, 6.5, 8.1).
// Pos: In-memory ring buffer behind the trend strip and the problem charts; Foundation only. Owner I1.
//      390 points x 88 bytes = 34 KB (checked by a test against the 50 KB limit).

import Foundation

struct TrendPoint: Codable, Equatable {
    var t: Date
    var cpu: Double?
    var rx: Double?
    var tx: Double?
    var swapUsed: Int64?
    var battery: Double?            // Battery percent. Nil when the Mac has no battery.
    var pressure: MemoryPressure?
    var thermal: ThermalLevel?
    var power: PowerSource?
    /// Memory pressure percent, 0 to 100. Nil means "not measured", also for points decoded from an older file.
    var pressurePercent: Int?

    enum CodingKeys: String, CodingKey {
        case t, cpu, rx, tx, swapUsed, battery, pressure, thermal, power
        case pressurePercent = "pp"
    }
}

struct CPUSummary: Codable, Equatable {
    var mean: Double
    var peak: Double
}

struct TrendSeries: Equatable {
    /// Segments split at gaps. Each segment is in ascending time order.
    var segments: [[TrendPoint]]
    var latest: TrendPoint? { segments.last?.last }
    static let empty = TrendSeries(segments: [])
}

struct TrendBuffer {
    static let coarseInterval: TimeInterval = 30
    static let coarseCapacity = 240
    static let fineInterval: TimeInterval = 2
    static let fineCapacity = 150

    private var coarsePoints = [TrendPoint]()
    private var finePoints = [TrendPoint]()

    init() {}

    /// A buffer restored from trend.json. Only the newest `coarseCapacity` points are kept.
    init(restoring points: [TrendPoint]) {
        let sorted = points.sorted { $0.t < $1.t }
        coarsePoints = Array(sorted.suffix(TrendBuffer.coarseCapacity))
    }

    /// Appends one 30 second point. A point that is not newer than the last one (the clock moved back) removes
    /// the points from its time on, so the buffer stays in time order.
    mutating func appendCoarse(_ p: TrendPoint) {
        if let last = coarsePoints.last, p.t <= last.t { coarsePoints.removeAll { $0.t >= p.t } }
        coarsePoints.append(p)
        if coarsePoints.count > TrendBuffer.coarseCapacity {
            coarsePoints.removeFirst(coarsePoints.count - TrendBuffer.coarseCapacity)
        }
    }

    /// Appends one 2 second point. Fine points are never written to disk.
    mutating func appendFine(_ p: TrendPoint) {
        if let last = finePoints.last, p.t <= last.t { finePoints.removeAll { $0.t >= p.t } }
        finePoints.append(p)
        if finePoints.count > TrendBuffer.fineCapacity {
            finePoints.removeFirst(finePoints.count - TrendBuffer.fineCapacity)
        }
    }

    mutating func clearFine() {
        finePoints = []
    }

    var coarse: [TrendPoint] { coarsePoints }
    var fine: [TrendPoint] { finePoints }
    var latest: TrendPoint? { coarsePoints.last }

    /// Merges the coarse and fine parts, splits at gaps. The default window is 2 hours.
    /// Where the fine part starts, the coarse points are left out, so the two never draw the same time twice.
    func series(now: Date, window: TimeInterval = 7200) -> TrendSeries {
        let start = now.addingTimeInterval(-window)
        let fineStart = finePoints.first?.t
        var tagged = [(point: TrendPoint, isFine: Bool)]()
        for p in coarsePoints where p.t >= start && p.t <= now {
            if let fineStart, p.t >= fineStart { continue }
            tagged.append((p, false))
        }
        for p in finePoints where p.t >= start && p.t <= now { tagged.append((p, true)) }
        guard !tagged.isEmpty else { return .empty }
        let coarseGap = 3 * TrendBuffer.coarseInterval
        let fineGap = 3 * TrendBuffer.fineInterval
        var segments = [[TrendPoint]]()
        var current = [TrendPoint]()
        var previous: (point: TrendPoint, isFine: Bool)?
        for entry in tagged {
            if let previous {
                let limit = (previous.isFine && entry.isFine) ? fineGap : coarseGap
                if entry.point.t.timeIntervalSince(previous.point.t) > limit {
                    segments.append(current)
                    current = []
                }
            }
            current.append(entry.point)
            previous = entry
        }
        segments.append(current)
        return TrendSeries(segments: segments)
    }

    /// Splits ascending points where two neighbours are more than `maxGap` seconds apart.
    static func segments(_ points: [TrendPoint], maxGap: TimeInterval) -> [[TrendPoint]] {
        var out = [[TrendPoint]]()
        var current = [TrendPoint]()
        for p in points {
            if let last = current.last, p.t.timeIntervalSince(last.t) > maxGap {
                out.append(current)
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 2 hour CPU mean and peak for the prompt and status.json. Nil without any CPU value.
    func cpuSummary(now: Date) -> CPUSummary? {
        let start = now.addingTimeInterval(-7200)
        var sum = 0.0
        var peak = 0.0
        var n = 0
        for p in coarsePoints where p.t >= start && p.t <= now {
            guard let cpu = p.cpu else { continue }
            sum += cpu
            peak = max(peak, cpu)
            n += 1
        }
        guard n > 0 else { return nil }
        return CPUSummary(mean: sum / Double(n), peak: peak)
    }
}

/// Window helpers for the health rules. Pure functions over ascending points.
enum TrendMath {
    /// Two points further apart than this are not in the same run (sleep or a stopped app). 3 coarse intervals.
    static let maxGap: TimeInterval = 3 * TrendBuffer.coarseInterval
    /// Timer jitter allowance for "sustained for D seconds" (timer leeway is 6 s).
    static let tolerance: TimeInterval = 10
    /// A window mean needs this share of the window covered by data.
    static let minCoverage = 0.9

    /// The trailing run: the newest points without a gap larger than `maxGap`.
    /// Empty when the newest point is older than `maxGap` before `now`.
    static func run(_ points: [TrendPoint], now: Date) -> [TrendPoint] {
        guard let last = points.last, now.timeIntervalSince(last.t) <= maxGap else { return [] }
        var start = points.count - 1
        while start > 0, points[start].t.timeIntervalSince(points[start - 1].t) <= maxGap { start -= 1 }
        return Array(points[start...])
    }

    /// Mean of `value` over the points with t in (run[end].t - window, run[end].t], or nil when the run does not
    /// cover 90 % of the window or no point has a value.
    static func mean(_ run: [TrendPoint], end: Int, window: TimeInterval, value: (TrendPoint) -> Double?) -> Double? {
        guard end >= 0, end < run.count else { return nil }
        let endTime = run[end].t
        guard endTime.timeIntervalSince(run[0].t) >= window * minCoverage else { return nil }
        let from = endTime.addingTimeInterval(-window)
        var sum = 0.0
        var n = 0
        var i = end
        while i >= 0, run[i].t > from {
            if let v = value(run[i]) {
                sum += v
                n += 1
            }
            i -= 1
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// The trailing stretch of points for which `predicate` is true. Nil when the newest point does not satisfy it
    /// (a nil answer counts as "not satisfied"). `start` is the time of the first point of the stretch.
    static func streak(_ run: [TrendPoint], predicate: (Int) -> Bool?) -> (start: Date, duration: TimeInterval)? {
        guard !run.isEmpty, predicate(run.count - 1) == true else { return nil }
        var first = run.count - 1
        while first > 0, predicate(first - 1) == true { first -= 1 }
        return (run[first].t, run[run.count - 1].t.timeIntervalSince(run[first].t))
    }

    /// True when the stretch has lasted at least `duration` seconds (minus the jitter allowance).
    static func lasted(_ streak: (start: Date, duration: TimeInterval)?, _ duration: TimeInterval) -> Bool {
        guard let streak else { return false }
        return streak.duration >= duration - tolerance
    }

    /// The point nearest to `target`, within `tolerance` seconds. Points are ascending.
    static func nearest(_ points: [TrendPoint], to target: Date, tolerance limit: TimeInterval) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < target { lo = mid + 1 } else { hi = mid }
        }
        var best = points[lo]
        if lo > 0, abs(points[lo - 1].t.timeIntervalSince(target)) < abs(best.t.timeIntervalSince(target)) { best = points[lo - 1] }
        return abs(best.t.timeIntervalSince(target)) <= limit ? best : nil
    }
}
