// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, sample, now, GB) defined in main.swift.
// Output: Assertions for RingSeries, CPULoad, LiveBuffer, RateText, DiskSeries and PreviewScenario.
// Pos: Called from main.swift via runLiveTests(); no top-level code in this file.

import Foundation

private func ticks(_ user: UInt64, _ system: UInt64, _ idle: UInt64, _ nice: UInt64 = 0) -> CPUTicks {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
}

func runLiveTests() {
    section("RingSeries")
    do {
        var r = RingSeries<Int>(capacity: 3)
        expect(r.isEmpty && r.last == nil && r.elements.isEmpty, "empty ring")
        r.append(1); r.append(2)
        expect(r.elements == [1, 2] && r.last == 2 && r.count == 2, "below capacity keeps order")
        r.append(3); r.append(4)
        expect(r.elements == [2, 3, 4] && r.last == 4 && r.count == 3, "full ring drops the oldest")
        r.append(5); r.append(6); r.append(7)
        expect(r.elements == [5, 6, 7] && r.last == 7, "ring wraps more than once")
        r.removeAll()
        expect(r.isEmpty && r.elements.isEmpty && r.last == nil, "removeAll empties the ring")
        r.append(9)
        expect(r.elements == [9] && r.last == 9, "ring works after removeAll")
        expect(RingSeries<Int>(capacity: 0).capacity == 1, "capacity below 1 becomes 1")
    }

    section("CPULoad")
    do {
        let a = [ticks(100, 50, 850), ticks(200, 100, 700)]
        let b = [ticks(130, 60, 910), ticks(260, 120, 720)]
        // busy delta: 30+10 + 60+20 = 120; total delta: 100 + 100 = 200
        let p = CPULoad.percent(prev: a, now: b)
        expect(p != nil && abs(p! - 60) < 1e-9, "60 percent over two cores: \(String(describing: p))")
        expect(CPULoad.percent(prev: a, now: a) == nil, "no tick passed gives nil")
        let idleOnly = CPULoad.percent(prev: [ticks(10, 10, 10)], now: [ticks(10, 10, 110)])
        expect(idleOnly == 0, "measured idle machine gives 0, not nil")
        let full = CPULoad.percent(prev: [ticks(0, 0, 0, 0)], now: [ticks(50, 30, 0, 20)])
        expect(full == 100, "all busy gives 100")
        expect(CPULoad.percent(prev: [ticks(100, 0, 0)], now: [ticks(5, 0, 90)]) == nil, "counter that went down gives nil")
        expect(CPULoad.percent(prev: [ticks(0, 0, 0), ticks(0, 0, 0)], now: [ticks(1, 0, 1)]) == nil, "core count mismatch gives nil")
        expect(CPULoad.percent(prev: [], now: []) == nil, "empty readings give nil")
        let niceCase = CPULoad.percent(prev: [ticks(0, 0, 0, 0)], now: [ticks(0, 0, 50, 50)])
        expect(niceCase == 50, "nice ticks count as busy")
        let wrap = CPULoad.percent(prev: [ticks(4_294_967_290, 0, 0)], now: [ticks(3, 0, 5)])
        expect(wrap == nil, "32-bit wrap-around gives nil")
    }

    section("LiveBuffer")
    do {
        var buf = LiveBuffer()
        let empty = buf.snapshot
        expect(empty == LiveSnapshot.empty && empty.latest == nil, "empty buffer gives the empty snapshot")
        buf.add(at: ago(0.01), rate: NetworkRate(rxPerSecond: 1000, txPerSecond: 200), cpuPercent: 12)
        var snap = buf.snapshot
        expect(snap.net.count == 1 && snap.cpu.count == 1 && snap.rx == 1000 && snap.tx == 200 && snap.cpuPercent == 12, "one tick")
        buf.add(at: ago(0.005), rate: nil, cpuPercent: nil)
        snap = buf.snapshot
        expect(snap.net.count == 1 && snap.cpu.count == 1 && snap.rx == nil && snap.tx == nil && snap.cpuPercent == nil,
               "a missing reading adds no point and clears the current value")
        for i in 0..<100 {
            buf.add(at: now.addingTimeInterval(Double(i)), rate: NetworkRate(rxPerSecond: Double(i), txPerSecond: 0), cpuPercent: 0)
        }
        snap = buf.snapshot
        expect(snap.net.count == LiveSnapshot.capacity && snap.cpu.count == LiveSnapshot.capacity, "capacity limits both series")
        expect(snap.net.last?.rx == 99 && snap.cpuPercent == 0, "newest value kept; a measured 0 stays 0")
        expect(snap.latest == now.addingTimeInterval(99), "latest time")
        buf.removeAll()
        expect(buf.snapshot == LiveSnapshot.empty, "removeAll clears everything")
    }

    section("RateText")
    do {
        expect(RateText.parts(0) == ("0", "B/s"), "0 B/s")
        expect(RateText.parts(999) == ("999", "B/s"), "999 B/s")
        expect(RateText.parts(1500) == ("1.5", "KB/s"), "1.5 KB/s")
        expect(RateText.parts(12_340) == ("12", "KB/s"), "12 KB/s")
        expect(RateText.parts(2_500_000) == ("2.5", "MB/s"), "2.5 MB/s")
        expect(RateText.parts(1.2e9) == ("1.2", "GB/s"), "1.2 GB/s")
        expect(RateText.parts(-5) == ("0", "B/s") && RateText.parts(.nan) == ("0", "B/s"), "negative and NaN give 0 B/s")
        expect(RateText.text(nil) == "—" && RateText.text(2_500_000) == "2.5 MB/s", "text form")
        expect(RateText.percent(nil) == "—" && RateText.percent(23.4) == "23%" && RateText.percent(180) == "100%", "percent text")
    }

    section("DiskSeries")
    do {
        // Six samples in two 6-hour buckets (UTC 00-06 and 06-12 of 2026-10-11), plus old and failed rows.
        func at(_ iso: String, _ usedGB: Int64) -> DiskSample {
            DiskSample(t: UTCTime.parseISO(iso)!, total: 1000 * GB, availImportant: (1000 - usedGB) * GB)
        }
        let rows = [at("2026-10-11T01:00:00Z", 100), at("2026-10-11T05:59:00Z", 110), at("2026-10-11T06:00:00Z", 120),
                    at("2026-10-11T11:30:00Z", 130), at("2026-09-01T00:00:00Z", 50),
                    DiskSample(t: UTCTime.parseISO("2026-10-11T09:00:00Z")!, ok: false, err: "x"),
                    at("2026-10-11T13:00:00Z", 999)]
        let pts = DiskSeries.downsample(samples: rows.reversed(), now: now)
        expect(pts.map { $0.used / GB } == [110, 130], "last sample per bucket; old, failed and future rows skipped: \(pts.map { $0.used / GB })")
        expect(pts.first.map { abs($0.gb - 110) < 1e-9 } == true, "gb conversion")

        var many = [DiskSample]()
        for i in 0..<400 { many.append(sample(Double(i) * 1.9, usedGB: 100)) }
        let capped = DiskSeries.downsample(samples: many, now: now, days: 35)
        expect(capped.count <= DiskSeries.maxPoints && capped.count > 100, "at most \(DiskSeries.maxPoints) points: \(capped.count)")
        expect(capped == capped.sorted { $0.t < $1.t }, "oldest first")
        expect(DiskSeries.downsample(samples: [], now: now).isEmpty, "no samples gives an empty series")

        // Trigger: 5 day growth from 100 GB (120 h ago) to 400 GB.
        let s = [sample(119.5, usedGB: 100), sample(72, usedGB: 150), sample(0, usedGB: 400)]
        let v = eval(s)
        let trig = DiskSeries.trigger(verdict: v, samples: s)
        expect(v.level == .red && trig?.windowKey == "5d" && trig?.fromUsed == 100 * GB && trig?.level == .red, "red 5d trigger")
        expect(trig?.from == ago(119.5), "trigger starts at the lowest point")
        if let trig {
            let line = DiskSeries.triggerPoints(series: DiskSeries.downsample(samples: s, now: now), trigger: trig)
            expect(line.first?.t == trig.from && line.first?.used == 100 * GB && line.last?.used == 400 * GB && line.count == 3,
                   "highlight line starts at the exact trigger point: \(line.count)")
        }
        expect(DiskSeries.trigger(verdict: eval(flatSeries(300)), samples: flatSeries(300)) == nil, "green has no trigger")
        let lowSpace = [sample(120, usedGB: 940), sample(0, usedGB: 945)]
        expect(DiskSeries.trigger(verdict: eval(lowSpace), samples: lowSpace) == nil, "low space only has no growth trigger")
    }

    section("PreviewScenario")
    do {
        for level in PreviewLevel.allCases {
            let (r, samples) = PreviewScenario.result(level, now: now)
            let want: HealthLevel = level == .green ? .green : (level == .yellow ? .yellow : .red)
            expect(r.items.disk.level == want, "\(level) scenario gives level \(r.items.disk.level)")
            expect(r.activeAlerts.isEmpty == (level == .green), "\(level) scenario alerts: \(r.activeAlerts.count)")
            expect(DiskSeries.downsample(samples: samples, now: now).count >= 100, "\(level) scenario has a long series")
            let t = DiskSeries.trigger(verdict: r.verdict, samples: samples)
            expect((t != nil) == (level != .green), "\(level) scenario trigger: \(String(describing: t))")
            expect(r.items.disk.used.value != nil && r.items.network.traffic["5d"]?.rx != nil, "\(level) scenario has used space and traffic")
        }
        let live = PreviewScenario.live(now: now)
        expect(live.net.count == 30 && live.cpu.count == 30 && live.latest == now, "live preview has 30 points")
        expect(live.cpu.allSatisfy { $0.percent >= 0 && $0.percent <= 100 } && live.net.allSatisfy { $0.rx >= 0 && $0.tx >= 0 },
               "live preview values are in range")
    }
}
