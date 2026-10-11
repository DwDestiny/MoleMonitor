// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Interface counters, raw routing-message bytes, disk readings, samples and alert state from the engine.
// Output: Physical-NIC totals, byte rates, bounds-safe message walking, sample assembly, one engine evaluation step, notification budget, small file helpers.
// Pos: Pure logic behind Sources/App/{Sampler,Engine,Notifier}.swift (docs/PROJECT.md 5, 6, 7); Foundation only, testable on Linux.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Network counters

struct InterfaceCounters: Equatable {
    var name: String
    var rxBytes: UInt64
    var txBytes: UInt64
}

struct NetworkRate: Equatable {
    var rxPerSecond: Double
    var txPerSecond: Double
}

enum NetworkFilter {
    /// Counted: Wi-Fi and wired (en*), cellular (pdp_ip*).
    static let includedPrefixes = ["en", "pdp_ip"]
    /// Never counted: loopback, tunnels, AWDL, low-latency WLAN, bridges, hotspot, and other virtual links.
    static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi", "vmenet"]

    static func isPhysical(_ name: String) -> Bool {
        if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        return includedPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Sum of rx/tx over physical interfaces. Nil when no physical interface is present (missing, not 0).
    /// A sum above Int64.max is clamped; real counters never get near it.
    static func total(_ list: [InterfaceCounters]) -> (rx: Int64, tx: Int64)? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var any = false
        for c in list where isPhysical(c.name) {
            any = true
            rx = rx.addingReportingOverflow(c.rxBytes).overflow ? UInt64.max : rx + c.rxBytes
            tx = tx.addingReportingOverflow(c.txBytes).overflow ? UInt64.max : tx + c.txBytes
        }
        guard any else { return nil }
        return (Int64(min(rx, UInt64(Int64.max))), Int64(min(tx, UInt64(Int64.max))))
    }

    /// Bytes per second between two counter readings. Nil when a counter went down (reset, interface removed)
    /// or when seconds is not positive and finite.
    static func rate(prevRx: Int64, prevTx: Int64, rx: Int64, tx: Int64, seconds: TimeInterval) -> NetworkRate? {
        guard seconds > 0, seconds.isFinite, rx >= prevRx, tx >= prevTx else { return nil }
        return NetworkRate(rxPerSecond: Double(rx - prevRx) / seconds, txPerSecond: Double(tx - prevTx) / seconds)
    }
}

// MARK: - Routing message walking

struct RouteMessage: Equatable {
    var offset: Int
    var length: Int
    /// rtm_type / ifm_type, the byte at offset 3 of every routing message.
    var type: UInt8
}

enum RouteMessages {
    /// Common header: u_short msglen, u_char version, u_char type.
    static let headerSize = 4

    /// Splits a sysctl(NET_RT_*) buffer into messages. Stops at the first message that is too short,
    /// has length 0, or runs past `count`. Never reads outside the buffer.
    static func walk(_ buffer: [UInt8], count: Int) -> [RouteMessage] {
        let n = min(max(count, 0), buffer.count)
        var out = [RouteMessage]()
        var off = 0
        while off + headerSize <= n {
            let len = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: off, as: UInt16.self)) }
            if len < headerSize || off + len > n { break }
            out.append(RouteMessage(offset: off, length: len, type: buffer[off + 3]))
            off += len
        }
        return out
    }
}

// MARK: - Boot time

enum BootClock {
    /// kern.boottime follows the wall clock and can shift by a second or more (NTP). Return the previous
    /// value when the new one is within `tolerance` seconds; otherwise the new value rounded down to a second.
    static func stabilized(current: Date, previous: Date?, tolerance: TimeInterval = 10) -> Date {
        let rounded = Date(timeIntervalSince1970: current.timeIntervalSince1970.rounded(.down))
        if let previous, abs(rounded.timeIntervalSince(previous)) <= tolerance { return previous }
        return rounded
    }
}

