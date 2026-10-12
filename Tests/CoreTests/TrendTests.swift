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
    var pts = [TrendPoint]()
    for i in 0..<20 {
        let age: Double = Double(19 - i) * 30.0
        let load: Double = i < 10 ? 20.0 : 90.0
        pts.append(tp(age, cpu: load))
    }
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

private func proc(_ pid: Int32, _ name: String, key: String? = nil, cpuMs: UInt64, fp: UInt64? = nil, rss: UInt64? = nil,
                  start: UInt64 = 1, system: Bool = false, display: String? = nil) -> ProcessSample {
    ProcessSample(pid: pid, startAbs: start, name: name, appKey: key ?? "proc:" + name, displayName: display ?? name,
                  bundleID: key, cpuTimeNs: cpuMs * 1_000_000, footprint: fp, rss: rss, isSystem: system)
}

func runAppRankingTests() {
    section("AppRanking")
    let prev = [proc(10, "Render", key: "com.example.render", cpuMs: 1000, fp: 800_000_000, display: "Render"),
                proc(11, "RenderHelper", key: "com.example.render", cpuMs: 500, fp: 200_000_000, display: "Render"),
                proc(20, "Mail", key: "com.example.mail", cpuMs: 100, fp: 300_000_000, display: "Mail"),
                proc(30, "mdworker_shared", cpuMs: 100, fp: 60_000_000, system: true),
                proc(40, "idle", cpuMs: 10, fp: 1_000_000)]
    let cur = [proc(10, "Render", key: "com.example.render", cpuMs: 11_000, fp: 900_000_000, display: "Render"),   // +10 s in 10 s: 100 %
               proc(11, "RenderHelper", key: "com.example.render", cpuMs: 5_500, fp: 300_000_000, display: "Render"), // +5 s: 50 %
               proc(20, "Mail", key: "com.example.mail", cpuMs: 150, fp: 310_000_000, display: "Mail"),            // +50 ms: 0.5 %
               proc(30, "mdworker_shared", cpuMs: 9_000, fp: 60_000_000, system: true),                            // ignored
               proc(40, "idle", cpuMs: 10, fp: 1_000_000),
               proc(50, "NewTool", cpuMs: 2_000, rss: 120_000_000)]                                               // new: 2 s in 10 s
    let usage = AppRanking.usage(previous: prev, current: cur, seconds: 10, ignore: AppRanking.defaultIgnore)
    let byKey = Dictionary(uniqueKeysWithValues: usage.map { ($0.key, $0) })
    expect(byKey["com.example.render"]?.cpuPercent == 150, "processes of one app add up (can exceed 100 %), got \(String(describing: byKey["com.example.render"]?.cpuPercent))")
    expect(byKey["com.example.render"]?.memoryBytes == 1_200_000_000 && byKey["com.example.render"]?.processCount == 2, "memory adds footprints")
    expect(byKey["com.example.render"]?.memoryBasis == "footprint" && byKey["com.example.render"]?.name == "Render", "footprint basis and bundle display name")
    expect(abs((byKey["com.example.mail"]?.cpuPercent ?? 0) - 0.5) < 0.0001, "0.5 % is measured")
    expect(byKey["proc:mdworker_shared"] == nil, "ignored processes are not listed")
    expect(abs((byKey["proc:NewTool"]?.cpuPercent ?? 0) - 20) < 0.0001, "a new process counts its CPU time")
    expect(byKey["proc:NewTool"]?.memoryBasis == "rss" && byKey["proc:NewTool"]?.memoryBytes == 120_000_000, "rss is the fallback basis")
    expect(byKey["proc:NewTool"]?.isSystem == false && byKey["com.example.render"]?.isSystem == false, "isSystem needs every process to be a system process")

    let reused = AppRanking.usage(previous: [proc(10, "Old", cpuMs: 5_000, start: 1)], current: [proc(10, "New", cpuMs: 1_000, start: 2)], seconds: 10, ignore: [])
    expect(abs((reused.first?.cpuPercent ?? 0) - 10) < 0.0001, "a reused pid with a new start time is a new process")
    let backwards = AppRanking.usage(previous: [proc(10, "A", cpuMs: 5_000)], current: [proc(10, "A", cpuMs: 1_000)], seconds: 10, ignore: [])
    expect(backwards.first?.cpuPercent == 0, "a smaller CPU time gives 0, not a negative value")
    let first = AppRanking.usage(previous: [], current: cur, seconds: 10, ignore: [])
    expect(first.allSatisfy { $0.cpuPercent == nil } && first.contains { $0.memoryBytes != nil }, "the first scan has memory but no CPU")
    expect(AppRanking.usage(previous: prev, current: cur, seconds: 0, ignore: []).allSatisfy { $0.cpuPercent == nil }, "zero seconds gives no CPU")
    expect(AppRanking.isIgnored("XProtectService", ignore: AppRanking.defaultIgnore) && AppRanking.isIgnored("mdworker", ignore: AppRanking.defaultIgnore)
           && !AppRanking.isIgnored("MoleMonitor", ignore: AppRanking.defaultIgnore), "the ignore list matches by name prefix and keeps MoleMonitor")

    let topCPU = AppRanking.top(usage, by: .cpu)
    expect(topCPU.map { $0.key } == ["com.example.render", "proc:NewTool", "com.example.mail"], "CPU order, rows below both minimums left out: \(topCPU.map { $0.key })")
    let topMem = AppRanking.top(usage, by: .memory)
    expect(topMem.first?.key == "com.example.render" && topMem.map { $0.key }.contains("proc:idle") == false, "memory order")
    expect(AppRanking.top(usage, by: .cpu, count: 1).count == 1, "count limits the rows")
    let tie = [AppUsage(key: "b", name: "B", bundleID: nil, cpuPercent: 5, memoryBytes: 100_000_000, memoryBasis: "footprint", processCount: 1, isSystem: false),
               AppUsage(key: "a", name: "A", bundleID: nil, cpuPercent: 5, memoryBytes: 100_000_000, memoryBasis: "footprint", processCount: 1, isSystem: false)]
    expect(AppRanking.top(tie, by: .cpu).map { $0.key } == ["a", "b"], "equal rows sort by name")

    section("AppCPUTracker")
    func scan(_ cpu: Double, key: String = "com.example.render") -> [AppUsage] {
        [AppUsage(key: key, name: "Render", bundleID: key, cpuPercent: cpu, memoryBytes: nil, memoryBasis: "footprint", processCount: 1, isSystem: false)]
    }
    var tracker = AppCPUTracker()
    for i in 0..<10 { tracker.add(at: now.addingTimeInterval(Double(i) * 60), seconds: 60, usage: scan(95)) }
    let t10 = now.addingTimeInterval(9 * 60)
    var stats = tracker.stats(now: t10)
    expect(stats.count == 1 && stats[0].mean30m == nil, "10 minutes of scans cannot give a 30 minute mean")
    expect(stats.first?.mean10m != nil && abs((stats.first?.mean10m ?? 0) - 95) < 0.01, "10 minute mean is 95 %")
    expect(tracker.hasCoverage(now: t10), "10 minutes of scans cover the 10 minute window")
    for i in 10..<35 { tracker.add(at: now.addingTimeInterval(Double(i) * 60), seconds: 60, usage: scan(95)) }
    stats = tracker.stats(now: now.addingTimeInterval(34 * 60))
    expect(abs((stats.first?.mean30m ?? 0) - 95) < 0.01, "30 minute mean after 35 minutes is 95 %, got \(String(describing: stats.first?.mean30m))")
    for i in 35..<45 { tracker.add(at: now.addingTimeInterval(Double(i) * 60), seconds: 60, usage: scan(5)) }
    stats = tracker.stats(now: now.addingTimeInterval(44 * 60))
    expect((stats.first?.mean10m ?? 100) < 50, "10 minute mean drops below 50 % after a calm period")
    expect((stats.first?.mean30m ?? 0) > 60 && (stats.first?.mean30m ?? 100) < 80, "30 minute mean falls slowly")
    var sleepy = AppCPUTracker()
    sleepy.add(at: now, seconds: 60, usage: scan(95))
    sleepy.add(at: now.addingTimeInterval(7200), seconds: 7200, usage: scan(1))
    expect(!sleepy.hasCoverage(now: now.addingTimeInterval(7200)), "an interval longer than 10 minutes is a sleep and is not counted")
    var memory = AppCPUTracker()
    for i in 0..<500 { memory.add(at: now.addingTimeInterval(Double(i) * 4), seconds: 4, usage: scan(50)) }
    expect(memory.stats(now: now.addingTimeInterval(1996)).count == 1, "many 4 second scans stay in few buckets")
    memory.reset()
    expect(memory.stats(now: now).isEmpty && !memory.hasCoverage(now: now), "reset clears the tracker")
}

/// Old trend data has no pressure percent: it decodes as nil (not measured), never as 0.
func runTrendCompatTests() {
    section("TrendPoint pressure percent compatibility")
    let old = Data(#"{"t":0,"cpu":12.5}"#.utf8)
    let dec = JSONDecoder()
    let p = try? dec.decode(TrendPoint.self, from: old)
    expect(p != nil && p?.pressurePercent == nil, "a point without pp decodes with nil pressure percent")
    var q = TrendPoint(t: now)
    q.pressurePercent = 23
    let json = String(data: (try? JSONEncoder().encode(q)) ?? Data(), encoding: .utf8) ?? ""
    expect(json.contains("\"pp\":23"), "the JSON key is pp")
}
