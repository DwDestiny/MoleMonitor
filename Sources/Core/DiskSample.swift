// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Disk samples from the sampler; monthly NDJSON files in the data directory.
// Output: Parsed samples, appended lines, pruned old files.
// Pos: Disk history storage (docs/PROJECT.md 6.3); Foundation only, safe off the main thread.

import Foundation

enum DiskSource: String, Codable { case launch, timer, wake, panel }

/// One NDJSON line. `ok == false` means the read failed; its numbers are never used.
struct DiskSample: Codable {
    static let currentVersion = 1

    var v: Int
    var t: Date
    var src: DiskSource
    var ok: Bool
    var vol: String
    var total: Int64?
    var availImportant: Int64?
    var avail: Int64?
    var used: Int64?
    var netRx: Int64?
    var netTx: Int64?
    var boot: Date?
    var err: String?

    enum CodingKeys: String, CodingKey {
        case v, t, src, ok, vol, total, avail, used, boot, err
        case availImportant = "avail_important"
        case netRx = "net_rx"
        case netTx = "net_tx"
    }

    init(v: Int = DiskSample.currentVersion, t: Date, src: DiskSource = .timer, ok: Bool = true,
         vol: String = "/System/Volumes/Data", total: Int64? = nil, availImportant: Int64? = nil,
         avail: Int64? = nil, used: Int64? = nil, netRx: Int64? = nil, netTx: Int64? = nil,
         boot: Date? = nil, err: String? = nil) {
        self.v = v; self.t = t; self.src = src; self.ok = ok; self.vol = vol
        self.total = total; self.availImportant = availImportant; self.avail = avail; self.used = used
        self.netRx = netRx; self.netTx = netTx; self.boot = boot; self.err = err
    }

    /// v, t and ok are required. Optional fields of the wrong type become nil, never 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        t = try c.decode(Date.self, forKey: .t)
        ok = try c.decode(Bool.self, forKey: .ok)
        src = (try? c.decode(DiskSource.self, forKey: .src)) ?? .timer
        vol = (try? c.decode(String.self, forKey: .vol)) ?? ""
        func int(_ k: CodingKeys) -> Int64? { (try? c.decodeIfPresent(Int64.self, forKey: k)) ?? nil }
        total = int(.total); availImportant = int(.availImportant); avail = int(.avail); used = int(.used)
        netRx = int(.netRx); netTx = int(.netTx)
        boot = (try? c.decodeIfPresent(Date.self, forKey: .boot)) ?? nil
        err = (try? c.decodeIfPresent(String.self, forKey: .err)) ?? nil
    }

    /// Real used = total - availImportant. Nil unless the read worked and the numbers are plausible.
    var realUsed: Int64? {
        guard ok, let total, let availImportant, total > 0, availImportant >= 0, availImportant <= total else { return nil }
        return total - availImportant
    }
}

enum DiskHistory {
    static func fileName(for date: Date) -> String {
        let m = UTCTime.month(date)
        return "disk-" + UTCTime.monthString(year: m.year, month: m.month) + ".ndjson"
    }

    /// Skips blank lines silently. Bad JSON, missing v/t/ok, and unknown versions count as corrupt.
    static func parse(lines: [String]) -> (samples: [DiskSample], corrupt: Int) {
        let decoder = CoreJSON.decoder()
        var out = [DiskSample]()
        var corrupt = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let s = try? decoder.decode(DiskSample.self, from: Data(trimmed.utf8)),
                  s.v >= 1, s.v <= DiskSample.currentVersion else {
                corrupt += 1
                continue
            }
            out.append(s)
        }
        return (out, corrupt)
    }

    /// Reads this month's and last month's files; keeps samples from the last `days` days, oldest first.
    static func load(dir: URL, now: Date, days: Int) -> (samples: [DiskSample], corrupt: Int) {
        let cur = UTCTime.month(now)
        let prev = UTCTime.previousMonth(of: cur)
        let start = now.addingTimeInterval(-Double(max(days, 0)) * 86400)
        var all = [DiskSample]()
        var corrupt = 0
        for m in [prev, cur] {
            let url = dir.appendingPathComponent("disk-" + UTCTime.monthString(year: m.year, month: m.month) + ".ndjson")
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let r = parse(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            all += r.samples.filter { $0.t >= start }
            corrupt += r.corrupt
        }
        all.sort { $0.t < $1.t }
        return (all, corrupt)
    }

    /// Appends one line (no fsync). Creates the directory 0700 and the file 0600.
    static func append(_ s: DiskSample, dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(fileName(for: s.t))
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var payload = try CoreJSON.encoder().encode(s)
        payload.append(10)
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        if end > 0 {
            // A crashed write can leave a partial last line; start a new line so it stays isolated.
            try h.seek(toOffset: end - 1)
            if let last = try h.read(upToCount: 1), last.first != 10 { payload.insert(10, at: 0) }
        }
        try h.write(contentsOf: payload)
    }

    /// Deletes disk-YYYY-MM.ndjson files older than last month.
    static func prune(dir: URL, now: Date) {
        let cur = UTCTime.month(now)
        let prev = UTCTime.previousMonth(of: cur)
        let keepFrom = prev.year * 12 + prev.month
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            guard name.hasPrefix("disk-"), name.hasSuffix(".ndjson") else { continue }
            let core = name.dropFirst(5).dropLast(7)  // YYYY-MM
            let parts = core.split(separator: "-")
            guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
                  let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { continue }
            if y * 12 + m < keepFrom {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
