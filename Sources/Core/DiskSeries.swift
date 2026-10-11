// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk samples, the current time and the disk verdict.
// Output: A down-sampled used-space series (at most 120 points) and the growth segment that triggered the alert.
// Pos: Read-only data for the 30 day trend chart in the status card (docs/PROJECT.md 4.2); Foundation only.

import Foundation

struct DiskPoint: Equatable, Identifiable {
    var t: Date
    /// Real used bytes (total - available_important).
    var used: Int64
    var id: Date { t }
    var gb: Double { Double(used) / 1e9 }
}

/// The growth segment behind the verdict: from the lowest point of the trigger window until now.
struct DiskTrigger: Equatable {
    var from: Date
    var fromUsed: Int64
    var level: HealthLevel
    var windowKey: String
}

enum DiskSeries {
    static let bucketSeconds: TimeInterval = 6 * 3600
    static let maxPoints = 120

    /// One point per 6 hour bucket (the last usable sample of the bucket), oldest first, newest 120 buckets at most.
    /// Failed reads and samples after `now` are skipped.
    static func downsample(samples: [DiskSample], now: Date, days: Int = 30) -> [DiskPoint] {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        var usable = [(t: Date, used: Int64)]()
        for s in samples {
            if let u = s.realUsed, s.t >= start, s.t <= now { usable.append((s.t, u)) }
        }
        usable.sort { $0.t < $1.t }
        var out = [DiskPoint]()
        var lastBucket: Int64?
        for p in usable {
            let bucket = UTCTime.floorDiv(Int64(p.t.timeIntervalSince1970.rounded(.down)), Int64(bucketSeconds))
            let point = DiskPoint(t: p.t, used: p.used)
            if bucket == lastBucket, !out.isEmpty {
                out[out.count - 1] = point
            } else {
                out.append(point)
                lastBucket = bucket
            }
        }
        if out.count > maxPoints { out.removeFirst(out.count - maxPoints) }
        return out
    }

    /// The segment to highlight, or nil when growth does not trigger (green, or only low space).
    static func trigger(verdict: DiskVerdict, samples: [DiskSample]) -> DiskTrigger? {
        guard let window = verdict.triggerWindow, (verdict.growthLevel.colorRank ?? 0) >= 1 else { return nil }
        let growth: DiskGrowth
        switch window {
        case .day1: growth = verdict.growth1d
        case .day5: growth = verdict.growth5d
        case .day30: return nil
        }
        guard let from = growth.fromMinAt,
              let low = samples.first(where: { $0.t == from && $0.realUsed != nil }), let used = low.realUsed
        else { return nil }
        return DiskTrigger(from: from, fromUsed: used, level: verdict.growthLevel, windowKey: window.key)
    }

    /// Points of the highlighted line: the exact start point, then every series point after it.
    static func triggerPoints(series: [DiskPoint], trigger: DiskTrigger) -> [DiskPoint] {
        [DiskPoint(t: trigger.from, used: trigger.fromUsed)] + series.filter { $0.t > trigger.from }
    }
}
