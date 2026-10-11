// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Trend points and a data directory (docs/DESIGN.md 6.4, 8.1).
// Output: trend.json encode, decode, atomic write (0600) and tolerant load.
// Pos: Persistence of the coarse trend so a restart keeps the 2 hour curve; Foundation only. Owner I1.
//      File units: cpu with 1 decimal, rx and tx in KB/s (1000 bytes), swap in MiB, bat whole percent.

import Foundation

enum TrendStore {
    static let fileName = "trend.json"
    static let version = 1

    /// Columnar form. Every array has one entry per point. A nil entry is a missing value, not zero.
    private struct Columns: Codable {
        var v: Int
        var t0: String
        var dt: [Int]
        var cpu: [Double?]
        var rx: [Int?]
        var tx: [Int?]
        var swap: [Int?]
        var bat: [Int?]?
        var mp: [String?]
        var th: [String?]
        var ps: [String?]?
    }

    static func encode(_ points: [TrendPoint]) throws -> Data {
        let sorted = points.sorted { $0.t < $1.t }
        let first = sorted.first?.t ?? Date(timeIntervalSince1970: 0)
        let t0 = Date(timeIntervalSince1970: first.timeIntervalSince1970.rounded(.down))
        var c = Columns(v: version, t0: UTCTime.iso(t0), dt: [], cpu: [], rx: [], tx: [], swap: [],
                        bat: [], mp: [], th: [], ps: [])
        for p in sorted {
            c.dt.append(Int(p.t.timeIntervalSince(t0).rounded()))
            c.cpu.append(p.cpu.map { ($0 * 10).rounded() / 10 })
            c.rx.append(p.rx.map { Int(($0 / 1000).rounded()) })
            c.tx.append(p.tx.map { Int(($0 / 1000).rounded()) })
            c.swap.append(p.swapUsed.map { Int((Double($0) / 1_048_576).rounded()) })
            c.bat?.append(p.battery.map { Int($0.rounded()) })
            c.mp.append(p.pressure.map(pressureCode))
            c.th.append(p.thermal.map(thermalCode))
            c.ps?.append(p.power?.rawValue)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(c)
    }

    /// A wrong version, a damaged file or unequal lengths give an empty array. Points outside the window are dropped.
    /// An older file without `bat` or `ps` reads as all nil.
    static func decode(_ data: Data, now: Date, maxAge: TimeInterval = 7200) -> [TrendPoint] {
        guard let c = try? JSONDecoder().decode(Columns.self, from: data), c.v == version,
              let t0 = UTCTime.parseISO(c.t0) else { return [] }
        let n = c.dt.count
        guard c.cpu.count == n, c.rx.count == n, c.tx.count == n, c.swap.count == n,
              c.mp.count == n, c.th.count == n else { return [] }
        if let bat = c.bat, bat.count != n { return [] }
        if let ps = c.ps, ps.count != n { return [] }
        let oldest = now.addingTimeInterval(-maxAge)
        var out = [TrendPoint]()
        var lastDT = Int.min
        for i in 0..<n {
            guard c.dt[i] > lastDT else { return [] }   // not ascending: damaged
            lastDT = c.dt[i]
            let t = t0.addingTimeInterval(TimeInterval(c.dt[i]))
            if t < oldest || t > now { continue }
            var p = TrendPoint(t: t)
            p.cpu = c.cpu[i]
            p.rx = c.rx[i].map { Double($0) * 1000 }
            p.tx = c.tx[i].map { Double($0) * 1000 }
            p.swapUsed = c.swap[i].map { Int64($0) * 1_048_576 }
            p.battery = c.bat?[i].map { Double($0) }
            p.pressure = c.mp[i].flatMap(pressureFrom)
            p.thermal = c.th[i].flatMap(thermalFrom)
            p.power = c.ps?[i].flatMap { PowerSource(rawValue: $0) }
            out.append(p)
        }
        return out
    }

    /// Atomic write, mode 0600.
    static func write(_ points: [TrendPoint], dir: URL) throws {
        try AtomicFile.write(try encode(points), to: dir.appendingPathComponent(fileName))
    }

    static func load(dir: URL, now: Date) -> [TrendPoint] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return [] }
        return decode(data, now: now)
    }

    private static func pressureCode(_ m: MemoryPressure) -> String {
        switch m {
        case .normal: return "n"
        case .warning: return "w"
        case .critical: return "c"
        }
    }

    private static func pressureFrom(_ s: String) -> MemoryPressure? {
        switch s {
        case "n": return .normal
        case "w": return .warning
        case "c": return .critical
        default: return nil
        }
    }

    private static func thermalCode(_ m: ThermalLevel) -> String {
        switch m {
        case .nominal: return "n"
        case .fair: return "f"
        case .serious: return "s"
        case .critical: return "c"
        }
    }

    private static func thermalFrom(_ s: String) -> ThermalLevel? {
        switch s {
        case "n": return .nominal
        case "f": return .fair
        case "s": return .serious
        case "c": return .critical
        default: return nil
        }
    }
}