// MARK: - Sample assembly

enum SampleAssembler {
    /// Builds one NDJSON row. `ok` describes the disk read only: any missing field makes ok=false with a short
    /// code in `err`; missing fields stay nil and are never replaced by 0. A failed network read leaves
    /// net_rx/net_tx nil and does not change `ok`.
    static func make(t: Date, src: DiskSource, vol: String = "/System/Volumes/Data",
                     total: Int64?, availImportant: Int64?, avail: Int64?, readError: String? = nil,
                     counters: [InterfaceCounters]?, boot: Date?) -> DiskSample {
        var err = readError
        if err == nil {
            if total == nil { err = "total_unavailable" }
            else if availImportant == nil { err = "important_unavailable" }
            else if avail == nil { err = "available_unavailable" }
            else if let tot = total, let ai = availImportant, tot <= 0 || ai < 0 || ai > tot { err = "implausible" }
        }
        let ok = err == nil
        var used: Int64?
        if ok, let total, let availImportant { used = total - availImportant }
        let net = counters.flatMap { NetworkFilter.total($0) }
        return DiskSample(t: t, src: src, ok: ok, vol: vol, total: total, availImportant: availImportant, avail: avail,
                          used: used, netRx: net?.rx, netTx: net?.tx, boot: boot, err: err)
    }
}

// MARK: - Engine evaluation step

/// Everything the engine keeps between evaluations. Pure value; the engine persists `alertState` only.
struct DiskEngineState {
    /// Nil until a verdict with data exists. Not saved: a restart starts from green and re-evaluates the history.
    var level: HealthLevel?
    var levelChangedAt: Date?
    var alertState = DiskAlertState()
    /// When each active alert type became active (in memory only).
    var alertSince: [String: Date] = [:]
}

struct PendingNotification {
    var alert: AlertItem
    var title: String
}

struct DiskEngineResult {
    var verdict: DiskVerdict
    var overall: StatusFile.Overall
    var items: StatusFile.Items
    var activeAlerts: [AlertItem]
    var notifications: [PendingNotification]
    /// The level differs from the previous one (a start from green counts).
    var levelChanged: Bool
    /// A new alert type became active, or a notification is due.
    var newAlert: Bool
}

