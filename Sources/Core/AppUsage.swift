// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Process samples from two scans (docs/DESIGN.md 6.6, 8.1).
// Output: Per-app CPU and memory usage, the top list, and window means for the single-app CPU rule.
// Pos: Pure app ranking logic behind "占用 App"; Foundation only. Owner I1.
//      Process names, bundle ids and display names only. No path, no argument, no user name is kept.

import Foundation

struct ProcessSample: Equatable {
    var pid: Int32
    var startAbs: UInt64
    var name: String
    var appKey: String          // Bundle id or "proc:<name>"
    var displayName: String
    var bundleID: String?
    var cpuTimeNs: UInt64
    var footprint: UInt64?
    var rss: UInt64?
    var isSystem: Bool
}

struct AppUsage: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var bundleID: String?
    var cpuPercent: Double?
    var memoryBytes: Int64?
    var memoryBasis: String     // "footprint" or "rss"
    var processCount: Int
    var isSystem: Bool
    /// Bytes written to disk since the previous scan (`ri_diskio_byteswritten` difference). Nil when not measured.
    /// Writes are not disk growth: deletes and overwrites count too (DESIGN_V2.md 6.4).
    var diskWrittenBytes: Int64?
    var id: String { key }
}

struct ProcessCoverage: Codable, Equatable {
    var readable: Int
    var unreadable: Int
}

enum AppSortKey { case cpu, memory }

/// Window means of one app for the single-app CPU rule (PROJECT.md 3.2): yellow at a 30 minute mean of 90 %
/// (one core = 100 %), exit below a 10 minute mean of 50 %. Not listed in DESIGN.md 8.1 at skeleton time;
/// added because `CPUHealth.evaluate` needs it.
struct AppWindowStat: Codable, Equatable {
    var key: String
    var name: String
    var mean10m: Double?
    var mean30m: Double?
}

enum AppRanking {
    /// Default ignore list (PROJECT.md 3.2). A process is ignored when its name starts with an entry (case-insensitive).
    /// MoleMonitor itself is not ignored.
    static let defaultIgnore: Set<String> = [
        "mds_stores", "mdworker", "mdworker_shared", "photoanalysisd", "backupd", "XProtect",
    ]

    /// A row is shown when CPU is at least 0.5 % or memory is at least 50 MB (DESIGN.md 6.6).
    static let minimumCPU = 0.5
    static let minimumMemory: Int64 = 50_000_000

    static func isIgnored(_ name: String, ignore: Set<String>) -> Bool {
        let lower = name.lowercased()
        for entry in ignore where !entry.isEmpty && lower.hasPrefix(entry.lowercased()) { return true }
        return false
    }

    /// Usage per app between two scans. `seconds` is the wall time between them.
    /// Processes are matched by (pid, start time), so a reused pid is a new process. A new process counts all of its
    /// CPU time, because it did not exist at the first scan. Without a previous scan or with `seconds <= 0` the CPU is nil.
    static func usage(previous: [ProcessSample], current: [ProcessSample], seconds: Double,
                      ignore: Set<String>) -> [AppUsage] {
        struct Key: Hashable { var pid: Int32; var start: UInt64 }
        var before = [Key: UInt64]()
        for p in previous { before[Key(pid: p.pid, start: p.startAbs)] = p.cpuTimeNs }
        let canMeasure = !previous.isEmpty && seconds > 0

        struct Group {
            var name: String
            var bundleID: String?
            var cpu: Double?
            var memory: Int64?
            var usedRSS = false
            var count = 0
            var allSystem = true
        }
        var groups = [String: Group]()
        var order = [String]()
        for p in current.sorted(by: { $0.pid < $1.pid }) {
            if isIgnored(p.name, ignore: ignore) { continue }
            var g = groups[p.appKey] ?? Group(name: p.displayName, bundleID: p.bundleID, cpu: canMeasure ? 0 : nil, memory: nil)
            if groups[p.appKey] == nil { order.append(p.appKey) }
            if canMeasure {
                let old = before[Key(pid: p.pid, start: p.startAbs)] ?? 0
                let delta = p.cpuTimeNs > old ? Double(p.cpuTimeNs - old) : 0
                g.cpu = (g.cpu ?? 0) + delta / (seconds * 1e9) * 100
            }
            if let f = p.footprint {
                g.memory = (g.memory ?? 0) + Int64(f)
            } else if let r = p.rss {
                g.memory = (g.memory ?? 0) + Int64(r)
                g.usedRSS = true
            }
            g.count += 1
            if !p.isSystem { g.allSystem = false }
            groups[p.appKey] = g
        }
        var out = [AppUsage]()
        for key in order {
            guard let g = groups[key] else { continue }
            out.append(AppUsage(key: key, name: g.name, bundleID: g.bundleID, cpuPercent: g.cpu, memoryBytes: g.memory,
                                memoryBasis: g.usedRSS ? "rss" : "footprint", processCount: g.count, isSystem: g.allSystem))
        }
        return out
    }

