// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Sources/Core/*.swift compiled into the same module (see scripts/test_core.py).
// Output: Pass/fail summary on stdout; exit code 1 when any assertion fails.
// Pos: Self-contained tests for the Foundation-only Core logic; no XCTest.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Mini framework

var passed = 0
var failed = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func section(_ name: String) { print("== \(name)") }

// MARK: - Fixtures

let GB: Int64 = 1_000_000_000
let now = UTCTime.parseISO("2026-10-11T12:00:00Z")!

func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

/// One ok sample: `used` in GB, availImportant = total - used.
func sample(_ hoursAgo: Double, usedGB: Int64, totalGB: Int64 = 1000, bootAt: Date? = nil,
            rx: Int64? = nil, tx: Int64? = nil) -> DiskSample {
    DiskSample(t: ago(hoursAgo), total: totalGB * GB, availImportant: (totalGB - usedGB) * GB,
               avail: (totalGB - usedGB) * GB - 5 * GB, netRx: rx, netTx: tx, boot: bootAt)
}

func failedSample(_ hoursAgo: Double) -> DiskSample {
    DiskSample(t: ago(hoursAgo), src: .timer, ok: false, err: "read failed")
}

/// Steady series: 100 GB used 5 days ago, then `100 + x` GB from 30 h ago until now.
func growthSeries(_ x: Int64, totalGB: Int64 = 1000, base: Int64 = 100) -> [DiskSample] {
    [sample(120, usedGB: base, totalGB: totalGB), sample(30, usedGB: base + x, totalGB: totalGB),
     sample(12, usedGB: base + x, totalGB: totalGB), sample(0, usedGB: base + x, totalGB: totalGB)]
}

func flatSeries(_ usedGB: Int64, totalGB: Int64 = 1000) -> [DiskSample] {
    [sample(120, usedGB: usedGB, totalGB: totalGB), sample(0, usedGB: usedGB, totalGB: totalGB)]
}

func eval(_ s: [DiskSample], prev: HealthLevel = .green) -> DiskVerdict {
    DiskHealth.evaluate(samples: s, now: now, previous: prev, thresholds: DiskThresholds())
}

func mode(_ url: URL) -> Int {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return -1 }
    return Int(st.st_mode & 0o777)
}

