// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk samples; number of days; a reference time.
// Output: One row per UTC day for `--disk-history`.
// Pos: CLI report logic; pure function.

import Foundation

/// Per-day summary. growth = last real used of the day - lowest real used of the day (needs 2+ samples).
/// Days without usable samples keep null fields so gaps stay visible.
struct DiskDay: Codable {
    var date: String
    var minUsed: Int64?
    var maxUsed: Int64?
    var growth: Int64?
    var samples: Int

    enum CodingKeys: String, CodingKey {
        case date, growth, samples
        case minUsed = "min_used"
        case maxUsed = "max_used"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(minUsed, forKey: .minUsed)
        try c.encode(maxUsed, forKey: .maxUsed)
        try c.encode(growth, forKey: .growth)
        try c.encode(samples, forKey: .samples)
    }
}

enum DiskReport {
    /// Rows for the last `days` UTC days ending with the day of `now`, oldest first.
    static func daily(samples: [DiskSample], days: Int, now: Date) -> [DiskDay] {
        let n = max(1, days)
        let today = UTCTime.dayIndex(now)
        var byDay = [Int64: [(t: Date, used: Int64)]]()
        for s in samples {
            guard let u = s.realUsed, s.t <= now else { continue }
            byDay[UTCTime.dayIndex(s.t), default: []].append((s.t, u))
        }
        var out = [DiskDay]()
        for idx in (today - Int64(n - 1))...today {
            let name = UTCTime.dayString(dayIndex: idx)
            guard var pts = byDay[idx], !pts.isEmpty else {
                out.append(DiskDay(date: name, minUsed: nil, maxUsed: nil, growth: nil, samples: 0))
                continue
            }
            pts.sort { $0.t < $1.t }
            let lo = pts.map { $0.used }.min()
            let hi = pts.map { $0.used }.max()
            var growth: Int64?
            if pts.count >= 2, let lo, let last = pts.last { growth = last.used - lo }
            out.append(DiskDay(date: name, minUsed: lo, maxUsed: hi, growth: growth, samples: pts.count))
        }
        return out
    }
}
