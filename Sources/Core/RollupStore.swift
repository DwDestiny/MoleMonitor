// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Rollup files rollup-YYYY-MM.ndjson in the data directory (docs/DESIGN_V2.md 12.2 D1).
// Output: RollupWindow (one 5 minute window), RollupAggregator (trend points -> window) and RollupStore (line format,
//         append, read, prune) for the 24 hour and 7 day curves.
// Pos: Storage behind the sidebar ranges (DESIGN_V2.md 12.2 D1); Foundation only. Owner WP-A.
//      Privacy: numbers and enums only. No app name, no path, no argument. Files 0600 in a 0700 directory.

import Foundation

/// One 5 minute window. Units follow the file keys: swap in MB, rx and tx in KB/s. Nil means missing, not zero.
struct RollupWindow: Codable, Equatable {
    /// `t`: end of the window (UTC).
    var end: Date
    /// `n`: coarse points in the window (10 for a full window).
    var pointCount: Int
    /// `cpu`: mean and peak, percent.
    var cpuMean: Double?
    var cpuPeak: Double?
    /// `pp`: memory pressure percent, mean and peak. Absent when the pressure percent was missing.
    var pressureMean: Double?
    var pressurePeak: Double?
    /// `sw`: swap used at the end of the window, MB.
    var swapMB: Int64?
    /// `mp`: highest pressure level in the window.
    var pressure: MemoryPressure?
    /// `th`: highest thermal state in the window.
    var thermal: ThermalLevel?
    /// `bat`: battery percent at the end of the window. Absent without a battery.
    var batteryPercent: Double?
    /// `ps`: power source.
    var power: PowerSource?
    /// `rx`, `tx`: mean rates, KB/s.
    var rxKBps: Double?
    var txKBps: Double?
}

/// Result of a read. Damaged lines are skipped and counted, as for `disk-*.ndjson`.
struct RollupReadResult: Equatable {
    var windows: [RollupWindow]
    var skippedLines: Int
    static let empty = RollupReadResult(windows: [], skippedLines: 0)
}

/// Builds one window from the coarse trend points. A window with no point gives nil: nothing is written for it, so a gap
/// stays a gap and never turns into zeros.
enum RollupAggregator {
    /// The window grid: ends are multiples of `RollupStore.windowSeconds` since the epoch.
    static func windowEnd(containing t: Date) -> Date {
        let w = RollupStore.windowSeconds
        return Date(timeIntervalSince1970: (t.timeIntervalSince1970 / w).rounded(.down) * w)
    }

    /// The newest window that is finished at `now` (its end is not after `now`).
    static func lastFinishedEnd(now: Date) -> Date { windowEnd(containing: now) }

    /// Points with `end - 300 s < t <= end`. Mean and peak ignore missing values. Swap, battery and power take the last
    /// measured value in the window. Pressure and thermal take the highest level.
    static func window(points: [TrendPoint], end: Date) -> RollupWindow? {
        let start = end.addingTimeInterval(-RollupStore.windowSeconds)
        let inside = points.filter { $0.t > start && $0.t <= end }.sorted { $0.t < $1.t }
        guard !inside.isEmpty else { return nil }
        func stat(_ values: [Double]) -> (mean: Double, peak: Double)? {
            let clean = values.filter { $0.isFinite }
            guard !clean.isEmpty else { return nil }
            return (clean.reduce(0, +) / Double(clean.count), clean.max() ?? 0)
        }
        let cpu = stat(inside.compactMap { $0.cpu })
        let pp = stat(inside.compactMap { $0.pressurePercent.map(Double.init) })
        let rx = stat(inside.compactMap { $0.rx })
        let tx = stat(inside.compactMap { $0.tx })
        let pressureRank: (MemoryPressure) -> Int = { $0 == .normal ? 0 : ($0 == .warning ? 1 : 2) }
        let thermalRank: (ThermalLevel) -> Int = {
            switch $0 { case .nominal: return 0; case .fair: return 1; case .serious: return 2; case .critical: return 3 }
        }
        return RollupWindow(
            end: end, pointCount: inside.count,
            cpuMean: cpu?.mean, cpuPeak: cpu?.peak, pressureMean: pp?.mean, pressurePeak: pp?.peak,
            swapMB: inside.compactMap { $0.swapUsed }.last.map { $0 / 1_000_000 },
            pressure: inside.compactMap { $0.pressure }.max { pressureRank($0) < pressureRank($1) },
            thermal: inside.compactMap { $0.thermal }.max { thermalRank($0) < thermalRank($1) },
            batteryPercent: inside.compactMap { $0.battery }.last,
            power: inside.compactMap { $0.power }.last,
            rxKBps: rx.map { $0.mean / 1000 }, txKBps: tx.map { $0.mean / 1000 })
    }
}

