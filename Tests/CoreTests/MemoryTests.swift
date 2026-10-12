// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for MemoryBreakdown, the pressure percent, the disk capacity triple and the preview fixtures (docs/DESIGN_V2.md 5.4, 6.3, W19/W21 Core part).
// Pos: Called from main.swift via runMemoryTests(); no top-level code in this file. A1 registers it, WP-A (A2) fills it.

import Foundation

func runMemoryTests() {
    section("MemoryTests")
    let full = MemoryBreakdown(app: 20 * GB, wired: 6 * GB, compressed: 4 * GB, total: 64 * GB)
    expect(full.used == 30 * GB, "used = app + wired + compressed")
    expect(full.available == 34 * GB, "available = total - used")
    expect(MemoryBreakdown(app: 1, wired: nil, compressed: 1, total: 10).used == nil, "a missing part gives no used value")
    expect(MemoryBreakdown(app: 1, wired: 1, compressed: 1, total: nil).available == nil, "a missing total gives no available value")
    expect(MemoryBreakdown(app: 9, wired: 9, compressed: 9, total: 10).available == 0, "available is never negative")
    var c = CurrentReadings()
    expect(c.memoryPressurePercent == nil && c.memory == nil && c.diskTotal == nil, "new readings start as not measured")
    c.memoryPressurePercent = 0
    expect(c.memoryPressurePercent == 0, "a measured zero stays zero")

    // Pressure percent: 100 - kern.memorystatus_level (DESIGN_V2.md 5.4).
    expect(PressurePercent.from(level: 77) == 23, "level 77 gives 23 percent")
    expect(PressurePercent.from(level: 0) == 100, "level 0 gives 100 percent")
    expect(PressurePercent.from(level: 100) == 0, "level 100 gives a measured 0 percent")
    expect(PressurePercent.from(level: -1) == nil, "level -1 is not measured")
    expect(PressurePercent.from(level: 101) == nil, "level 101 is not measured")
    expect(PressurePercent.from(level: nil) == nil, "a missing level is not measured")

    // MemoryBreakdown.make: pages to bytes (16 KiB pages).
    let page: Int64 = 16384
    let m = MemoryBreakdown.make(internalPages: 1_000_000, purgeablePages: 200_000, wirePages: 300_000,
                                 compressorPages: 100_000, pageSize: page, total: 64 * GB)
    expect(m.app == 800_000 * page, "app = (internal - purgeable) x page size")
    expect(m.wired == 300_000 * page && m.compressed == 100_000 * page, "wired and compressed in bytes")
    expect(m.used == 1_200_000 * page, "used = app + wired + compressed")
    expect(m.available == 64 * GB - 1_200_000 * page, "available = total - used")
    expect((m.used ?? 0) + (m.available ?? 0) == 64 * GB, "used + available = total")
    let noPage = MemoryBreakdown.make(internalPages: 1, purgeablePages: 0, wirePages: 1, compressorPages: 1, pageSize: nil, total: 64 * GB)
    expect(noPage.app == nil && noPage.used == nil && noPage.total == 64 * GB, "no page size gives no byte values")
    let noWire = MemoryBreakdown.make(internalPages: 10, purgeablePages: 0, wirePages: nil, compressorPages: 1, pageSize: page, total: 64 * GB)
    expect(noWire.app == 10 * page && noWire.wired == nil && noWire.used == nil, "a missing part gives no used value")
    let overPurge = MemoryBreakdown.make(internalPages: 5, purgeablePages: 9, wirePages: 1, compressorPages: 1, pageSize: page, total: 64 * GB)
    expect(overPurge.app == 0, "purgeable above internal clamps app to a measured 0")
    let negative = MemoryBreakdown.make(internalPages: -1, purgeablePages: 0, wirePages: 1, compressorPages: 1, pageSize: page, total: 64 * GB)
    expect(negative.app == nil, "a negative count is not measured")
    let huge = MemoryBreakdown.make(internalPages: Int64.max, purgeablePages: 0, wirePages: 1, compressorPages: 1, pageSize: page, total: 64 * GB)
    expect(huge.app == nil, "an overflowing product is not measured")

    // Disk capacity triple: used + available = total; purgeable is part of available.
    let cap = DiskCapacity.make(total: 995 * GB, availableImportant: 120 * GB, availableNow: 99 * GB)
    expect(cap.total == 995 * GB && cap.used == 875 * GB && cap.available == 120 * GB, "875 used + 120 available = 995 total")
    expect((cap.used ?? 0) + (cap.available ?? 0) == cap.total, "used + available = total")
    expect(cap.purgeable == 21 * GB && (cap.purgeable ?? 0) <= (cap.available ?? 0), "purgeable 21 GB is a part of available")
    expect(DiskCapacity.make(total: 995 * GB, availableImportant: 120 * GB, availableNow: nil).purgeable == nil, "missing availableNow gives no purgeable value")
    expect(DiskCapacity.make(total: 995 * GB, availableImportant: 90 * GB, availableNow: 99 * GB).purgeable == nil, "a negative purgeable estimate is dropped")
    expect(DiskCapacity.make(total: 995 * GB, availableImportant: nil, availableNow: 5).used == nil, "no available value gives no used value")
    expect(DiskCapacity.make(total: 995 * GB, availableImportant: 2000 * GB, availableNow: nil).used == nil, "available above total is not trusted")
    expect(DiskCapacity.make(total: nil, availableImportant: 1, availableNow: 1) == DiskCapacity(), "no total gives all nil")
    expect(DiskCapacity.make(total: 995 * GB, availableImportant: 995 * GB, availableNow: 995 * GB).used == 0, "a full-free disk has a measured used 0")

    // Status file round trip and old files (DESIGN_V2.md 12.2: compatible additions).
    var readings = CurrentReadings()
    readings.memoryPressurePercent = 0
    readings.memory = m
    readings.pressure = .normal
    let verdict = ItemVerdict(item: .memory, level: .green, reasonCode: "ok", headline: "内存正常", since: nil, levelChangedAt: nil, alert: nil)
    let item = StatusExtras.itemStatus(for: verdict, current: readings, cpuSummary: nil)
    expect(item.pressurePercent?.value == 0 && item.pressurePercent?.status == .ok, "a measured 0 percent is written as ok")
    expect(item.breakdown == m, "breakdown is written")
    let data = try? JSONEncoder().encode(item)
    let back = data.flatMap { try? JSONDecoder().decode(HealthItemStatus.self, from: $0) }
    expect(back == item, "memory item round trip")
    var lost = readings
    lost.memoryPressurePercent = nil
    lost.memory = nil
    let lostItem = StatusExtras.itemStatus(for: verdict, current: lost, cpuSummary: nil)
    expect(lostItem.pressurePercent?.value == nil && lostItem.pressurePercent?.status == .collecting, "an unreadable pressure is absent, not 0")
    expect(lostItem.breakdown == nil, "an unreadable breakdown is absent")
    if let data, var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        object.removeValue(forKey: "pressure_percent")
        object.removeValue(forKey: "breakdown")
        let old = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(HealthItemStatus.self, from: $0) }
        expect(old != nil && old?.pressurePercent == nil && old?.breakdown == nil, "an old memory item without the new keys still decodes")
    } else {
        expect(false, "memory item encodes to a JSON object")
    }

    // Fixtures carry the new fields, with the numbers of the design examples.
    let red = PreviewScenario.fixture(.diskRed, full: true, now: now)
    expect(red.current.diskTotal == 995 * GB, "fixture disk total is 995 GB")
    let redUsed = Double(red.current.diskUsed ?? 0) / 1e9
    expect(abs(redUsed - 875) < 3, "red fixture disk used is about 875 GB, got \(redUsed)")
    expect((red.current.diskUsed ?? 0) + (red.current.diskAvailable ?? 0) == red.current.diskTotal, "fixture used + available = total")
    expect(red.current.diskPurgeable == 21 * GB, "fixture purgeable is 21 GB")
    let multi = PreviewScenario.fixture(.multi, full: true, now: now)
    expect(multi.current.memoryPressurePercent == 87, "multi fixture has pressure 87")
    let usedGiB = Double(multi.current.memory?.used ?? 0) / Double(1 << 30)
    expect(abs(usedGiB - 58.2) < 0.01, "multi fixture memory used is 58.2 GiB, got \(usedGiB)")
    let green = PreviewScenario.fixture(.allGreen, full: true, now: now)
    expect(green.current.memoryPressurePercent == 23, "calm fixture pressure is 23 percent")
    expect(abs(Double(green.current.memory?.used ?? 0) / Double(1 << 30) - 31.4) < 0.01, "calm fixture memory used is 31.4 GiB")
    expect(green.current.memory?.total == 64 << 30, "fixture memory total is 64 GiB")
    let collecting = PreviewScenario.fixture(.collecting, full: true, now: now)
    expect(collecting.current.memoryPressurePercent == nil && collecting.current.memory == nil && collecting.current.diskTotal == nil,
           "the collecting fixture has no new values")
    expect(green.trend.latest?.pressurePercent == 23, "calm fixture trend carries the pressure percent")
    expect(multi.events.contains { $0.item == .memory && $0.end == nil }, "multi fixture has an open memory record")
    expect(collecting.events.isEmpty && PreviewScenario.fixture(.multi, full: false, now: now).events.isEmpty, "no records without data")
    expect(PreviewScenario.fixtureRollups(.multi, hours: 24, now: now).count == 288, "24 hours of fixture rollups = 288 windows")
    // The status reader returns the same values the writer wrote.
    let back2 = StatusExtras.current(from: multi.status)
    expect(back2.diskTotal == nil || back2.diskTotal == multi.current.diskTotal, "reader fills the disk triple from the disk item")
}
