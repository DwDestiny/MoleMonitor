// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A level (green, yellow, red) and a reference time.
// Output: Invented disk samples (30 days), the engine result computed from them, and a 60 second live snapshot.
// Pos: Example data for `--preview` renders and tests only; the app never calls it at run time. The numbers describe no real machine.

import Foundation

enum PreviewLevel: String, CaseIterable {
    case green, yellow, red
}

enum PreviewScenario {
    static let totalGB = 995.0

    /// Invented used space in GB, `daysAgo` days before now (30 down to 0).
    static func usedGB(_ level: PreviewLevel, daysAgo d: Double) -> Double {
        let wobble = 3.0 * sin(d * 1.7) + 1.5 * sin(d * 4.1)
        switch level {
        case .green:
            return 380 + 0.5 * (30 - d) + wobble
        case .yellow:
            let ramp = max(0, min(1, (4.6 - d) / 4.6))
            return 450 + 0.3 * (30 - d) + 105 * ramp + wobble
        case .red:
            let ramp = max(0, min(1, (4.8 - d) / 4.8))
            return 271 + 0.4 * (30 - d) + 310 * ramp * ramp * (3 - 2 * ramp) + wobble
        }
    }

    /// One sample every 3 hours for 30 days, with invented cumulative network counters.
    static func samples(_ level: PreviewLevel, now: Date) -> [DiskSample] {
        let step = 3 * 3600.0
        let count = Int(30 * 86400 / step)
        var out = [DiskSample]()
        var rx: Int64 = 2_000_000_000_000
        var tx: Int64 = 300_000_000_000
        for i in 0...count {
            let age = Double(count - i) * step
            rx += 1_020_000_000
            tx += 140_000_000
            let used = Int64(usedGB(level, daysAgo: age / 86400) * 1e9)
            let total = Int64(totalGB * 1e9)
            out.append(DiskSample(t: now.addingTimeInterval(-age), src: .timer, total: total,
                                  availImportant: total - used, avail: total - used - 14_000_000_000,
                                  netRx: rx, netTx: tx))
        }
        return out
    }

    /// The real engine logic applied to the invented samples. Alerts start 3 hours before `now`.
    static func result(_ level: PreviewLevel, now: Date) -> (result: DiskEngineResult, samples: [DiskSample]) {
        let s = samples(level, now: now)
        var state = DiskEngineState()
        let since = now.addingTimeInterval(-3 * 3600)
        state.alertSince = ["disk_growth": since, "disk_low_space": since]
        let (r, _) = DiskEngineLogic.step(samples: s, now: now, todayStart: Calendar.current.startOfDay(for: now), state: state)
        return (r, s)
    }

    /// 30 points, 2 seconds apart, ending at `now`. Smooth invented curves.
    static func live(now: Date) -> LiveSnapshot {
        var buffer = LiveBuffer()
        let n = 30
        for i in 0..<n {
            let t = now.addingTimeInterval(-Double(n - 1 - i) * LiveSnapshot.interval)
            let x = Double(i)
            let burst = exp(-pow((x - 20) / 3.5, 2))
            let rx = 350_000 + 220_000 * (sin(x * 0.45) + 1) + 2_300_000 * burst
            let tx = 60_000 + 40_000 * (sin(x * 0.9 + 1) + 1) + 260_000 * burst
            let cpu = min(100, max(1, 17 + 9 * sin(x * 0.5) + 5 * sin(x * 1.7) + 24 * burst))
            buffer.add(at: t, rate: NetworkRate(rxPerSecond: rx, txPerSecond: tx), cpuPercent: cpu)
        }
        return buffer.snapshot
    }
}