enum DiskEngineLogic {
    /// One evaluation after a new sample. Call once per new sample, not on timer ticks without a sample:
    /// the hysteresis in `DiskHealth` lowers the level one step per call.
    /// since == levelChangedAt for a non-green level; both are nil while green and no change was seen.
    static func step(samples: [DiskSample], now: Date, todayStart: Date, state: DiskEngineState,
                     thresholds: DiskThresholds = DiskThresholds()) -> (DiskEngineResult, DiskEngineState) {
        var next = state
        let previous = state.level ?? .green
        var verdict = DiskHealth.evaluate(samples: samples, now: now, previous: previous, thresholds: thresholds)
        let noData = verdict.reasonCode == "no_data"

        var levelChanged = false
        if noData && state.level == nil {
            verdict.level = .unknown
        } else {
            if verdict.level != previous {
                levelChanged = true
                next.levelChangedAt = now
            }
            next.level = verdict.level
        }
        let levelSince: Date? = (verdict.level.colorRank ?? 0) >= 1 ? next.levelChangedAt : nil

        // Active alerts: conditions that hold now, independent of notification gating.
        var active = [AlertItem]()
        var activeTypes = Set<String>()
        func activeSince(_ type: String) -> Date { next.alertSince[type] ?? now }
        if let a = DiskAlertPolicy.growthAlert(verdict: verdict, since: activeSince("disk_growth"), state: DiskAlertState()) {
            active.append(a)
            activeTypes.insert(a.type)
        }
        if let a = DiskAlertPolicy.lowSpaceAlert(verdict: verdict, since: activeSince("disk_low_space"), state: DiskAlertState(), now: now) {
            active.append(a)
            activeTypes.insert(a.type)
        }
        var newType = false
        for type in activeTypes where next.alertSince[type] == nil {
            next.alertSince[type] = now
            newType = true
        }
        for type in Array(next.alertSince.keys) where !activeTypes.contains(type) { next.alertSince[type] = nil }

        // Notification decisions with the saved state (cooldown, 1.5x re-notify).
        DiskAlertPolicy.settle(verdict: verdict, into: &next.alertState)
        var pending = [PendingNotification]()
        if let g = DiskAlertPolicy.growthAlert(verdict: verdict, since: activeSince("disk_growth"), state: next.alertState),
           let bytes = verdict.triggerBytes {
            DiskAlertPolicy.record(growth: g, bytes: bytes, into: &next.alertState)
            pending.append(PendingNotification(alert: g, title: DiskAlertPolicy.growthTitle(verdict)))
        }
        if let l = DiskAlertPolicy.lowSpaceAlert(verdict: verdict, since: activeSince("disk_low_space"), state: next.alertState, now: now) {
            DiskAlertPolicy.recordLowSpace(at: now, into: &next.alertState)
            pending.append(PendingNotification(alert: l, title: DiskAlertPolicy.lowSpaceTitle(verdict)))
        }

        let disk = DiskItem.make(samples: samples, now: now, verdict: verdict, since: levelSince, levelChangedAt: next.levelChangedAt,
                                 thresholds: thresholds)
        let items = StatusFile.Items(disk: disk, network: NetworkItem.make(samples: samples, now: now, todayStart: todayStart))
        let overall = StatusFile.Overall(level: HealthLevel.worst([verdict.level]), summary: verdict.reason)
        let result = DiskEngineResult(verdict: verdict, overall: overall, items: items, activeAlerts: active,
                                      notifications: pending, levelChanged: levelChanged,
                                      newAlert: newType || !pending.isEmpty)
        return (result, next)
    }
}

// MARK: - Notification budget

/// Sliding-window cap on delivered notifications: 3 per hour and 10 per day (docs/PROJECT.md 5.1).
/// Held in memory only; a restart counts again from zero.
struct NotificationBudget {
    var perHour = 3
    var perDay = 10
    private var times = [Date]()

    init(perHour: Int = 3, perDay: Int = 10) {
        self.perHour = perHour
        self.perDay = perDay
    }

    /// Returns true and records the notification when both caps allow it. Entries in the future (clock moved back) are dropped.
    mutating func tryConsume(now: Date) -> Bool {
        times.removeAll { $0 > now || now.timeIntervalSince($0) >= 86400 }
        let lastHour = times.filter { now.timeIntervalSince($0) < 3600 }.count
        guard lastHour < perHour, times.count < perDay else { return false }
        times.append(now)
        return true
    }
}

// MARK: - Data directory and alert state files

enum AtomicFile {
    /// Same-directory temp file (0600), then rename(2). The directory is created with 0700.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            try h.write(contentsOf: data)
            if rename(tmp.path, url.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

enum AlertStateStore {
    static let fileName = "alert-state.json"

    static func url(dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    /// Nil when the file is missing or unreadable; the caller then starts from an empty state.
    static func load(dir: URL) -> DiskAlertState? {
        guard let data = try? Data(contentsOf: url(dir: dir)) else { return nil }
        return try? CoreJSON.decoder().decode(DiskAlertState.self, from: data)
    }

    static func encode(_ state: DiskAlertState) throws -> Data { try CoreJSON.encoder().encode(state) }

    static func save(_ state: DiskAlertState, dir: URL) throws {
        try AtomicFile.write(try encode(state), to: url(dir: dir))
    }
}

enum DataDirInspector {
    /// True when the directory holds any disk-*.ndjson file or alert-state.json.
    static func hasHistory(dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: AlertStateStore.url(dir: dir).path) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { $0.hasPrefix("disk-") && $0.hasSuffix(".ndjson") }
    }
}
