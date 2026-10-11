// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for TrendBuffer, TrendMath, TrendStore and AppRanking (docs/DESIGN.md 9.1).
// Pos: Called from main.swift via runTrendTests(); no top-level code in this file. Owner I1.

import Foundation

/// A coarse point `secondsAgo` before `now` with only the CPU value set.
func tp(_ secondsAgo: Double, cpu: Double? = nil, at base: Date = now) -> TrendPoint {
    var p = TrendPoint(t: base.addingTimeInterval(-secondsAgo))
    p.cpu = cpu
    return p
}

func runTrendTests() {
    section("TrendBuffer: capacity and order")
    var buf = TrendBuffer()
    for i in 0..<300 { buf.appendCoarse(tp(Double(300 - i) * 30, cpu: Double(i))) }
    expect(buf.coarse.count == 240, "coarse capacity is 240, got \(buf.coarse.count)")
    expect(buf.coarse.first?.cpu == 60, "oldest coarse point is dropped first")
    expect(buf.latest?.cpu == 299, "latest is the newest coarse point")
    for i in 0..<200 { buf.appendFine(tp(Double(200 - i) * 2)) }
    expect(buf.fine.count == 150, "fine capacity is 150, got \(buf.fine.count)")
    buf.clearFine()
    expect(buf.fine.isEmpty, "clearFine empties the fine part")

    var back = TrendBuffer()
    back.appendCoarse(tp(60, cpu: 1))
    back.appendCoarse(tp(30, cpu: 2))
    back.appendCoarse(tp(45, cpu: 3))   // the clock moved back
    expect(back.coarse.map { $0.cpu } == [1, 3], "a point older than the last removes the later points")

    let restored = TrendBuffer(restoring: [tp(30, cpu: 2), tp(60, cpu: 1)])
    expect(restored.coarse.map { $0.cpu } == [1, 2], "restoring sorts by time")
    expect(MemoryLayout<TrendPoint>.stride * 390 < 50_000, "buffer memory stays below 50 KB (stride \(MemoryLayout<TrendPoint>.stride))")

    section("TrendBuffer: series and gaps")
    var s1 = TrendBuffer()
    for i in 0..<10 { s1.appendCoarse(tp(Double(10 - i) * 30, cpu: 10)) }
    expect(s1.series(now: now).segments.count == 1, "continuous coarse points form one segment")
    var s2 = TrendBuffer()
    for i in 0..<5 { s2.appendCoarse(tp(1200 - Double(i) * 30, cpu: 10)) }
    for i in 0..<5 { s2.appendCoarse(tp(300 - Double(i) * 30, cpu: 10)) }
    let gapped = s2.series(now: now)
    expect(gapped.segments.count == 2, "a gap of 780 s splits into 2 segments, got \(gapped.segments.count)")
    var s3 = TrendBuffer()
    s3.appendCoarse(tp(120, cpu: 1))
    s3.appendCoarse(tp(30, cpu: 1))     // exactly 90 s apart: no break
    expect(s3.series(now: now).segments.count == 1, "a 90 s distance is not a gap")
    var s4 = TrendBuffer()
    s4.appendCoarse(tp(121, cpu: 1))
    s4.appendCoarse(tp(30, cpu: 1))     // 91 s apart
    expect(s4.series(now: now).segments.count == 2, "a 91 s distance is a gap")

    var s5 = TrendBuffer()
    for i in 0..<20 { s5.appendCoarse(tp(Double(20 - i) * 30, cpu: 10)) }
    for i in 0..<5 { s5.appendFine(tp(Double(5 - i) * 2, cpu: 90)) }
    let mixed = s5.series(now: now)
    let allPoints = mixed.segments.flatMap { $0 }
    expect(allPoints.filter { $0.cpu == 90 }.count == 5, "fine points are in the series")
    expect(allPoints.last?.cpu == 90, "the series ends with the fine points")
    var fineFirst = Date.distantFuture
    for p in s5.fine { fineFirst = min(fineFirst, p.t) }
    expect(allPoints.filter { $0.cpu == 10 && $0.t >= fineFirst }.isEmpty, "fine points cover the coarse points in their time range")
    var s6 = TrendBuffer()
    for i in 0..<3 { s6.appendFine(tp(40 - Double(i) * 2, cpu: 1)) }
    for i in 0..<3 { s6.appendFine(tp(20 - Double(i) * 2, cpu: 1)) }   // 12 s hole between fine points
    expect(s6.series(now: now).segments.count == 2, "a fine gap above 6 s splits the segment")
    expect(TrendBuffer().series(now: now) == .empty, "an empty buffer gives an empty series")
    var old = TrendBuffer()
    old.appendCoarse(tp(8000, cpu: 1))
    expect(old.series(now: now) == .empty, "points older than 2 hours are left out of the series")

    section("TrendBuffer: cpuSummary")
    var cs = TrendBuffer()
    cs.appendCoarse(tp(8000, cpu: 99))
    cs.appendCoarse(tp(90, cpu: 10))
    cs.appendCoarse(tp(60, cpu: 30))
    cs.appendCoarse(tp(30, cpu: nil))
    let sum = cs.cpuSummary(now: now)
    expect(sum?.mean == 20 && sum?.peak == 30, "cpuSummary skips nil and points outside 2 hours")
    expect(TrendBuffer().cpuSummary(now: now) == nil, "no points gives no summary")

    section("TrendMath")
    let pts: [TrendPoint] = (0..<20).map { tp(Double(19 - $0) * 30, cpu: $0 < 10 ? 20 : 90) }
    let run = TrendMath.run(pts, now: now)
    expect(run.count == 20, "run takes all continuous points")
    expect(TrendMath.run(pts, now: now.addingTimeInterval(200)).isEmpty, "a stale run is empty")
    let holed = [tp(1000, cpu: 1), tp(970, cpu: 1), tp(60, cpu: 1), tp(30, cpu: 1)]
    expect(TrendMath.run(holed, now: now).count == 2, "run stops at the gap")
    let m = TrendMath.mean(run, end: 19, window: 300) { $0.cpu }
    expect(m != nil && abs(m! - 90) < 0.001, "300 s mean over the last high points is 90, got \(String(describing: m))")
    expect(TrendMath.mean(run, end: 19, window: 1800) { $0.cpu } == nil, "a window longer than the run has no mean")
    let st = TrendMath.streak(run) { run[$0].cpu.map { $0 >= 80 } }
    expect(st != nil && Int(st!.duration) == 270, "streak lasts 270 s, got \(String(describing: st?.duration))")
    expect(TrendMath.lasted(st, 270) && TrendMath.lasted(st, 280) && !TrendMath.lasted(st, 300), "lasted uses the 10 s tolerance")
    expect(TrendMath.streak(run) { _ in false } == nil, "no streak when the newest point fails")
    expect(TrendMath.streak(run) { _ in nil } == nil, "nil answers count as not satisfied")
    expect(TrendMath.nearest(pts, to: now.addingTimeInterval(-100), tolerance: 20)?.t == pts[16].t, "nearest finds the closest point")
    expect(TrendMath.nearest(pts, to: now.addingTimeInterval(-5000), tolerance: 20) == nil, "nearest respects the tolerance")

    section("TrendStore")
    var full = TrendPoint(t: now.addingTimeInterval(-90))
    full.cpu = 12.34
    full.rx = 1_234_000
    full.tx = 80_000
    full.swapUsed = 1288 * 1_048_576
    full.battery = 82
    full.pressure = .warning
    full.thermal = .fair
    full.power = .battery
    var holeP = TrendPoint(t: now.addingTimeInterval(-60))
    holeP.power = .ac
    var third = TrendPoint(t: now.addingTimeInterval(-30))
    third.cpu = 9
    third.pressure = .critical
    third.thermal = .critical
    let encoded = (try? TrendStore.encode([full, holeP, third])) ?? Data()
    let decoded = TrendStore.decode(encoded, now: now)
    expect(decoded.count == 3, "round trip keeps 3 points, got \(decoded.count)")
    if decoded.count == 3 {
        expect(decoded[0].cpu == 12.3, "cpu is rounded to 1 decimal")
        expect(decoded[0].rx == 1_234_000 && decoded[0].tx == 80_000, "rx and tx round trip in KB/s")
        expect(decoded[0].swapUsed == 1288 * 1_048_576, "swap round trips in MiB")
        expect(decoded[0].battery == 82 && decoded[0].power == .battery, "battery and power round trip")
        expect(decoded[0].pressure == .warning && decoded[0].thermal == .fair, "pressure and thermal round trip")
        expect(decoded[1].cpu == nil && decoded[1].rx == nil && decoded[1].battery == nil && decoded[1].pressure == nil && decoded[1].power == .ac,
               "a missing value stays nil and is not zero")
        expect(decoded[2].pressure == .critical && decoded[2].thermal == .critical, "critical codes round trip")
    }
    let text = String(data: encoded, encoding: .utf8) ?? ""
    expect(text.contains("\"v\":1") && text.contains("\"dt\":[0,30,60]") && text.contains("\"ps\":[\"b\",\"a\",null]"),
           "the file is columnar with relative seconds: \(text)")

    let dropWindow = TrendStore.decode(encoded, now: now.addingTimeInterval(7150))
    expect(dropWindow.count == 1, "points older than 2 hours are dropped, got \(dropWindow.count)")
    let dropFuture = TrendStore.decode(encoded, now: now.addingTimeInterval(-75))
    expect(dropFuture.count == 1, "points newer than now are dropped, got \(dropFuture.count)")
    expect(TrendStore.decode(Data("not json".utf8), now: now).isEmpty, "a damaged file gives an empty array")
    expect(TrendStore.decode(Data(), now: now).isEmpty, "an empty file gives an empty array")
    let wrongVersion = text.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
    expect(TrendStore.decode(Data(wrongVersion.utf8), now: now).isEmpty, "a wrong version gives an empty array")
    let unequal = text.replacingOccurrences(of: "\"dt\":[0,30,60]", with: "\"dt\":[0,30]")
    expect(TrendStore.decode(Data(unequal.utf8), now: now).isEmpty, "unequal lengths give an empty array")
    let notAscending = text.replacingOccurrences(of: "\"dt\":[0,30,60]", with: "\"dt\":[0,60,30]")
    expect(TrendStore.decode(Data(notAscending.utf8), now: now).isEmpty, "unordered times give an empty array")
    let legacy = "{\"v\":1,\"t0\":\"2026-10-11T11:58:30Z\",\"dt\":[0,30],\"cpu\":[1.5,2.5],\"rx\":[1,2],\"tx\":[3,4],\"swap\":[10,20],\"mp\":[\"n\",\"w\"],\"th\":[\"n\",\"f\"]}"
    let legacyPoints = TrendStore.decode(Data(legacy.utf8), now: now)
    expect(legacyPoints.count == 2 && legacyPoints[0].battery == nil && legacyPoints[1].power == nil && legacyPoints[1].pressure == .warning,
           "an older file without bat and ps reads as nil")
    expect((try? TrendStore.encode([])).flatMap { TrendStore.decode($0, now: now) }?.isEmpty == true, "an empty array round trips")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-trend-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try TrendStore.write([full, holeP, third], dir: dir)
        let file = dir.appendingPathComponent(TrendStore.fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(mode == 0o600, "trend.json mode is 0600, got \(String(mode, radix: 8))")
        expect(TrendStore.load(dir: dir, now: now).count == 3, "load reads what write wrote")
        try TrendStore.write([third], dir: dir)
        expect(TrendStore.load(dir: dir, now: now).count == 1, "a second write replaces the file")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        expect(leftovers.isEmpty, "no temp file stays behind")
    } catch {
        expect(false, "write and load threw \(error)")
    }
    expect(TrendStore.load(dir: dir.appendingPathComponent("missing"), now: now).isEmpty, "a missing file gives an empty array")
    expect(TrendBuffer(restoring: decoded).coarse.count == decoded.count, "a buffer restores from decoded points")

    runAppRankingTests()
}

func runAppRankingTests() {
    // Filled in with the AppRanking implementation.
}