enum RollupStore {
    static let filePrefix = "rollup-"
    static let version = 1
    /// Window length in seconds.
    static let windowSeconds: TimeInterval = 300
    /// One file is one UTC month: at most 8928 windows of about 110 bytes (about 1 MB). Two months stay under 2 MB.
    /// A file above this size accepts no more lines, so a runaway writer cannot fill the disk.
    static let maxFileBytes = 1_200_000
    static let maxPointsPerWindow = 1000

    static func fileName(for end: Date) -> String {
        let m = UTCTime.month(end)
        return filePrefix + UTCTime.monthString(year: m.year, month: m.month) + ".ndjson"
    }

    // MARK: Line format (DESIGN_V2.md 12.2 D1)

    private static func num(_ d: Double) -> String {
        let r = (d * 10).rounded() / 10
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        return String(r)
    }

    /// `{"v":1,"t":"...","n":10,"cpu":[a,b],"pp":[a,b],"sw":..,"mp":"n","th":"f","bat":61,"ps":"b","rx":..,"tx":..}`.
    /// A missing value leaves its key out. A measured zero is written as 0.
    static func encodeLine(_ w: RollupWindow) -> String {
        var parts = ["\"v\":\(version)", "\"t\":\"\(UTCTime.iso(w.end))\"", "\"n\":\(w.pointCount)"]
        if let a = w.cpuMean, let b = w.cpuPeak, a.isFinite, b.isFinite { parts.append("\"cpu\":[\(num(a)),\(num(b))]") }
        if let a = w.pressureMean, let b = w.pressurePeak, a.isFinite, b.isFinite { parts.append("\"pp\":[\(num(a)),\(num(b))]") }
        if let v = w.swapMB { parts.append("\"sw\":\(v)") }
        if let v = w.pressure { parts.append("\"mp\":\"\(v == .normal ? "n" : (v == .warning ? "w" : "c"))\"") }
        if let v = w.thermal {
            let code: String
            switch v { case .nominal: code = "n"; case .fair: code = "f"; case .serious: code = "s"; case .critical: code = "c" }
            parts.append("\"th\":\"\(code)\"")
        }
        if let v = w.batteryPercent, v.isFinite { parts.append("\"bat\":\(num(v))") }
        if let v = w.power { parts.append("\"ps\":\"\(v.rawValue)\"") }
        if let v = w.rxKBps, v.isFinite { parts.append("\"rx\":\(num(v))") }
        if let v = w.txKBps, v.isFinite { parts.append("\"tx\":\(num(v))") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Nil for a damaged line: bad JSON, a missing or wrong `v`, `t` or `n`. A field with a wrong type or an implausible
    /// value becomes nil (missing), never 0. A newer format version is skipped, not guessed.
    static func parseLine(_ line: String) -> RollupWindow? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let v = (object["v"] as? NSNumber)?.intValue, v == version,
              let t = (object["t"] as? String).flatMap({ UTCTime.parseISO($0) }),
              let n = (object["n"] as? NSNumber)?.intValue, n >= 1, n <= maxPointsPerWindow else { return nil }
        func pair(_ key: String, max limit: Double?) -> (Double, Double)? {
            guard let list = object[key] as? [Any], list.count == 2,
                  let a = (list[0] as? NSNumber)?.doubleValue, let b = (list[1] as? NSNumber)?.doubleValue,
                  a.isFinite, b.isFinite, a >= 0, b >= a else { return nil }
            if let limit, b > limit { return nil }
            return (a, b)
        }
        func number(_ key: String, max limit: Double) -> Double? {
            guard let x = (object[key] as? NSNumber)?.doubleValue, x.isFinite, x >= 0, x <= limit else { return nil }
            return x
        }
        let cpu = pair("cpu", max: 100_000)
        let pp = pair("pp", max: 100)
        var pressure: MemoryPressure?
        switch object["mp"] as? String { case "n": pressure = .normal; case "w": pressure = .warning; case "c": pressure = .critical; default: break }
        var thermal: ThermalLevel?
        switch object["th"] as? String {
        case "n": thermal = .nominal; case "f": thermal = .fair; case "s": thermal = .serious; case "c": thermal = .critical
        default: break
        }
        return RollupWindow(
            end: t, pointCount: n, cpuMean: cpu?.0, cpuPeak: cpu?.1, pressureMean: pp?.0, pressurePeak: pp?.1,
            swapMB: number("sw", max: 1e9).map { Int64($0) }, pressure: pressure, thermal: thermal,
            batteryPercent: number("bat", max: 100),
            power: (object["ps"] as? String).flatMap { PowerSource(rawValue: $0) },
            rxKBps: number("rx", max: 1e12), txKBps: number("tx", max: 1e12))
    }

    // MARK: Write

    /// Appends one line to the file of the window's month. Creates the directory 0700 and the file 0600. Returns false
    /// when the file is over `maxFileBytes`. A partial last line (a crashed write) is kept apart by a new line.
    @discardableResult
    static func append(_ w: RollupWindow, dir: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(fileName(for: w.end))
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var payload = Data((encodeLine(w) + "\n").utf8)
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        if Int(end) + payload.count > maxFileBytes { return false }
        if end > 0 {
            try h.seek(toOffset: end - 1)
            if let last = try h.read(upToCount: 1), last.first != 10 { payload.insert(10, at: 0) }
        }
        try h.write(contentsOf: payload)
        return true
    }

    /// Deletes rollup files older than last month.
    static func prune(dir: URL, now: Date) {
        let cur = UTCTime.month(now)
        let prev = UTCTime.previousMonth(of: cur)
        let keepFrom = prev.year * 12 + prev.month
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".ndjson") {
            let parts = name.dropFirst(filePrefix.count).dropLast(7).split(separator: "-")
            guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
                  let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { continue }
            if y * 12 + m < keepFrom { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    // MARK: Read

    /// The windows whose end time lies in `from ... to`, ascending, one per end time (the later line wins). Reads the
    /// files of the months in range. An unreadable file or a damaged line gives fewer windows and a count in
    /// `skippedLines`; it never throws or crashes.
    static func read(dir: URL, from: Date, to: Date) -> RollupReadResult {
        guard from <= to else { return .empty }
        var months = [(year: Int, month: Int)]()
        var m = UTCTime.month(from)
        let last = UTCTime.month(to)
        while m.year * 12 + m.month <= last.year * 12 + last.month, months.count < 4 {
            months.append(m)
            m = m.month == 12 ? (m.year + 1, 1) : (m.year, m.month + 1)
        }
        var byEnd = [Date: RollupWindow]()
        var skipped = 0
        for month in months {
            let url = dir.appendingPathComponent(filePrefix + UTCTime.monthString(year: month.year, month: month.month) + ".ndjson")
            guard let data = try? Data(contentsOf: url) else { continue }
            for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                guard let w = parseLine(line) else { skipped += 1; continue }
                if w.end >= from && w.end <= to { byEnd[w.end] = w }
            }
        }
        return RollupReadResult(windows: byEnd.values.sorted { $0.end < $1.end }, skippedLines: skipped)
    }

    /// Hours of data in a result, for the label "已记录 N 小时" (DESIGN_V2.md 12.2).
    static func recordedHours(_ r: RollupReadResult) -> Double {
        Double(r.windows.reduce(0) { $0 + min(10, $1.pointCount) }) * TrendBuffer.coarseInterval / 3600
    }
}