func jsonObject(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("molemonitor-core-test-" + UUID().uuidString)
try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
func freshDir(_ name: String) -> URL { tmpRoot.appendingPathComponent(name, isDirectory: true) }

// MARK: - Time helpers

section("UTCTime")
expect(UTCTime.iso(now) == "2026-10-11T12:00:00Z", "iso format")
expect(UTCTime.parseISO("2026-10-11T12:00:00Z") == now, "parse Z")
expect(UTCTime.parseISO("2026-10-11T21:00:00+09:00") == now, "parse offset")
expect(UTCTime.parseISO("2026-10-11T12:00:00.500Z") == now.addingTimeInterval(0.5), "parse fraction")
expect(UTCTime.parseISO("2026-13-11T12:00:00Z") == nil, "bad month")
expect(UTCTime.parseISO("garbage") == nil, "garbage date")
expect(UTCTime.parseISO("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1), "before epoch")
expect(UTCTime.iso(Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59Z", "iso before epoch")
expect(UTCTime.parseISO("2024-02-29T00:00:00Z").map(UTCTime.iso) == "2024-02-29T00:00:00Z", "leap day round trip")
expect(DiskHistory.fileName(for: now) == "disk-2026-10.ndjson", "file name by UTC month")
expect(DiskHistory.fileName(for: UTCTime.parseISO("2026-09-30T23:59:59Z")!) == "disk-2026-09.ndjson", "month edge")

// MARK: - DiskSample

section("DiskSample")
let exampleLine = "{\"v\":1,\"t\":\"2026-10-11T08:15:00Z\",\"src\":\"timer\",\"ok\":true,\"vol\":\"/System/Volumes/Data\",\"total\":994662584320,\"avail_important\":412310421504,\"avail\":398123450368,\"used\":582352162816,\"net_rx\":812345678901,\"net_tx\":123456789012,\"boot\":\"2026-10-08T01:02:03Z\"}"
do {
    let decoded = try CoreJSON.decoder().decode(DiskSample.self, from: Data(exampleLine.utf8))
    expect(decoded.total == 994662584320 && decoded.availImportant == 412310421504, "example numbers")
    expect(decoded.netRx == 812345678901 && decoded.netTx == 123456789012, "example net counters")
    expect(decoded.src == .timer && decoded.vol == "/System/Volumes/Data", "example src and vol")
    expect(decoded.boot == UTCTime.parseISO("2026-10-08T01:02:03Z"), "example boot")
    expect(decoded.realUsed == 994662584320 - 412310421504, "realUsed = total - availImportant")
    let encoded = try CoreJSON.encoder().encode(decoded)
    expect(jsonObject(encoded) == jsonObject(Data(exampleLine.utf8)), "round trip equals PROJECT.md example")
    let text = String(decoding: encoded, as: UTF8.self)
    expect(text.contains("\"avail_important\":412310421504") && text.contains("\"net_rx\"") && text.contains("\"net_tx\""), "snake_case keys")
    expect(text.contains("\"vol\":\"/System/Volumes/Data\""), "slashes are not escaped")
    expect(!text.contains("err"), "nil err is omitted")
} catch {
    expect(false, "example decode failed: \(error)")
}
do {
    let failLine = "{\"v\":1,\"t\":\"2026-10-11T08:30:00Z\",\"src\":\"launch\",\"ok\":false,\"vol\":\"/System/Volumes/Data\",\"err\":\"read failed\"}"
    let f = try CoreJSON.decoder().decode(DiskSample.self, from: Data(failLine.utf8))
    expect(!f.ok && f.err == "read failed" && f.total == nil && f.realUsed == nil, "ok=false row has no numbers")
    expect(f.src == .launch, "launch source")
    let back = String(decoding: try CoreJSON.encoder().encode(f), as: UTF8.self)
    expect(!back.contains("\"total\"") && back.contains("\"err\":\"read failed\""), "ok=false row encodes without total")
} catch {
    expect(false, "ok=false decode failed: \(error)")
}
expect(DiskSample(t: now, ok: true, total: 100, availImportant: 200).realUsed == nil, "avail > total is not trusted")
expect(DiskSample(t: now, ok: false, total: 100, availImportant: 10).realUsed == nil, "ok=false never gives realUsed")
expect(DiskSample(t: now, total: 100, availImportant: nil).realUsed == nil, "missing availImportant gives nil")

// MARK: - DiskHistory

section("DiskHistory")
do {
    let lines = [exampleLine, "not json", "", "{\"v\":1}", "   ",
                 "{\"v\":2,\"t\":\"2026-10-11T08:15:00Z\",\"ok\":true}",
                 "{\"v\":1,\"t\":\"2026-10-11T08:20:00Z\",\"ok\":true,\"total\":\"abc\"}"]
    let r = DiskHistory.parse(lines: lines)
    expect(r.samples.count == 2, "parse keeps 2 valid lines (got \(r.samples.count))")
    expect(r.corrupt == 3, "parse counts 3 corrupt lines (got \(r.corrupt))")
    expect(r.samples.last?.total == nil, "wrong-typed field becomes nil, not 0")
}
do {
    let dir = freshDir("history/nested")
    let sepDay = UTCTime.parseISO("2026-09-28T10:00:00Z")!
    let octDay = UTCTime.parseISO("2026-10-05T10:00:00Z")!
    let oldDay = UTCTime.parseISO("2026-09-01T10:00:00Z")!
    // Append out of order on purpose.
    try DiskHistory.append(DiskSample(t: octDay, total: 10 * GB, availImportant: 5 * GB), dir: dir)
    try DiskHistory.append(DiskSample(t: oldDay, total: 10 * GB, availImportant: 5 * GB), dir: dir)
    try DiskHistory.append(DiskSample(t: sepDay, total: 10 * GB, availImportant: 6 * GB), dir: dir)
    try DiskHistory.append(DiskSample(t: ago(1), total: 10 * GB, availImportant: 4 * GB), dir: dir)
    expect(mode(dir) == 0o700, "new directory is 0700 (got \(String(mode(dir), radix: 8)))")
    let sepFile = dir.appendingPathComponent("disk-2026-09.ndjson")
    let octFile = dir.appendingPathComponent("disk-2026-10.ndjson")
    expect(mode(sepFile) == 0o600 && mode(octFile) == 0o600, "new files are 0600")
    let loaded = DiskHistory.load(dir: dir, now: now, days: 35)
    expect(loaded.samples.count == 3, "35-day load drops the 2026-09-01 sample (got \(loaded.samples.count))")
    expect(loaded.samples.map { $0.t } == [sepDay, octDay, ago(1)], "cross-month load sorted ascending")
    expect(loaded.corrupt == 0, "no corrupt lines yet")
    // A crashed write leaves a partial line without newline; the next append must stay readable.
    let h = try FileHandle(forWritingTo: octFile)
    try h.seekToEnd()
    try h.write(contentsOf: Data("{\"v\":1,\"t\":\"2026-10-".utf8))
    try h.close()
    try DiskHistory.append(DiskSample(t: ago(0.5), total: 10 * GB, availImportant: 3 * GB), dir: dir)
    let again = DiskHistory.load(dir: dir, now: now, days: 35)
    expect(again.samples.count == 4 && again.corrupt == 1, "partial line is isolated and counted (got \(again.samples.count)/\(again.corrupt))")
    expect(DiskHistory.load(dir: dir, now: now, days: 1).samples.count == 2, "1-day load keeps last day only")
    expect(DiskHistory.load(dir: freshDir("missing"), now: now, days: 35).samples.isEmpty, "missing dir loads empty")
} catch {
    expect(false, "history test threw: \(error)")
}
do {
    let dir = freshDir("prune")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in ["disk-2026-07.ndjson", "disk-2026-08.ndjson", "disk-2026-09.ndjson", "disk-2026-10.ndjson", "other.txt", "disk-xx.ndjson"] {
        _ = FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8))
    }
    DiskHistory.prune(dir: dir, now: now)
    let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    expect(left == ["disk-2026-09.ndjson", "disk-2026-10.ndjson", "other.txt", "disk-xx.ndjson"], "prune keeps last 2 months only (left: \(left.sorted()))")
    let jan = UTCTime.parseISO("2027-01-15T00:00:00Z")!
    DiskHistory.prune(dir: dir, now: jan)
    let left2 = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    expect(!left2.contains("disk-2026-09.ndjson") && !left2.contains("disk-2026-10.ndjson"), "year wrap: prune in January 2027 removes 2026-09 and 2026-10")
} catch {
    expect(false, "prune test threw: \(error)")
}

// MARK: - DiskGrowth

section("DiskGrowth")
do {
    let g = DiskGrowth.compute(samples: [sample(120, usedGB: 200), sample(72, usedGB: 150), sample(0, usedGB: 450)], now: now, window: .day5)
    expect(g.bytes == 300 * GB, "growth is current - window minimum = 300 GB (got \(String(describing: g.bytes)))")
    expect(g.netBytes == 250 * GB, "net change is +250 GB")
    expect(g.fromMinAt == ago(72), "fromMinAt is the minimum sample time")
    expect(g.status == .ok && g.coveredHours == 120, "full coverage is ok")
    let text = String(decoding: try CoreJSON.encoder().encode(g), as: UTF8.self)
    expect(text.contains("\"net_bytes\":250000000000") && text.contains("\"from_min_at\":\"") && text.contains("\"covered_hours\":120"), "growth JSON keys")
}
do {
    let g = DiskGrowth.compute(samples: [sample(60, usedGB: 100), sample(0, usedGB: 150)], now: now, window: .day5)
    expect(g.bytes == 50 * GB && g.status == .insufficientWindow, "low coverage still reports bytes as a lower bound")
    expect(g.coveredHours == 60, "covered hours 60")
    let edge = DiskGrowth.compute(samples: [sample(108, usedGB: 100), sample(0, usedGB: 150)], now: now, window: .day5)
    expect(edge.status == .ok, "108 h of 120 h (90%) is ok")
    let under = DiskGrowth.compute(samples: [sample(107, usedGB: 100), sample(0, usedGB: 150)], now: now, window: .day5)
    expect(under.status == .insufficientWindow, "107 h of 120 h is insufficient")
}
do {
    let none = DiskGrowth.compute(samples: [], now: now, window: .day1)
    expect(none.bytes == nil && none.netBytes == nil && none.status == .collecting, "no samples -> collecting")
    let one = DiskGrowth.compute(samples: [sample(2, usedGB: 100)], now: now, window: .day1)
    expect(one.bytes == nil && one.status == .insufficientWindow && one.coveredHours == 2, "one sample -> insufficient, no bytes")
    let text = String(decoding: try CoreJSON.encoder().encode(none), as: UTF8.self)
    expect(text.contains("\"bytes\":null") && text.contains("\"from_min_at\":null"), "nil growth fields are written as null")
    let outside = DiskGrowth.compute(samples: [sample(30, usedGB: 100), sample(0, usedGB: 200)], now: now, window: .day1)
    expect(outside.bytes == nil, "sample older than window is ignored")
}
do {
    // The failed read must not count as 0 and become the minimum.
    let g = DiskGrowth.compute(samples: [sample(120, usedGB: 200), failedSample(60), sample(0, usedGB: 300)], now: now, window: .day5)
    expect(g.bytes == 100 * GB && g.netBytes == 100 * GB, "ok=false rows are skipped")
    // Snapshot: avail drops, availImportant stays -> real used stays.
    var a = sample(120, usedGB: 200), b = sample(0, usedGB: 200)
    a.avail = 790 * GB; b.avail = 400 * GB
    let snap = DiskGrowth.compute(samples: [a, b], now: now, window: .day5)
    expect(snap.bytes == 0 && snap.netBytes == 0 && snap.status == .ok, "snapshot growth does not change real used")
    expect(a.realUsed == b.realUsed, "realUsed ignores avail")
    let future = DiskGrowth.compute(samples: [sample(120, usedGB: 200), sample(-2, usedGB: 900), sample(0, usedGB: 210)], now: now, window: .day5)
    expect(future.bytes == 10 * GB, "samples after now are ignored")
}

// MARK: - TrafficTotals

section("TrafficTotals")
do {
    let bootA = UTCTime.parseISO("2026-10-08T01:00:00Z")!
    let bootB = UTCTime.parseISO("2026-10-11T05:00:00Z")!
    let since = ago(24)
    let reboot = [sample(24, usedGB: 1, bootAt: bootA, rx: 100, tx: 10), sample(12, usedGB: 1, bootAt: bootA, rx: 200, tx: 20),
                  sample(6, usedGB: 1, bootAt: bootB, rx: 50, tx: 5), sample(0, usedGB: 1, bootAt: bootB, rx: 80, tx: 9)]
    let t = TrafficTotals.compute(samples: reboot, since: since, now: now)
    expect(t.rx == 130 && t.tx == 14, "boot change splits segments: rx 100+30, tx 10+4 (got \(String(describing: t.rx))/\(String(describing: t.tx)))")
    expect(t.status == .ok && t.coveredHours == 24, "full traffic coverage")
    let shrink = [sample(24, usedGB: 1, bootAt: bootA, rx: 100, tx: 10), sample(12, usedGB: 1, bootAt: bootA, rx: 90, tx: 12),
                  sample(0, usedGB: 1, bootAt: bootA, rx: 150, tx: 20)]
    let s2 = TrafficTotals.compute(samples: shrink, since: since, now: now)
    expect(s2.rx == 60 && s2.tx == 8, "smaller counter skips that pair (got \(String(describing: s2.rx))/\(String(describing: s2.tx)))")
    let missing = [sample(24, usedGB: 1, bootAt: bootA, rx: 100, tx: 10), sample(12, usedGB: 1, bootAt: bootA, rx: nil, tx: nil),
                   sample(0, usedGB: 1, bootAt: bootA, rx: 200, tx: 25)]
    let s3 = TrafficTotals.compute(samples: missing, since: since, now: now)
    expect(s3.rx == 100 && s3.tx == 15, "rows without counters are skipped")
    var bad = sample(12, usedGB: 1, bootAt: bootA, rx: 9_999_999, tx: 9_999_999)
    bad.ok = false
    let s4 = TrafficTotals.compute(samples: [missing[0], bad, missing[2]], since: since, now: now)
    expect(s4.rx == 100, "ok=false rows are skipped for traffic")
    let partial = TrafficTotals.compute(samples: [sample(6, usedGB: 1, bootAt: bootA, rx: 0, tx: 0), sample(0, usedGB: 1, bootAt: bootA, rx: 60, tx: 6)], since: since, now: now)
    expect(partial.rx == 60 && partial.status == .insufficientWindow, "short coverage keeps value with insufficient_window")
    let none = TrafficTotals.compute(samples: [], since: since, now: now)
    expect(none.rx == nil && none.status == .collecting, "no samples -> collecting")
    let one = TrafficTotals.compute(samples: [reboot[0]], since: since, now: now)
    expect(one.rx == nil && one.status == .insufficientWindow, "one sample -> no value")
    let onlyResets = TrafficTotals.compute(samples: [reboot[1], reboot[2]], since: since, now: now)
    expect(onlyResets.rx == nil && onlyResets.status == .insufficientWindow, "only reset pairs -> no value")
    let text = String(decoding: try CoreJSON.encoder().encode(none), as: UTF8.self)
    expect(text.contains("\"rx\":null") && text.contains("\"tx\":null"), "nil traffic written as null")
}

// MARK: - DiskHealth

section("DiskHealth")
do {
    let green = eval(growthSeries(10))
    expect(green.level == .green && green.reasonCode == "ok", "small growth is green")
    let y = eval(growthSeries(100), prev: .green)
    expect(y.level == .yellow && y.reasonCode == "growth_5d", "100 GB in 5 days on 1 TB is yellow")
    expect(y.reason == "5 天内真实已用增长 100 GB", "reason text: \(y.reason)")
    expect(y.triggerBytes == 100 * GB && y.triggerWindow == .day5 && y.growthLevel == .yellow && y.spaceLevel == .green, "yellow verdict details")
    let r = eval(growthSeries(250), prev: .yellow)
    expect(r.level == .red && r.reasonCode == "growth_5d", "250 GB in 5 days is red")
    let jump = eval(growthSeries(250), prev: .green)
    expect(jump.level == .red, "upgrade can jump from green to red")
    let d1 = eval([sample(20, usedGB: 100), sample(0, usedGB: 140)], prev: .green)
    expect(d1.level == .yellow && d1.reasonCode == "growth_1d", "40 GB in 1 day is yellow (threshold 30 GB on 1 TB)")
    let d1red = eval([sample(20, usedGB: 100), sample(0, usedGB: 190)], prev: .green)
    expect(d1red.level == .red && d1red.reasonCode == "growth_1d", "90 GB in 1 day is red (threshold 80 GB)")
    // PROJECT.md 3.5 example.
    let ex = eval([sample(120, usedGB: 200), sample(72, usedGB: 150), sample(0, usedGB: 450)])
    expect(ex.level == .red && ex.growth5d.bytes == 300 * GB && ex.growth5d.netBytes == 250 * GB, "3.5 example is red with growth 300 GB")
}
do {
    // Hysteresis.
    let hold = eval(growthSeries(150), prev: .red)
    expect(hold.level == .red && hold.reasonCode == "hold", "150 GB growth is above the red exit line (100 GB): stay red")
    let down = eval(growthSeries(90), prev: .red)
    expect(down.level == .yellow && down.reasonCode == "growth_5d", "90 GB growth below red exit: red -> yellow")
    let yHold = eval(growthSeries(50), prev: .yellow)
    expect(yHold.level == .yellow && yHold.reasonCode == "hold", "50 GB growth is above the yellow exit line (40 GB): stay yellow")
    let yExit = eval(growthSeries(30), prev: .yellow)
    expect(yExit.level == .green && yExit.reasonCode == "ok", "30 GB growth below yellow exit: yellow -> green")
    let step = eval(growthSeries(10), prev: .red)
    expect(step.level == .yellow && step.reasonCode == "recovering", "red falls one level per evaluation")
    expect(eval(growthSeries(10), prev: step.level).level == .green, "second evaluation reaches green")
    expect(eval(growthSeries(10), prev: .green).level == .green, "green stays green")
}
do {
    // Relative threshold: same 70 GB growth on two disk sizes.
    let small = eval(growthSeries(70, totalGB: 256, base: 50))
    expect(small.level == .yellow, "70 GB in 5 days on 256 GB disk: absolute 60 GiB applies -> yellow")
    let big = eval(growthSeries(70, totalGB: 2000, base: 100))
    expect(big.level == .green, "70 GB in 5 days on 2 TB disk: 8% = 160 GB applies -> green")
    let bigYellow = eval(growthSeries(170, totalGB: 2000, base: 100))
    expect(bigYellow.level == .yellow, "170 GB on 2 TB is yellow")
    let bigRed = eval(growthSeries(420, totalGB: 2000, base: 100))
    expect(bigRed.level == .red, "420 GB on 2 TB is red (20% = 400 GB)")
}
do {
    // Free space rules.
    let red = eval(flatSeries(960))
    expect(red.level == .red && red.reasonCode == "low_space" && red.spaceLevel == .red && red.growthLevel == .green, "40 GB free of 1 TB is red")
    expect(eval(flatSeries(860)).level == .yellow, "140 GB free of 1 TB (14%) is yellow")
    expect(eval(flatSeries(840)).level == .green, "160 GB free of 1 TB is green")
    let abs = eval(flatSeries(241, totalGB: 256))
    expect(abs.level == .red, "15 GB free of 256 GB is red by the 15 GiB rule")
    let hold = eval(flatSeries(940), prev: .red)
    expect(hold.level == .red && hold.reasonCode == "hold", "60 GB free is below entry+3pp (80 GB): stay red")
    let out = eval(flatSeries(900), prev: .red)
    expect(out.level == .yellow, "100 GB free: red -> yellow")
    let yHold = eval(flatSeries(830), prev: .yellow)
    expect(yHold.level == .yellow, "170 GB free is below 18%: stay yellow")
    let yOut = eval(flatSeries(800), prev: .yellow)
    expect(yOut.level == .green, "200 GB free: yellow -> green")
}
do {
    // Missing data keeps the previous level.
    let empty = eval([], prev: .yellow)
    expect(empty.level == .yellow && empty.reasonCode == "no_data" && empty.growthLevel == .unknown, "no samples -> previous level, no_data")
    let old = eval([sample(3, usedGB: 960)], prev: .yellow)
    expect(old.level == .yellow && old.reasonCode == "no_data", "sample older than 2 h -> no_data")
    let failedOnly = eval([failedSample(0.1), failedSample(0.2)], prev: .red)
    expect(failedOnly.level == .red && failedOnly.reasonCode == "no_data", "failed reads -> no_data")
    let mixed = eval([sample(120, usedGB: 100), sample(1, usedGB: 960), failedSample(0.1)], prev: .green)
    expect(mixed.level == .red, "failed latest read falls back to the last ok sample")
}

// MARK: - DiskAlertPolicy

section("DiskAlertPolicy")
do {
    let v = eval([sample(120, usedGB: 200), sample(72, usedGB: 150), sample(0, usedGB: 450)])
    var state = DiskAlertState()
    let since = ago(1)
    guard let first = DiskAlertPolicy.growthAlert(verdict: v, since: since, state: state) else {
        expect(false, "first growth alert missing"); exit(1)
    }
    expect(first.type == "disk_growth" && first.subject == "/System/Volumes/Data" && first.level == .red, "alert fields")
    expect(DiskAlertPolicy.growthTitle(v) == "磁盘 5 天多占用了 300 GB", "title: \(DiskAlertPolicy.growthTitle(v))")
    expect(first.message.contains("已排除可清除空间（快照、缓存）") && !first.message.contains("不是快照"), "message wording")
    expect(first.agentHint.contains("Mole CLI") && first.agentHint.contains("不要删除") && first.agentHint.contains("5 天"), "agent hint wording")
    expect(!first.agentHint.lowercased().contains("mole-") && !first.agentHint.contains("mole "), "agent hint has no command name")
    DiskAlertPolicy.record(growth: first, bytes: v.triggerBytes ?? 0, into: &state)
    expect(DiskAlertPolicy.growthAlert(verdict: v, since: since, state: state) == nil, "same growth does not notify again")
    var v2 = v
    v2.triggerBytes = 449 * GB
    expect(DiskAlertPolicy.growthAlert(verdict: v2, since: since, state: state) == nil, "growth below 1.5x does not notify")
    v2.triggerBytes = 450 * GB
    expect(DiskAlertPolicy.growthAlert(verdict: v2, since: since, state: state) != nil, "growth at 1.5x notifies")
    var yellowState = DiskAlertState(lastGrowthNotifiedBytes: 300 * GB, lastGrowthLevel: .yellow, lastLowSpaceNotifiedAt: nil)
    v2.triggerBytes = 310 * GB
    expect(DiskAlertPolicy.growthAlert(verdict: v2, since: since, state: yellowState) != nil, "yellow -> red notifies at once")
    yellowState.lastGrowthLevel = .red
    expect(DiskAlertPolicy.growthAlert(verdict: v2, since: since, state: yellowState) == nil, "red -> red below 1.5x stays quiet")
    let greenV = eval(growthSeries(10))
    expect(DiskAlertPolicy.growthAlert(verdict: greenV, since: since, state: DiskAlertState()) == nil, "green verdict never notifies")
    let lowOnly = eval(flatSeries(960))
    expect(DiskAlertPolicy.growthAlert(verdict: lowOnly, since: since, state: DiskAlertState()) == nil, "low space alone is not a growth alert")
    DiskAlertPolicy.settle(verdict: greenV, into: &state)
    expect(state.lastGrowthNotifiedBytes == nil && state.lastGrowthLevel == nil, "settle clears growth state when growth is green")
    var kept = DiskAlertState(lastGrowthNotifiedBytes: 5, lastGrowthLevel: .red, lastLowSpaceNotifiedAt: nil)
    DiskAlertPolicy.settle(verdict: empty(), into: &kept)
    expect(kept.lastGrowthNotifiedBytes == 5, "settle keeps state when data is missing")
}
func empty() -> DiskVerdict { eval([], prev: .yellow) }
do {
    let v = eval(flatSeries(960))
    let since = ago(2)
    var state = DiskAlertState()
    guard let a = DiskAlertPolicy.lowSpaceAlert(verdict: v, since: since, state: state, now: now) else {
        expect(false, "low space alert missing"); exit(1)
    }
    expect(a.type == "disk_low_space" && a.level == .red && a.message.contains("40 GB"), "low space alert text: \(a.message)")
    DiskAlertPolicy.recordLowSpace(at: now, into: &state)
    expect(DiskAlertPolicy.lowSpaceAlert(verdict: v, since: since, state: state, now: now.addingTimeInterval(23 * 3600)) == nil, "23 h later: cooldown")
    expect(DiskAlertPolicy.lowSpaceAlert(verdict: v, since: since, state: state, now: now.addingTimeInterval(24 * 3600)) != nil, "24 h later: notify again")
    expect(DiskAlertPolicy.lowSpaceAlert(verdict: eval(flatSeries(860)), since: since, state: DiskAlertState(), now: now) == nil, "yellow free space does not notify")
}

// MARK: - StatusFile

section("StatusFile")
func makeStatus(_ samples: [DiskSample], prev: HealthLevel = .green, writtenAt: Date = now, pid: Int32 = 4242) -> StatusFile {
    let v = eval(samples, prev: prev)
    let disk = DiskItem.make(samples: samples, now: now, verdict: v, since: v.level == .green ? nil : ago(1), levelChangedAt: ago(1))
    let alerts = DiskAlertPolicy.growthAlert(verdict: v, since: ago(1), state: DiskAlertState()).map { [$0] } ?? []
    return StatusFile(appVersion: "test", writtenAt: writtenAt, writerPid: pid,
                      overall: .init(level: HealthLevel.worst([v.level]), summary: v.reason),
                      items: .init(disk: disk, network: NetworkItem.make(samples: samples, now: now, todayStart: ago(12))),
                      activeAlerts: alerts, notifications: .init(authorization: "authorized"))
}
let redSamples = [sample(120, usedGB: 200, rx: 100, tx: 10), sample(72, usedGB: 150, rx: 200, tx: 20), sample(0, usedGB: 450, rx: 300, tx: 30)]
do {
    let absent = Measured<Int64>.absent(unit: "bytes", status: .missing)
    let text = String(decoding: try CoreJSON.encoder().encode(absent), as: UTF8.self)
    expect(text == "{\"sampled_at\":null,\"status\":\"missing\",\"unit\":\"bytes\",\"value\":null}", "Measured writes value:null (got \(text))")
    let ok = Measured<Int64>.ok(0, unit: "bytes", at: now)
    let okText = String(decoding: try CoreJSON.encoder().encode(ok), as: UTF8.self)
    expect(okText.contains("\"value\":0") && okText.contains("\"sampled_at\":\"2026-10-11T12:00:00Z\""), "measured zero stays 0 (got \(okText))")
    let back = try CoreJSON.decoder().decode(Measured<Int64>.self, from: Data(text.utf8))
    expect(back.value == nil && back.status == .missing, "null value decodes to nil")

    let status = makeStatus(redSamples, prev: .green)
    let data = try CoreJSON.encoder().encode(status)
    let decoded = try CoreJSON.decoder().decode(StatusFile.self, from: data)
    let reencoded = try CoreJSON.encoder().encode(decoded)
    expect(reencoded == data, "StatusFile JSON round trip is stable")
    let obj = jsonObject(data)
    expect(obj?["schema_version"] as? Int == 1, "schema_version 1")
    let items = obj?["items"] as? NSDictionary
    let disk = items?["disk"] as? NSDictionary
    expect(disk?["level"] as? String == "red" && disk?["reason_code"] as? String == "growth_5d", "disk level and reason_code")
    expect((disk?["growth"] as? NSDictionary)?.allKeys.count == 3, "growth has 1d, 5d, 30d")
    expect(((disk?["used"] as? NSDictionary)?["value"] as? Int) == Int(450 * GB), "used = real used 450 GB")
    expect(((disk?["purgeable_estimate"] as? NSDictionary)?["value"] as? Int) == Int(5 * GB), "purgeable estimate = important - now = 5 GB")
    let net = items?["network"] as? NSDictionary
    expect((net?["traffic"] as? NSDictionary)?.allKeys.count == 2 && net?["note"] as? String == "物理网卡合计，不含 VPN 隧道", "network traffic and note")
    expect((obj?["active_alerts"] as? [Any])?.count == 1, "one active alert")
    expect(((obj?["notifications"] as? NSDictionary)?["authorization"] as? String) == "authorized", "authorization")
    let growth30 = (disk?["growth"] as? NSDictionary)?["30d"] as? NSDictionary
    expect(growth30?["status"] as? String == "insufficient_window" && growth30?["bytes"] as? Int == Int(300 * GB), "30d growth is a lower bound")

    // Data older than max age or failed reads: values are null, not 0.
    let stale = makeStatus([sample(5, usedGB: 500)])
    expect(stale.items.disk.used.value == nil && stale.items.disk.used.status == .stale, "stale sample gives null value, status stale")
    let none = makeStatus([])
    expect(none.items.disk.total.value == nil && none.items.disk.total.status == .collecting, "no samples -> collecting")
    let failedOnly = makeStatus([failedSample(0.1)])
    expect(failedOnly.items.disk.total.status == .failed && failedOnly.items.disk.lastSampleAt == nil, "failed read -> failed, no last sample")
    let noDiskText = String(decoding: try CoreJSON.encoder().encode(none.items.disk), as: UTF8.self)
    expect(noDiskText.contains("\"since\":null") && noDiskText.contains("\"last_sample_at\":null"), "nil dates are written as null")
    var noAvail = sample(0, usedGB: 100)
    noAvail.avail = nil
    expect(makeStatus([sample(120, usedGB: 100), noAvail]).items.disk.purgeableEstimate.status == .missing, "no avail -> purgeable missing")
    var negative = sample(0, usedGB: 100)
    negative.avail = negative.availImportant.map { $0 + 1 }
    expect(makeStatus([sample(120, usedGB: 100), negative]).items.disk.purgeableEstimate.value == nil, "negative purgeable is not reported")
    expect(HealthLevel.worst([.green, .yellow]) == .yellow && HealthLevel.worst([.green, .red, .stale]) == .red && HealthLevel.worst([.green]) == .green && HealthLevel.worst([]) == .unknown, "worst level")
} catch {
    expect(false, "status JSON test threw: \(error)")
}
do {
    let dir = freshDir("status")
    let url = MoleMonitorPaths.statusURL(dir: dir)
    let status = makeStatus(redSamples)
    try StatusStore.write(status, to: url)
    expect(mode(url) == 0o600, "status.json is 0600 (got \(String(mode(url), radix: 8)))")
    expect(mode(dir) == 0o700, "status directory is 0700")
    var second = status
    second.appVersion = "second"
    try StatusStore.write(second, to: url)
    let reread = try StatusStore.read(from: url)
    expect(reread.appVersion == "second", "second write replaces the file")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    expect(names == ["status.json"], "no temp file is left (found \(names))")

    // Failure leaves no half file: the target is a directory, so rename fails.
    let blockDir = freshDir("status-blocked")
    try FileManager.default.createDirectory(at: blockDir.appendingPathComponent("status.json"), withIntermediateDirectories: true)
    var threw = false
    do { try StatusStore.write(status, to: blockDir.appendingPathComponent("status.json")) } catch { threw = true }
    let leftover = ((try? FileManager.default.contentsOfDirectory(atPath: blockDir.path)) ?? []).filter { $0 != "status.json" }
    expect(threw && leftover.isEmpty, "failed write throws and removes its temp file (leftover \(leftover))")

    // Reading garbage throws instead of crashing.
    let junk = dir.appendingPathComponent("junk.json")
    try Data("{\"schema_version\":1".utf8).write(to: junk)
    var readThrew = false
    do { _ = try StatusStore.read(from: junk) } catch { readThrew = true }
    expect(readThrew, "truncated status.json throws")
    var missingThrew = false
    do { _ = try StatusStore.read(from: dir.appendingPathComponent("nope.json")) } catch { missingThrew = true }
    expect(missingThrew, "missing status.json throws")
} catch {
    expect(false, "status store test threw: \(error)")
}
do {
    let s = makeStatus(redSamples, writtenAt: now.addingTimeInterval(-419))
    var f = StatusStore.freshness(of: s, now: now, pidAlive: { _ in true })
    expect(f.fresh && f.appRunning && f.ageSeconds == 419, "419 s old with live pid is fresh")
    var s2 = s
    s2.writtenAt = now.addingTimeInterval(-421)
    f = StatusStore.freshness(of: s2, now: now, pidAlive: { _ in true })
    expect(!f.fresh && f.appRunning, "421 s old is not fresh")
    s2.writtenAt = now.addingTimeInterval(-420)
    expect(StatusStore.freshness(of: s2, now: now, pidAlive: { _ in true }).fresh, "420 s is still fresh")
    f = StatusStore.freshness(of: s, now: now, pidAlive: { _ in false })
    expect(!f.fresh && !f.appRunning, "dead pid -> not running, not fresh")
    var future = s
    future.writtenAt = now.addingTimeInterval(3600)
    expect(!StatusStore.freshness(of: future, now: now, pidAlive: { _ in true }).fresh, "timestamp far in the future is not fresh")
    expect(StatusStore.processAlive(getpid()), "own pid is alive")
    expect(!StatusStore.processAlive(0) && !StatusStore.processAlive(-5), "pid <= 0 is never alive")
    expect(!StatusStore.processAlive(2_000_000_000), "unused pid is not alive")
}

// MARK: - Paths

section("Paths")
expect(MoleMonitorPaths.dataDir(environment: ["MOLEMONITOR_DATA_DIR": "/tmp/mm-x", "HOME": "/h"]).path == "/tmp/mm-x", "env override wins")
expect(MoleMonitorPaths.dataDir(environment: ["HOME": "/Users/test"]).path == "/Users/test/Library/Application Support/MoleMonitor", "default under HOME")
expect(MoleMonitorPaths.dataDir(environment: ["MOLEMONITOR_DATA_DIR": "", "HOME": "/Users/test"]).path == "/Users/test/Library/Application Support/MoleMonitor", "empty override is ignored")
expect(MoleMonitorPaths.statusURL(dir: URL(fileURLWithPath: "/x")).path == "/x/status.json", "status.json path")

// MARK: - Brief

section("Brief")
do {
    let freshF = StatusStore.Freshness(fresh: true, ageSeconds: 30, appRunning: true)
    let red = makeStatus(redSamples)
    expect(Brief.line(red, freshness: freshF) == "磁盘 红（5 天 +300 GB）", "red growth: \(Brief.line(red, freshness: freshF))")
    let green = makeStatus(growthSeries(10))
    expect(Brief.line(green, freshness: freshF) == "磁盘 绿（剩余 890 GB）", "green: \(Brief.line(green, freshness: freshF))")
    let low = makeStatus(flatSeries(960))
    expect(Brief.line(low, freshness: freshF) == "磁盘 红（剩余 40 GB）", "low space: \(Brief.line(low, freshness: freshF))")
    let hold = makeStatus(growthSeries(150), prev: .red)
    expect(Brief.line(hold, freshness: freshF) == "磁盘 红（回落观察）", "hold: \(Brief.line(hold, freshness: freshF))")
    let unknown = makeStatus([])
    expect(Brief.line(unknown, freshness: freshF) == "磁盘 绿", "no data keeps previous level, no figure: \(Brief.line(unknown, freshness: freshF))")
    let down = StatusStore.Freshness(fresh: false, ageSeconds: 7300, appRunning: false)
    expect(Brief.line(red, freshness: down) == "磁盘 红（5 天 +300 GB） · App 未运行（数据 2 小时前）", "app not running: \(Brief.line(red, freshness: down))")
    let late = StatusStore.Freshness(fresh: false, ageSeconds: 720, appRunning: true)
    expect(Brief.line(red, freshness: late) == "磁盘 红（5 天 +300 GB） · 数据已过期（12 分钟前）", "stale data: \(Brief.line(red, freshness: late))")
    expect(!Brief.line(red, freshness: freshF).contains("\n"), "brief is one line")
}

// MARK: - DiskReport

section("DiskReport")
do {
    func at(_ iso: String, _ usedGB: Int64) -> DiskSample {
        DiskSample(t: UTCTime.parseISO(iso)!, total: 1000 * GB, availImportant: (1000 - usedGB) * GB)
    }
    let samples = [at("2026-10-09T23:50:00Z", 120), at("2026-10-09T01:00:00Z", 100), at("2026-10-09T12:00:00Z", 150),
                   at("2026-10-11T08:00:00Z", 130), at("2026-10-11T10:00:00Z", 200),
                   DiskSample(t: UTCTime.parseISO("2026-10-11T11:00:00Z")!, ok: false, err: "x"),
                   at("2026-10-11T13:00:00Z", 999)]  // after now: ignored
    let days = DiskReport.daily(samples: samples, days: 3, now: now)
    expect(days.map { $0.date } == ["2026-10-09", "2026-10-10", "2026-10-11"], "three UTC days, oldest first")
    expect(days[0].minUsed == 100 * GB && days[0].maxUsed == 150 * GB && days[0].growth == 20 * GB && days[0].samples == 3, "day 1 min/max/growth")
    expect(days[1].minUsed == nil && days[1].maxUsed == nil && days[1].growth == nil && days[1].samples == 0, "empty day keeps nulls")
    expect(days[2].minUsed == 130 * GB && days[2].growth == 70 * GB && days[2].samples == 2, "day 3 growth 70 GB, failed and future rows skipped")
    expect(DiskReport.daily(samples: samples, days: 0, now: now).count == 1, "days < 1 gives one row")
    let text = String(decoding: try CoreJSON.encoder().encode(days[1]), as: UTF8.self)
    expect(text == "{\"date\":\"2026-10-10\",\"growth\":null,\"max_used\":null,\"min_used\":null,\"samples\":0}", "DiskDay JSON: \(text)")
}

// MARK: - NetworkFilter / engine logic (NetworkTests.swift)

runNetworkTests()

// MARK: - Live series (LiveTests.swift)

runLiveTests()

// MARK: - Redesign suites (skeleton: empty functions; each owner fills their own file)

runPromptTests()
runTrendTests()
runHealthRuleTests()
runPowerTests()
runLayoutTests()
runDogTests()
runDogArtPoseTests()
runPipelineTests()

// MARK: - Summary

try? FileManager.default.removeItem(at: tmpRoot)
print("Result: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
