// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, sample, now, GB, freshDir) defined in main.swift.
// Output: Assertions for NetworkFilter.swift: NIC filter, sums, rates, message walking, boot clock, sample assembly, engine step, budget, files.
// Pos: Called from main.swift via runNetworkTests(); no top-level code in this file.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func nic(_ name: String, _ rx: UInt64, _ tx: UInt64) -> InterfaceCounters {
    InterfaceCounters(name: name, rxBytes: rx, txBytes: tx)
}

/// Builds one fake routing message: native-endian u_short length, version, type, zero padding.
private func message(type: UInt8, length: Int, version: UInt8 = 5) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: length)
    withUnsafeBytes(of: UInt16(length)) { raw in
        b[0] = raw[0]
        b[1] = raw[1]
    }
    if length > 2 { b[2] = version }
    if length > 3 { b[3] = type }
    return b
}

func runNetworkTests() {
    section("NetworkFilter.isPhysical")
    for name in ["en0", "en1", "en12", "pdp_ip0", "pdp_ip3"] {
        expect(NetworkFilter.isPhysical(name), "\(name) is counted")
    }
    for name in ["lo0", "utun0", "utun4", "awdl0", "llw0", "bridge0", "bridge100", "ap1", "gif0", "stf0", "anpi0", "vmenet0"] {
        expect(!NetworkFilter.isPhysical(name), "\(name) is excluded")
    }
    for name in ["", "e", "wlan0", "eth0", "EN0", "xen0", "p2p0"] {
        expect(!NetworkFilter.isPhysical(name), "\(name.isEmpty ? "(empty)" : name) is not counted (no included prefix)")
    }

    section("NetworkFilter.total")
    let mixed = [nic("lo0", 1_000, 1_000), nic("en0", 500, 50), nic("utun3", 9_000, 9_000), nic("en1", 300, 30),
                 nic("bridge0", 777, 777), nic("awdl0", 5, 5), nic("pdp_ip0", 20, 2)]
    let t = NetworkFilter.total(mixed)
    expect(t?.rx == 820 && t?.tx == 82, "sum counts en0, en1, pdp_ip0 only: \(String(describing: t))")
    expect(NetworkFilter.total([]) == nil, "empty list gives nil")
    expect(NetworkFilter.total([nic("lo0", 5, 5), nic("utun0", 6, 6)]) == nil, "only virtual interfaces gives nil, not 0")
    let zero = NetworkFilter.total([nic("en0", 0, 0)])
    expect(zero?.rx == 0 && zero?.tx == 0, "measured zero stays 0")
    let big = NetworkFilter.total([nic("en0", UInt64.max, 1), nic("en1", 5, 1)])
    expect(big?.rx == Int64.max && big?.tx == 2, "overflow is clamped to Int64.max")
    let large = NetworkFilter.total([nic("en0", 5_000_000_000_000, 3_000_000_000_000)])
    expect(large?.rx == 5_000_000_000_000 && large?.tx == 3_000_000_000_000, "values above 32 bit keep full width")

    section("NetworkFilter.rate")
    let r = NetworkFilter.rate(prevRx: 1_000, prevTx: 100, rx: 3_000, tx: 600, seconds: 2)
    expect(r == NetworkRate(rxPerSecond: 1_000, txPerSecond: 250), "rate 1000/250 per second: \(String(describing: r))")
    let idle = NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 5, tx: 5, seconds: 2)
    expect(idle == NetworkRate(rxPerSecond: 0, txPerSecond: 0), "equal counters give measured 0, not nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 4, tx: 9, seconds: 2) == nil, "rx counter went down: nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 9, tx: 4, seconds: 2) == nil, "tx counter went down: nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 9, tx: 9, seconds: 0) == nil, "zero time difference: nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 9, tx: 9, seconds: -1) == nil, "negative time difference: nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 9, tx: 9, seconds: .nan) == nil, "NaN time difference: nil")
    expect(NetworkFilter.rate(prevRx: 5, prevTx: 5, rx: 9, tx: 9, seconds: .infinity) == nil, "infinite time difference: nil")

    section("RouteMessages.walk")
    let m1 = message(type: 0x12, length: 192)
    let m2 = message(type: 0x0e, length: 16)
    let m3 = message(type: 0x12, length: 192)
    let buf = m1 + m2 + m3
    let walked = RouteMessages.walk(buf, count: buf.count)
    expect(walked == [RouteMessage(offset: 0, length: 192, type: 0x12), RouteMessage(offset: 192, length: 16, type: 0x0e),
                      RouteMessage(offset: 208, length: 192, type: 0x12)], "three messages: \(walked)")
    expect(RouteMessages.walk(buf, count: 0).isEmpty, "count 0: nothing")
    expect(RouteMessages.walk([], count: 100).isEmpty, "empty buffer: nothing")
    expect(RouteMessages.walk(buf, count: -5).isEmpty, "negative count: nothing")
    expect(RouteMessages.walk(buf, count: 3).isEmpty, "shorter than a header: nothing")
    expect(RouteMessages.walk(buf, count: 1_000_000).count == 3, "count above buffer size is clamped")
    expect(RouteMessages.walk(buf, count: 200).count == 1, "truncated second message is dropped")
    expect(RouteMessages.walk(buf, count: 191).isEmpty, "truncated first message: nothing")
    let zeroLen = m1 + [UInt8](repeating: 0, count: 16) + m3
    expect(RouteMessages.walk(zeroLen, count: zeroLen.count).count == 1, "length 0 stops the walk (no endless loop)")
    let shortLen = m1 + message(type: 0x12, length: 4)
    expect(RouteMessages.walk(shortLen, count: shortLen.count).count == 2, "a 4-byte message (header only) is valid")
    var badLen = m2
    badLen[0] = 3
    badLen[1] = 0
    expect(RouteMessages.walk(badLen, count: badLen.count).isEmpty, "length below header size stops the walk")

    section("BootClock")
    let boot = UTCTime.parseISO("2026-10-08T01:02:03Z")!
    expect(BootClock.stabilized(current: boot.addingTimeInterval(0.9), previous: nil) == boot, "no previous: rounded down to a second")
    expect(BootClock.stabilized(current: boot.addingTimeInterval(2.4), previous: boot) == boot, "2 s jitter keeps previous")
    expect(BootClock.stabilized(current: boot.addingTimeInterval(-9), previous: boot) == boot, "jitter backwards keeps previous")
    expect(BootClock.stabilized(current: boot.addingTimeInterval(300.7), previous: boot) == boot.addingTimeInterval(300),
           "a 5 minute difference is a new boot")
    expect(BootClock.stabilized(current: boot.addingTimeInterval(10.5), previous: boot) == boot, "10.5 s rounds to 10 s: still within tolerance")
    expect(BootClock.stabilized(current: boot.addingTimeInterval(11.2), previous: boot) == boot.addingTimeInterval(11),
           "11 s is outside the tolerance")

    section("SampleAssembler")
    let counters = [nic("en0", 700, 70), nic("utun1", 999, 999), nic("en1", 300, 30)]
    let good = SampleAssembler.make(t: now, src: .launch, total: 1000 * GB, availImportant: 400 * GB, avail: 380 * GB,
                                    counters: counters, boot: boot)
    expect(good.ok && good.err == nil && good.used == 600 * GB && good.realUsed == 600 * GB, "ok sample: used = total - important")
    expect(good.netRx == 1000 && good.netTx == 100 && good.boot == boot && good.src == .launch, "network sum, boot and src kept")
    let noImportant = SampleAssembler.make(t: now, src: .timer, total: 1000 * GB, availImportant: nil, avail: 380 * GB,
                                           counters: counters, boot: boot)
    expect(!noImportant.ok && noImportant.err == "important_unavailable" && noImportant.availImportant == nil && noImportant.used == nil,
           "missing important capacity: ok=false, field nil, not 0")
    expect(noImportant.realUsed == nil && noImportant.total == 1000 * GB, "failed row has no real used but keeps other readings")
    let noTotal = SampleAssembler.make(t: now, src: .timer, total: nil, availImportant: nil, avail: nil, counters: nil, boot: nil)
    expect(!noTotal.ok && noTotal.err == "total_unavailable" && noTotal.netRx == nil && noTotal.netTx == nil, "nothing read: total_unavailable")
    let noAvail = SampleAssembler.make(t: now, src: .timer, total: 1000 * GB, availImportant: 400 * GB, avail: nil, counters: nil, boot: nil)
    expect(!noAvail.ok && noAvail.err == "available_unavailable", "missing plain available capacity: ok=false")
    let silly = SampleAssembler.make(t: now, src: .timer, total: 1000 * GB, availImportant: 1100 * GB, avail: 1 * GB, counters: nil, boot: nil)
    expect(!silly.ok && silly.err == "implausible" && silly.used == nil, "important > total: implausible")
    let zeroTotal = SampleAssembler.make(t: now, src: .timer, total: 0, availImportant: 0, avail: 0, counters: nil, boot: nil)
    expect(!zeroTotal.ok && zeroTotal.err == "implausible", "total 0: implausible")
    let thrown = SampleAssembler.make(t: now, src: .panel, total: nil, availImportant: nil, avail: nil, readError: "read_failed",
                                      counters: nil, boot: nil)
    expect(!thrown.ok && thrown.err == "read_failed" && thrown.src == .panel, "explicit read error wins")
    let onlyVirtual = SampleAssembler.make(t: now, src: .timer, total: 1000 * GB, availImportant: 400 * GB, avail: 380 * GB,
                                           counters: [nic("lo0", 1, 1)], boot: nil)
    expect(onlyVirtual.ok && onlyVirtual.netRx == nil && onlyVirtual.netTx == nil, "no physical NIC: counters nil, disk still ok")
    let line = String(decoding: (try? CoreJSON.encoder().encode(good)) ?? Data(), as: UTF8.self)
    expect(line.contains("\"boot\":\"2026-10-08T01:02:03Z\"") && line.contains("\"net_rx\":1000"), "row JSON has boot and net_rx: \(line)")

    section("DiskEngineLogic")
    let todayStart = ago(12)
    func step(_ s: [DiskSample], _ st: DiskEngineState, at: Date = now) -> (DiskEngineResult, DiskEngineState) {
        DiskEngineLogic.step(samples: s, now: at, todayStart: todayStart, state: st)
    }
    do {
        // No data at all: unknown, nothing remembered.
        let (r, st) = step([], DiskEngineState())
        expect(r.overall.level == .unknown && r.items.disk.level == .unknown && st.level == nil, "no data: level unknown, state level stays nil")
        expect(!r.levelChanged && r.activeAlerts.isEmpty && r.notifications.isEmpty && !r.newAlert, "no data: no change, no alerts")
        expect(r.items.disk.total.value == nil && r.items.disk.total.status == .collecting, "no data: total is null/collecting")
        let failedOnly = step([failedSample(0)], DiskEngineState())
        expect(failedOnly.0.items.disk.level == .unknown && failedOnly.0.items.disk.total.status == .failed, "failed sample only: unknown, status failed")
    }
    do {
        // Green start.
        let (r, st) = step(flatSeries(100), DiskEngineState())
        expect(r.items.disk.level == .green && st.level == .green && !r.levelChanged, "green start: no level change")
        expect(r.items.disk.since == nil && r.items.disk.levelChangedAt == nil, "green start: since and level_changed_at are nil")
        expect(r.activeAlerts.isEmpty && r.notifications.isEmpty && !r.newAlert, "green: no alerts")
        expect(r.overall.level == .green && r.overall.summary == "磁盘正常", "overall follows disk: \(r.overall.summary)")
        expect(r.items.network.note == NetworkItem.defaultNote, "network item present")
    }
    do {
        // Start straight into red from history: previous green, no saved level.
        let series = [sample(110, usedGB: 100), sample(30, usedGB: 400), sample(0, usedGB: 400)]
        let (r1, s1) = step(series, DiskEngineState())
        expect(r1.items.disk.level == .red && r1.levelChanged && s1.level == .red, "history already red: level change from green")
        expect(r1.items.disk.since == now && r1.items.disk.levelChangedAt == now, "since == level_changed_at == now")
        expect(r1.activeAlerts.count == 1 && r1.activeAlerts[0].type == "disk_growth" && r1.activeAlerts[0].since == now, "one active growth alert since now")
        expect(r1.notifications.count == 1 && r1.notifications[0].title.contains("磁盘 5 天多占用了"), "one notification with growth title: \(r1.notifications.first?.title ?? "-")")
        expect(r1.notifications[0].alert.message.contains("已排除可清除空间"), "notification body is the alert message")
        expect(r1.newAlert && s1.alertState.lastGrowthNotifiedBytes != nil && s1.alertSince["disk_growth"] == now, "state recorded the notification and the alert start")

        // Second evaluation 15 minutes later with the same data: no new notification, since kept.
        let later = now.addingTimeInterval(900)
        let (r2, s2) = step(series, s1, at: later)
        expect(r2.notifications.isEmpty && !r2.newAlert && !r2.levelChanged, "same data later: no notification, no new alert")
        expect(r2.activeAlerts.count == 1 && r2.activeAlerts[0].since == now, "active alert keeps its original since")
        expect(r2.items.disk.levelChangedAt == now && s2.levelChangedAt == now, "level_changed_at stays at the change time")

        // App restart: logic state is new, alert state is loaded from disk. No repeated notification.
        var restarted = DiskEngineState()
        restarted.alertState = s2.alertState
        let (r3, s3) = step(series, restarted, at: later)
        expect(r3.notifications.isEmpty, "restart with saved alert state: no repeated notification")
        expect(r3.activeAlerts.count == 1 && r3.items.disk.level == .red && r3.levelChanged, "restart: still active and red (level starts from green)")
        expect(r3.newAlert && s3.alertSince["disk_growth"] == later, "restart: alert counted as new for the status write")

        // Growth rises 1.5x or more: notify again.
        let bigger = [sample(110, usedGB: 100), sample(30, usedGB: 580), sample(0, usedGB: 580)]
        let (r4, _) = step(bigger, s2, at: later)
        expect(r4.notifications.count == 1, "growth up by 1.5x: notify again")

        // Everything back to normal: alerts vanish, no recovered state, level steps down one level per evaluation.
        let calm = [sample(110, usedGB: 100), sample(0, usedGB: 100)]
        let (r5, s5) = step(calm, s2, at: later)
        expect(r5.activeAlerts.isEmpty && r5.notifications.isEmpty, "growth gone: no active alerts, no notification")
        expect(r5.items.disk.level == .yellow && r5.levelChanged && s5.alertSince.isEmpty, "red steps down to yellow first")
        expect(s5.alertState.lastGrowthNotifiedBytes == nil, "settle forgets the last growth notification")
        let (r6, _) = step(calm, s5, at: later.addingTimeInterval(900))
        expect(r6.items.disk.level == .green && r6.items.disk.since == nil, "second evaluation: green, since nil")
        expect(r6.items.disk.levelChangedAt == later.addingTimeInterval(900), "level_changed_at records the step to green")
        let encoded = String(decoding: (try? CoreJSON.encoder().encode(r6.items.disk)) ?? Data(), as: UTF8.self).lowercased()
        expect(!encoded.contains("recover") && !encoded.contains("resolved"), "no recovered wording in the status item")
    }
    do {
        // Low free space.
        let series = flatSeries(960)
        let (r1, s1) = step(series, DiskEngineState())
        expect(r1.items.disk.level == .red, "960 of 1000 GB used: red")
        expect(r1.activeAlerts.contains { $0.type == "disk_low_space" && $0.level == .red }, "active low-space alert")
        expect(r1.notifications.count == 1 && r1.notifications[0].alert.type == "disk_low_space"
               && r1.notifications[0].title.contains("磁盘剩余空间只有"), "one low-space notification")
        expect(s1.alertState.lastLowSpaceNotifiedAt == now, "cooldown start recorded")
        let (r2, _) = step(series, s1, at: now.addingTimeInterval(23 * 3600 - 7200))
        expect(r2.notifications.isEmpty, "inside 24 h cooldown: no notification")
        // Samples older than 2 h would be no_data; give a fresh sample at the later time.
        let later = now.addingTimeInterval(25 * 3600)
        let freshSeries = [DiskSample(t: later, total: 1000 * GB, availImportant: 40 * GB, avail: 40 * GB)]
        let (r3, _) = step(freshSeries, s1, at: later)
        expect(r3.notifications.count == 1, "after 24 h and with a fresh sample: notify again")
        // Both rules at once: growth and low space.
        let both = [sample(120, usedGB: 100), sample(30, usedGB: 400), sample(0, usedGB: 960)]
        let (r4, _) = step(both, DiskEngineState())
        expect(r4.activeAlerts.map { $0.type }.sorted() == ["disk_growth", "disk_low_space"], "both alert types can be active together")
        expect(r4.notifications.count == 2, "two notifications when both rules fire")
    }
    do {
        // Yellow only for free space does not notify; level yellow is reported.
        let (r, _) = step(flatSeries(860), DiskEngineState())
        expect(r.items.disk.level == .yellow && r.notifications.isEmpty && r.activeAlerts.isEmpty, "yellow free space: level yellow, no alert, no notification")
        expect(r.items.disk.since == now, "yellow since")
        // Level held by hysteresis after data goes older than the limit: unchanged, no_data.
        var st = DiskEngineState()
        st.level = .yellow
        st.levelChangedAt = ago(5)
        let (r2, s2) = step([sample(5, usedGB: 860)], st)
        expect(r2.verdict.reasonCode == "no_data" && r2.items.disk.level == .yellow && !r2.levelChanged && s2.levelChangedAt == ago(5),
               "stale data keeps the known level")
    }

    section("NotificationBudget")
    do {
        var b = NotificationBudget()
        let t0 = now
        expect(b.tryConsume(now: t0) && b.tryConsume(now: t0.addingTimeInterval(10)) && b.tryConsume(now: t0.addingTimeInterval(20)),
               "three in a row are allowed")
        expect(!b.tryConsume(now: t0.addingTimeInterval(30)), "fourth within the hour is refused")
        expect(!b.tryConsume(now: t0.addingTimeInterval(3599)), "still inside the first notification's hour")
        expect(b.tryConsume(now: t0.addingTimeInterval(3600)), "the first one left the hour window")
        // Daily cap: spread out so the hourly cap never blocks.
        var d = NotificationBudget()
        var allowed = 0
        for i in 0..<14 where d.tryConsume(now: t0.addingTimeInterval(Double(i) * 4000)) { allowed += 1 }
        expect(allowed == 10, "daily cap is 10 (got \(allowed))")
        expect(!d.tryConsume(now: t0.addingTimeInterval(14 * 4000)), "day not over (56000 s): still refused")
        expect(d.tryConsume(now: t0.addingTimeInterval(86401)), "the first notification left the day window: one slot opens")
        var c = NotificationBudget(perHour: 1, perDay: 2)
        expect(c.tryConsume(now: t0) && !c.tryConsume(now: t0.addingTimeInterval(1)), "custom hourly cap")
        expect(c.tryConsume(now: t0.addingTimeInterval(-86400 - 10)) , "clock moved far back: old entries are dropped, one allowed")
    }

    section("AlertStateStore / AtomicFile / DataDirInspector")
    do {
        let dir = freshDir("network-alert-state")
        expect(!DataDirInspector.hasHistory(dir: dir), "missing directory: no history")
        expect(AlertStateStore.load(dir: dir) == nil, "missing file loads nil")
        var st = DiskAlertState()
        st.lastGrowthNotifiedBytes = 312 * GB
        st.lastGrowthLevel = .red
        st.lastLowSpaceNotifiedAt = now
        do {
            try AlertStateStore.save(st, dir: dir)
            let back = AlertStateStore.load(dir: dir)
            expect(back?.lastGrowthNotifiedBytes == 312 * GB && back?.lastGrowthLevel == .red && back?.lastLowSpaceNotifiedAt == now,
                   "alert state round trip")
            expect(mode(AlertStateStore.url(dir: dir)) == 0o600, "alert-state.json mode 0600")
            expect(DataDirInspector.hasHistory(dir: dir), "alert-state.json counts as history")
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".tmp") }
            expect(leftovers.isEmpty, "no temp files left")
            let text = String(decoding: try AlertStateStore.encode(st), as: UTF8.self)
            expect(text.contains("\"last_growth_notified_bytes\":312000000000"), "snake_case keys: \(text)")
        } catch {
            expect(false, "alert state save failed: \(error)")
        }
        try? Data("not json".utf8).write(to: AlertStateStore.url(dir: dir))
        expect(AlertStateStore.load(dir: dir) == nil, "corrupt file loads nil")
        let hist = freshDir("network-history")
        try? FileManager.default.createDirectory(at: hist, withIntermediateDirectories: true)
        expect(!DataDirInspector.hasHistory(dir: hist), "empty directory: no history")
        try? Data("x".utf8).write(to: hist.appendingPathComponent("status.json"))
        expect(!DataDirInspector.hasHistory(dir: hist), "status.json alone is not history")
        try? Data().write(to: hist.appendingPathComponent("disk-2026-10.ndjson"))
        expect(DataDirInspector.hasHistory(dir: hist), "disk-*.ndjson counts as history")
    }
}