    /// The top rows. Rows below both minimums are left out, so the result can hold fewer than `count` rows.
    /// CPU order: CPU descending, then memory. Memory order: memory descending, then CPU.
    static func top(_ apps: [AppUsage], by key: AppSortKey, count: Int = 5) -> [AppUsage] {
        let shown = apps.filter { ($0.cpuPercent ?? 0) >= minimumCPU || ($0.memoryBytes ?? 0) >= minimumMemory }
        let sorted = shown.sorted { a, b in
            let ac = a.cpuPercent ?? -1, bc = b.cpuPercent ?? -1
            let am = a.memoryBytes ?? -1, bm = b.memoryBytes ?? -1
            switch key {
            case .cpu:
                if ac != bc { return ac > bc }
                if am != bm { return am > bm }
            case .memory:
                if am != bm { return am > bm }
                if ac != bc { return ac > bc }
            }
            if a.name != b.name { return a.name < b.name }
            return a.key < b.key
        }
        return Array(sorted.prefix(max(0, count)))
    }
}

/// Window means of app CPU over the last 30 minutes, kept in 30 second buckets (at most 60 buckets).
/// Intervals longer than 10 minutes (sleep) are not counted. A mean needs 90 % coverage of its window.
/// Apps below 10 % in an interval count as 0 there, which can only lower a mean. That is safe for the
/// thresholds (yellow at 90 %, exit below 50 %).
struct AppCPUTracker {
    static let bucketSeconds = 30.0
    static let longestInterval = 600.0
    static let trackedMinimum = 10.0
    static let window30m = 1800.0
    static let window10m = 600.0

    private struct Bucket {
        var start: Double
        var covered = 0.0
        var weighted = [String: Double]()   // app key -> sum of cpu% x seconds
    }

    private var buckets = [Bucket]()
    private var names = [String: String]()

    init() {}

    mutating func add(at time: Date, seconds: Double, usage: [AppUsage]) {
        guard seconds > 0, seconds <= AppCPUTracker.longestInterval else { return }
        let t = time.timeIntervalSince1970
        let start = (t / AppCPUTracker.bucketSeconds).rounded(.down) * AppCPUTracker.bucketSeconds
        if let last = buckets.last, start < last.start {
            buckets.removeAll()   // The clock moved back: start again.
        }
        if buckets.last?.start != start { buckets.append(Bucket(start: start)) }
        let index = buckets.count - 1
        buckets[index].covered += seconds
        for u in usage {
            guard let cpu = u.cpuPercent, cpu >= AppCPUTracker.trackedMinimum else { continue }
            buckets[index].weighted[u.key, default: 0] += cpu * seconds
            names[u.key] = u.name
        }
        let oldest = start - AppCPUTracker.window30m
        buckets.removeAll { $0.start < oldest }
    }

    mutating func reset() {
        buckets.removeAll()
        names.removeAll()
    }

    private func mean(_ key: String, now: Double, window: Double) -> Double? {
        var covered = 0.0
        var sum = 0.0
        for b in buckets where b.start > now - window && b.start <= now {
            covered += b.covered
            sum += b.weighted[key] ?? 0
        }
        guard covered >= window * 0.9 else { return nil }
        return sum / covered
    }

    /// True when the scans of the last 10 minutes cover at least 90 % of that window, so a 10 minute mean is valid.
    func hasCoverage(now: Date) -> Bool {
        let t = now.timeIntervalSince1970
        var covered = 0.0
        for b in buckets where b.start > t - AppCPUTracker.window10m && b.start <= t { covered += b.covered }
        return covered >= AppCPUTracker.window10m * 0.9
    }

    /// One entry per app that had at least 10 % in any interval of the last 30 minutes.
    func stats(now: Date) -> [AppWindowStat] {
        let t = now.timeIntervalSince1970
        var keys = Set<String>()
        for b in buckets where b.start > t - AppCPUTracker.window30m { keys.formUnion(b.weighted.keys) }
        var out = [AppWindowStat]()
        for key in keys.sorted() {
            out.append(AppWindowStat(key: key, name: names[key] ?? key,
                                     mean10m: mean(key, now: t, window: AppCPUTracker.window10m),
                                     mean30m: mean(key, now: t, window: AppCPUTracker.window30m)))
        }
        return out
    }
}
