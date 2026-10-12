// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for RollupStore, EventLog, EventTracker and AppDiskWriteTracker (docs/DESIGN_V2.md 12.2 D1, D2, 6.4; W19).
// Pos: Called from main.swift via runStorageTests(); no top-level code in this file. Owner WP-A.

import Foundation

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mm-storage-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max))")
    try? FileManager.default.removeItem(at: url)
    return url
}

private func perm(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func pt(_ t: Date, cpu: Double? = nil, pp: Int? = nil, swap: Int64? = nil, rx: Double? = nil) -> TrendPoint {
    var p = TrendPoint(t: t)
    p.cpu = cpu
    p.pressurePercent = pp
    p.swapUsed = swap
    p.rx = rx
    return p
}

func runStorageTests() {
    section("StorageTests: aggregation")
    let end = RollupAggregator.windowEnd(containing: now.addingTimeInterval(-100))
    expect(end.timeIntervalSince1970.truncatingRemainder(dividingBy: 300) == 0 && end <= now, "window ends are on the 5 minute grid")
    expect(RollupAggregator.windowEnd(containing: end) == end, "a time on the grid is its own window end")
    let inside = [pt(end.addingTimeInterval(-30), cpu: 10, pp: 20, swap: 3_000_000_000, rx: 2000),
                  pt(end.addingTimeInterval(-60), cpu: 30, pp: 40, swap: 2_000_000_000, rx: 4000),
                  pt(end.addingTimeInterval(-300), cpu: 99),      // On the start edge: outside.
                  pt(end.addingTimeInterval(30), cpu: 99)]        // After the end: outside.
    let w = RollupAggregator.window(points: inside, end: end)
    expect(w?.pointCount == 2, "points inside (end-300, end] only: \(String(describing: w?.pointCount))")
    expect(w?.cpuMean == 20 && w?.cpuPeak == 30, "cpu mean and peak")
    expect(w?.pressureMean == 30 && w?.pressurePeak == 40, "pressure mean and peak")
    expect(w?.swapMB == 3000, "swap takes the last value in decimal MB")
    expect(w?.rxKBps == 3, "rx in KB/s")
    expect(w?.batteryPercent == nil && w?.thermal == nil, "unmeasured fields stay nil")
    expect(RollupAggregator.window(points: [pt(end.addingTimeInterval(-1000), cpu: 5)], end: end) == nil, "no point in the window: no window")
    let zero = RollupAggregator.window(points: [pt(end.addingTimeInterval(-10), cpu: 0, swap: 0)], end: end)
    expect(zero?.cpuMean == 0 && zero?.swapMB == 0, "a measured zero stays 0")

    section("StorageTests: RollupStore files")
    let dir = tempDir("rollup")
    defer { try? FileManager.default.removeItem(at: dir) }
    expect(RollupStore.read(dir: dir, from: now.addingTimeInterval(-3600), to: now) == RollupReadResult.empty, "read of a missing directory is empty")
    var all = [RollupWindow]()
    for k in 0..<6 {
        var win = RollupWindow(end: end.addingTimeInterval(-Double(k) * 300), pointCount: 10)
        win.cpuMean = Double(k) * 10; win.cpuPeak = Double(k) * 10 + 5
        if k != 3 { win.pressureMean = 22; win.pressurePeak = 40 }
        if k == 0 { win.swapMB = 0; win.pressure = .warning; win.thermal = .fair; win.batteryPercent = 61; win.power = .battery; win.rxKBps = 0; win.txKBps = 1.5 }
        all.append(win)
    }
    for win in all.reversed() { _ = try? RollupStore.append(win, dir: dir) }
    let file = dir.appendingPathComponent(RollupStore.fileName(for: end))
    expect(perm(file) == 0o600, "rollup file mode is 0600 (got \(String(perm(file), radix: 8)))")
    expect(perm(dir) == 0o700, "rollup directory mode is 0700 (got \(String(perm(dir), radix: 8)))")
    let back = RollupStore.read(dir: dir, from: end.addingTimeInterval(-3600), to: end)
    expect(back.windows.count == 6 && back.skippedLines == 0, "six windows read back")
    expect(back.windows.map { $0.end } == all.reversed().map { $0.end }, "windows come back ascending")
    let first = back.windows.last
    expect(first?.swapMB == 0 && first?.rxKBps == 0 && first?.txKBps == 1.5, "zero values survive the round trip as 0")
    expect(first?.pressure == .warning && first?.thermal == .fair && first?.power == .battery && first?.batteryPercent == 61, "levels survive the round trip")
    expect(back.windows.first { $0.pressureMean == nil } != nil && back.windows.first?.swapMB == nil, "missing values stay missing, not 0")
    // Duplicate end time: the later line wins and there is one window.
    var dup = all[0]; dup.cpuMean = 77; dup.cpuPeak = 80
    _ = try? RollupStore.append(dup, dir: dir)
    let again = RollupStore.read(dir: dir, from: end.addingTimeInterval(-3600), to: end)
    expect(again.windows.count == 6 && again.windows.last?.cpuMean == 77, "one window per end time, the later line wins")
    // Range filter.
    expect(RollupStore.read(dir: dir, from: end.addingTimeInterval(-600), to: end).windows.count == 3, "from and to filter by the end time")
    expect(RollupStore.read(dir: dir, from: end, to: end.addingTimeInterval(-1)) == RollupReadResult.empty, "from after to is empty")
    // Damaged lines are skipped and counted; the rest survives.
    if let h = try? FileHandle(forWritingTo: file) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("not json\n{\"v\":1,\"t\":\"bad\",\"n\":3}\n{\"v\":9,\"t\":\"\(UTCTime.iso(end))\",\"n\":3}\n{\"v\":1,\"t\":\"\(UTCTime.iso(end.addingTimeInterval(-1800)))\",\"n\":4,\"cpu\":\"x\",\"pp\":[1,200],\"sw\":-5}\n{\"v\":1,\"t\":\"\(UTCTime.iso(end))\"".utf8))
        try? h.close()
    }
    let damaged = RollupStore.read(dir: dir, from: end.addingTimeInterval(-3600), to: end)
    expect(damaged.skippedLines >= 4, "damaged lines are counted: \(damaged.skippedLines)")
    expect(damaged.windows.count == 7, "bad fields become missing, good lines stay (\(damaged.windows.count))")
    let weird = damaged.windows.first { $0.end == end.addingTimeInterval(-1800) }
    expect(weird != nil && weird?.cpuMean == nil && weird?.pressureMean == nil && weird?.swapMB == nil, "wrong types and out of range values become missing")
    // A partial last line does not glue to the next line.
    let rest = (try? RollupStore.append(all[1], dir: dir)) ?? false
    expect(rest, "append after a partial line works")
    expect(RollupStore.read(dir: dir, from: end.addingTimeInterval(-3600), to: end).windows.count == 7, "the new line after a partial line is readable")
    // Size limit.
    let big = tempDir("big")
    defer { try? FileManager.default.removeItem(at: big) }
    try? FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
    let bigFile = big.appendingPathComponent(RollupStore.fileName(for: end))
    FileManager.default.createFile(atPath: bigFile.path, contents: Data(repeating: 10, count: RollupStore.maxFileBytes - 10), attributes: [.posixPermissions: 0o600])
    let accepted = (try? RollupStore.append(all[0], dir: big)) ?? true
    expect(accepted == false, "a file over the size limit takes no more lines")
    expect(((try? FileManager.default.attributesOfItem(atPath: bigFile.path))?[.size] as? NSNumber)?.intValue == RollupStore.maxFileBytes - 10, "the full file is not changed")
    // Pruning keeps this month and last month.
    let pr = tempDir("prune")
    defer { try? FileManager.default.removeItem(at: pr) }
    try? FileManager.default.createDirectory(at: pr, withIntermediateDirectories: true)
    for name in ["rollup-2026-10.ndjson", "rollup-2026-09.ndjson", "rollup-2026-08.ndjson", "rollup-2025-12.ndjson", "other.txt"] {
        FileManager.default.createFile(atPath: pr.appendingPathComponent(name).path, contents: Data("x".utf8))
    }
    RollupStore.prune(dir: pr, now: now)
    let left = ((try? FileManager.default.contentsOfDirectory(atPath: pr.path)) ?? []).sorted()
    expect(left == ["other.txt", "rollup-2026-09.ndjson", "rollup-2026-10.ndjson"], "prune keeps two months and foreign files: \(left)")
    // Line format.
    let line = RollupStore.encodeLine(all[0])
    expect(line.hasPrefix("{\"v\":1,\"t\":\"") && !line.contains("\n") && line.contains("\"sw\":0") && line.contains("\"rx\":0"), "line format: \(line)")
    expect(!RollupStore.encodeLine(all[3]).contains("\"pp\""), "a missing value leaves its key out")
    expect(RollupStore.parseLine(line) == all[0], "encode and parse are inverse")
    expect(RollupStore.recordedHours(back) > 0, "recorded hours count the points")

    section("StorageTests: EventLog files")
    let edir = tempDir("events")
    defer { try? FileManager.default.removeItem(at: edir) }
    expect(EventLog.read(dir: edir, days: 7, now: now).isEmpty, "event read of a missing directory is empty")
    func rec(_ item: HealthItem, _ peak: HealthLevel, daysAgo: Double, hours: Double? = 1) -> EventRecord {
        let s = now.addingTimeInterval(-daysAgo * 86400)
        return EventRecord(item: item, first: .yellow, peak: peak, reasonCode: "x", start: s,
                           end: hours.map { s.addingTimeInterval($0 * 3600) }, peakValue: 87, unit: "%", app: nil, endEstimated: false)
    }
    var records = [rec(.cpu, .yellow, daysAgo: 1), rec(.memory, .red, daysAgo: 0.1, hours: nil), rec(.disk, .red, daysAgo: 20), rec(.power, .yellow, daysAgo: 40)]
    records[0].app = "Xcode"
    records[0].endEstimated = true
    records[1].peakValue = nil
    records[1].unit = nil
    try? EventLog.write(records, dir: edir, now: now)
    let efile = edir.appendingPathComponent(EventLog.fileName)
    expect(perm(efile) == 0o600, "events.json mode is 0600 (got \(String(perm(efile), radix: 8)))")
    let e7 = EventLog.read(dir: edir, days: 7, now: now)
    expect(e7.map { $0.item } == [.memory, .cpu], "7 days, newest first: \(e7.map { $0.item.rawValue })")
    expect(e7.first?.end == nil && e7.first?.peakValue == nil && e7.first?.unit == nil, "an open record and null fields round trip")
    expect(e7.last?.app == "Xcode" && e7.last?.endEstimated == true && e7.last?.peakValue == 87, "app, estimate flag and value round trip")
    expect(EventLog.read(dir: edir, days: 30, now: now).count == 3, "30 days adds the 20 day old record")
    expect(EventLog.readAll(dir: edir).records.count == 3, "records older than 30 days are dropped on write")
    // Damaged and foreign files.
    try? Data("not json".utf8).write(to: efile)
    expect(EventLog.read(dir: edir, days: 7, now: now).isEmpty, "a damaged events file reads as empty")
    try? Data("[{\"v\":1,\"item\":\"cpu\",\"first\":\"yellow\",\"peak\":\"red\",\"reason\":\"x\",\"start\":\"2026-10-11T10:00:00Z\",\"end\":null,\"peakValue\":null,\"unit\":null,\"app\":null,\"endEstimated\":false},{\"v\":1,\"item\":\"bogus\"},{\"v\":7,\"item\":\"cpu\"},5]".utf8).write(to: efile)
    let partial = EventLog.readAll(dir: edir)
    expect(partial.records.count == 1 && partial.skipped == 3, "bad records are skipped one by one (\(partial.records.count), \(partial.skipped))")
    // Limits: 200 records, 50 KB.
    var many = [EventRecord]()
    for k in 0..<400 { var r = rec(.cpu, .yellow, daysAgo: 0.01 * Double(k) / 10); r.app = String(repeating: "A", count: 40); many.append(r) }
    let limited = EventLog.limited(many, now: now)
    expect(limited.count <= 200, "at most 200 records (\(limited.count))")
    try? EventLog.write(many, dir: edir, now: now)
    let size = ((try? FileManager.default.attributesOfItem(atPath: efile.path))?[.size] as? NSNumber)?.intValue ?? 0
    expect(size <= 50 * 1024, "events.json stays within 50 KB (\(size))")

    section("StorageTests: EventTracker")
    let t0 = now
    func verdict(_ item: HealthItem, _ level: HealthLevel, since: Date? = nil, reason: String = "cpu_mean_5m") -> ItemVerdict {
        ItemVerdict(item: item, level: level, reasonCode: reason, headline: "", since: since, levelChangedAt: nil, alert: nil)
    }
    var cur = CurrentReadings()
    cur.cpuMean5m = 74
    var tr = EventTracker(records: [], previousStatusAt: nil)
    expect(tr.observe(verdicts: [verdict(.cpu, .green)], current: cur, diskGrowth: [:], appNames: [:], now: t0) == false && tr.records.isEmpty, "green opens nothing")
    expect(tr.observe(verdicts: [verdict(.cpu, .yellow, since: t0.addingTimeInterval(-600))], current: cur, diskGrowth: [:], appNames: [.cpu: "Xcode"], now: t0), "yellow opens a record")
    expect(tr.records.count == 1 && tr.records[0].start == t0.addingTimeInterval(-600) && tr.records[0].end == nil && tr.records[0].app == "Xcode", "start = since, open, app name")
    expect(tr.records[0].peakValue == 74 && tr.records[0].unit == "%", "peak value from the readings")
    cur.cpuMean5m = 95
    expect(tr.observe(verdicts: [verdict(.cpu, .red)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(30)), "a worse level changes the record")
    expect(tr.records[0].peak == .red && tr.records[0].first == .yellow && tr.records.count == 1, "peak is red, first stays yellow, one record")
    expect(tr.observe(verdicts: [verdict(.cpu, .yellow)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(60)) == false && tr.records[0].peak == .red, "a lower level keeps the peak")
    expect(tr.observe(verdicts: [verdict(.cpu, .unknown)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(90)) == false && tr.records[0].end == nil, "unknown does not close")
    expect(tr.observe(verdicts: [verdict(.cpu, .stale)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(95)) == false && tr.records[0].end == nil, "stale does not close")
    expect(tr.observe(verdicts: [verdict(.cpu, .green)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(120)), "green closes")
    expect(tr.records[0].end == t0.addingTimeInterval(120) && !tr.records[0].endEstimated, "end = now, not estimated")
    expect(tr.observe(verdicts: [verdict(.cpu, .yellow)], current: cur, diskGrowth: [:], appNames: [:], now: t0.addingTimeInterval(150)) && tr.records.count == 2, "a new stretch is a new record")
    // Restart: an open record from the last run is closed with the last status time, marked as an estimate.
    let open = EventRecord(item: .memory, first: .red, peak: .red, reasonCode: "pressure_critical", start: t0.addingTimeInterval(-7200),
                           end: nil, peakValue: 90, unit: "%", app: nil, endEstimated: false)
    var restart = EventTracker(records: [open], previousStatusAt: t0.addingTimeInterval(-3600))
    expect(restart.observe(verdicts: [verdict(.memory, .green)], current: CurrentReadings(), diskGrowth: [:], appNames: [:], now: t0), "restart closes the old record")
    expect(restart.records[0].end == t0.addingTimeInterval(-3600) && restart.records[0].endEstimated, "end is the last status time and marked estimated")
    var still = EventTracker(records: [open], previousStatusAt: t0.addingTimeInterval(-3600))
    expect(still.observe(verdicts: [verdict(.memory, .red, reason: "pressure_critical")], current: CurrentReadings(), diskGrowth: [:], appNames: [:], now: t0) == false
           && still.records[0].end == nil, "the same problem after a restart continues the open record")
    var evCur = CurrentReadings()
    evCur.memoryPressurePercent = 91
    evCur.diskAvailable = 120_000_000_000
    evCur.swapUsed = 9_800_000_000
    expect(EventTracker.evidence(for: verdict(.memory, .red, reason: "pressure_critical"), current: evCur, diskGrowth: [:]).value == 91, "memory evidence is the pressure percent")
    expect(EventTracker.evidence(for: verdict(.memory, .yellow, reason: "swap_high"), current: evCur, diskGrowth: [:]).unit == "GB", "swap evidence is in GB")
    expect(EventTracker.evidence(for: verdict(.disk, .red, reason: "growth_5d"), current: evCur, diskGrowth: ["5d": 314_000_000_000]).value == 314, "disk growth evidence")
    expect(EventTracker.evidence(for: verdict(.thermal, .yellow, reason: "t"), current: evCur, diskGrowth: [:]).value == nil, "thermal has no value")

    section("StorageTests: disk write tracking")
    func sample(_ pid: Int32, _ name: String, written: UInt64?, start: UInt64 = 1) -> ProcessSample {
        ProcessSample(pid: pid, startAbs: start, name: name, appKey: "proc:" + name, displayName: name, bundleID: nil, cpuTimeNs: 0,
                      footprint: nil, rss: nil, isSystem: false, diskWritten: written)
    }
    let prev = [sample(1, "A", written: 1_000), sample(2, "B", written: 5_000)]
    let curr = [sample(1, "A", written: 3_000_001_000), sample(2, "B", written: 1_000), sample(3, "C", written: 700)]
    let usage = AppRanking.usage(previous: prev, current: curr, seconds: 30, ignore: [])
    func written(_ name: String) -> Int64? { usage.first { $0.name == name }?.diskWrittenBytes }
    expect(written("A") == 3_000_000_000, "written bytes are the difference")
    expect(written("B") == 0, "a counter that went down counts 0")
    expect(written("C") == 700, "a new process counts all its bytes")
    let noPrev = AppRanking.usage(previous: [sample(1, "A", written: nil)], current: [sample(1, "A", written: 9_000)], seconds: 30, ignore: [])
    expect(noPrev.first?.diskWrittenBytes == nil, "no earlier disk data: nil, not a huge number")
    var tracker = AppDiskWriteTracker()
    func app(_ key: String, _ bytes: Int64) -> AppUsage {
        AppUsage(key: key, name: key, bundleID: nil, cpuPercent: 0, memoryBytes: 0, memoryBasis: "rss", processCount: 1, isSystem: false, diskWrittenBytes: bytes)
    }
    tracker.add(at: now.addingTimeInterval(-120), seconds: 30, usage: [app("Big", 600_000_000), app("Small", 400_000)])
    tracker.add(at: now.addingTimeInterval(-60), seconds: 30, usage: [app("Big", 700_000_000), app("Mid", 900_000)])
    tracker.add(at: now.addingTimeInterval(-30), seconds: 30, usage: [app("Mid", 900_000)])
    let top = tracker.top(now: now)
    expect(top.map { $0.name } == ["Big", "Mid"] && top.first?.bytes == 1_300_000_000, "top writers in the window: \(top)")
    expect(!top.contains { $0.name == "Small" }, "a writer below 1 MB is not shown")
    expect(tracker.top(now: now.addingTimeInterval(400)).isEmpty, "entries older than 5 minutes leave the window")
    tracker.add(at: now.addingTimeInterval(1000), seconds: 900, usage: [app("Sleepy", 9_000_000_000)])
    expect(!tracker.top(now: now.addingTimeInterval(1000)).contains { $0.name == "Sleepy" }, "a gap over 10 minutes (sleep) is not counted")
    tracker.reset()
    expect(tracker.top(now: now).isEmpty, "reset clears the window")
}
