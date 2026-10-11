// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk samples sorted or unsorted; a reference time.
// Output: Growth over 1/5/30 day windows and segmented network traffic totals.
// Pos: Pure logic shared by the app and the CLI (docs/PROJECT.md 3.5, 7.3); Foundation only.

import Foundation

enum DiskWindow: CaseIterable {
    case day1, day5, day30

    var seconds: TimeInterval {
        switch self {
        case .day1: return 86400
        case .day5: return 5 * 86400
        case .day30: return 30 * 86400
        }
    }

    var key: String {
        switch self {
        case .day1: return "1d"
        case .day5: return "5d"
        case .day30: return "30d"
        }
    }

    var days: Int { Int(seconds / 86400) }
}

/// Growth = current real used - lowest real used in the window. Net = current - earliest in the window.
/// Exception to "value only when ok": with 2+ samples the bytes are given even if coverage is low (a lower bound).
struct DiskGrowth: Codable {
    var window: String
    var bytes: Int64?
    var netBytes: Int64?
    var fromMinAt: Date?
    var coveredHours: Double
    var status: ValueStatus

    enum CodingKeys: String, CodingKey {
        case window, bytes, status
        case netBytes = "net_bytes"
        case fromMinAt = "from_min_at"
        case coveredHours = "covered_hours"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(window, forKey: .window)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(netBytes, forKey: .netBytes)
        try c.encode(fromMinAt, forKey: .fromMinAt)
        try c.encode(coveredHours, forKey: .coveredHours)
        try c.encode(status, forKey: .status)
    }

    static let minCoverage = 0.9

    static func compute(samples: [DiskSample], now: Date, window: DiskWindow) -> DiskGrowth {
        let start = now.addingTimeInterval(-window.seconds)
        var pts = [(t: Date, used: Int64)]()
        for s in samples {
            if let u = s.realUsed, s.t >= start, s.t <= now { pts.append((s.t, u)) }
        }
        pts.sort { $0.t < $1.t }
        guard let first = pts.first, let last = pts.last else {
            return DiskGrowth(window: window.key, bytes: nil, netBytes: nil, fromMinAt: nil, coveredHours: 0, status: .collecting)
        }
        let covered = now.timeIntervalSince(first.t)
        let coveredHours = covered / 3600
        guard pts.count >= 2 else {
            return DiskGrowth(window: window.key, bytes: nil, netBytes: nil, fromMinAt: nil,
                              coveredHours: coveredHours, status: .insufficientWindow)
        }
        var low = pts[0]
        for p in pts where p.used < low.used { low = p }
        let status: ValueStatus = covered >= minCoverage * window.seconds ? .ok : .insufficientWindow
        return DiskGrowth(window: window.key, bytes: last.used - low.used, netBytes: last.used - first.used,
                          fromMinAt: low.t, coveredHours: coveredHours, status: status)
    }
}

/// Network bytes summed over adjacent sample pairs; a pair is skipped when the counters reset.
struct TrafficTotals: Codable {
    var rx: Int64?
    var tx: Int64?
    var coveredHours: Double
    var status: ValueStatus

    enum CodingKeys: String, CodingKey {
        case rx, tx, status
        case coveredHours = "covered_hours"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rx, forKey: .rx)
        try c.encode(tx, forKey: .tx)
        try c.encode(coveredHours, forKey: .coveredHours)
        try c.encode(status, forKey: .status)
    }

    /// Uses ok samples with both counters inside since...now. A boot change or a smaller counter skips that pair.
    static func compute(samples: [DiskSample], since: Date, now: Date) -> TrafficTotals {
        var pts = samples.filter { $0.ok && $0.netRx != nil && $0.netTx != nil && $0.t >= since && $0.t <= now }
        pts.sort { $0.t < $1.t }
        guard let first = pts.first else {
            return TrafficTotals(rx: nil, tx: nil, coveredHours: 0, status: .collecting)
        }
        let covered = now.timeIntervalSince(first.t)
        let hours = covered / 3600
        var rx: Int64 = 0, tx: Int64 = 0
        var pairs = 0
        for i in 1..<max(pts.count, 1) {
            let a = pts[i - 1], b = pts[i]
            guard let arx = a.netRx, let atx = a.netTx, let brx = b.netRx, let btx = b.netTx else { continue }
            if a.boot != b.boot || brx < arx || btx < atx { continue }
            rx += brx - arx
            tx += btx - atx
            pairs += 1
        }
        guard pairs > 0 else {
            return TrafficTotals(rx: nil, tx: nil, coveredHours: hours, status: .insufficientWindow)
        }
        let span = now.timeIntervalSince(since)
        let status: ValueStatus = covered >= DiskGrowth.minCoverage * span ? .ok : .insufficientWindow
        return TrafficTotals(rx: rx, tx: tx, coveredHours: hours, status: status)
    }
}
