// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Network rates and CPU percentages with their sample times, one call per 2 second tick while the panel is open.
// Output: LiveSnapshot values (60 second window) for the live charts, and rate text split into value and unit.
// Pos: Pure live-chart data (docs/PROJECT.md 4); memory only, never written to NDJSON or status.json.

import Foundation

struct NetPoint: Equatable, Identifiable {
    var t: Date
    /// Bytes per second, download.
    var rx: Double
    /// Bytes per second, upload.
    var tx: Double
    var id: Date { t }
}

struct CPUPoint: Equatable, Identifiable {
    var t: Date
    /// 0 to 100 for the whole machine.
    var percent: Double
    var id: Date { t }
}

struct LiveSnapshot: Equatable {
    static let windowSeconds: TimeInterval = 60
    static let interval: TimeInterval = 2
    /// 30 points cover 60 seconds; two spare points absorb timer jitter.
    static let capacity = 32
    static let empty = LiveSnapshot(net: [], cpu: [], rx: nil, tx: nil, cpuPercent: nil)

    var net: [NetPoint]
    var cpu: [CPUPoint]
    /// Rate of the newest tick. Nil means "not measured at the newest tick", never 0.
    var rx: Double?
    var tx: Double?
    var cpuPercent: Double?

    /// Time of the newest point of either series.
    var latest: Date? {
        [net.last?.t, cpu.last?.t].compactMap { $0 }.max()
    }
}

/// The two ring buffers behind a LiveSnapshot. Confined to the sampling queue by its owner.
struct LiveBuffer {
    private var net = RingSeries<NetPoint>(capacity: LiveSnapshot.capacity)
    private var cpu = RingSeries<CPUPoint>(capacity: LiveSnapshot.capacity)
    private var rx: Double?
    private var tx: Double?
    private var cpuPercent: Double?

    /// Adds the readings of one tick. A nil reading adds no point and clears the "current" value.
    mutating func add(at t: Date, rate: NetworkRate?, cpuPercent: Double?) {
        if let rate {
            net.append(NetPoint(t: t, rx: rate.rxPerSecond, tx: rate.txPerSecond))
            rx = rate.rxPerSecond
            tx = rate.txPerSecond
        } else {
            rx = nil
            tx = nil
        }
        if let cpuPercent {
            cpu.append(CPUPoint(t: t, percent: cpuPercent))
            self.cpuPercent = cpuPercent
        } else {
            self.cpuPercent = nil
        }
    }

    mutating func removeAll() {
        net.removeAll()
        cpu.removeAll()
        rx = nil
        tx = nil
        cpuPercent = nil
    }

    var snapshot: LiveSnapshot {
        LiveSnapshot(net: net.elements, cpu: cpu.elements, rx: rx, tx: tx, cpuPercent: cpuPercent)
    }
}

enum RateText {
    /// Decimal units (1 KB/s = 1000 B/s), like the disk sizes. One decimal below 10, otherwise whole numbers.
    static func parts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let v = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let units: [(limit: Double, divisor: Double, name: String)] = [
            (1e3, 1, "B/s"), (1e6, 1e3, "KB/s"), (1e9, 1e6, "MB/s"), (Double.infinity, 1e9, "GB/s"),
        ]
        for u in units where v < u.limit {
            let x = v / u.divisor
            if u.divisor == 1 { return (String(Int(x)), u.name) }
            return (x < 10 ? String(format: "%.1f", x) : String(format: "%.0f", x), u.name)
        }
        return ("0", "B/s")
    }

    static func text(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let p = parts(bytesPerSecond)
        return p.value + " " + p.unit
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }
}
