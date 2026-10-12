// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for CapacityText (docs/DESIGN_V2.md 6.3, gate W19).
// Pos: Called from main.swift via runCapacityTests(); no top-level code in this file. Owner WP-C.

import Foundation

/// Number at the front of "593 GB" or "12.50 TB".
private func number(_ s: String) -> Double { Double(s.split(separator: " ").first ?? "") ?? .nan }

private func unit(_ s: String) -> String { String(s.split(separator: " ").last ?? "") }

func runCapacityTests() {
    section("CapacityTests")
    expect(SidebarItem.allCases.count == 7, "six items and the anomaly log")
    expect(SidebarItem.allCases.map { $0.label }.contains("异常记录"), "anomaly log label")

    let d = CapacityFormat.disk(total: 994_662_584_320, used: 593_100_000_000, purgeable: 21_000_000_000)
    expect(d.total == "995 GB" && d.used == "593 GB" && d.available == "402 GB", "disk triple, got \(d.total) \(d.used) \(d.available)")
    expect(number(d.used) + number(d.available) == number(d.total), "disk used + available = total")
    expect(unit(d.used) == unit(d.total) && unit(d.available) == unit(d.total), "disk single unit")
    expect(d.usedOfTotal == "已用 593 / 995 GB" && d.purgeable == "21 GB", "disk note, got \(d.usedOfTotal)")
    expect(abs(d.segments.map { $0.fraction }.reduce(0, +) - 1) < 1e-9, "disk segments add to 1")

    // Rounding must not break the sum: three values whose rounded parts do not add up.
    let r = CapacityFormat.disk(total: 500_400_000_000, used: 200_450_000_000, purgeable: nil)
    expect(number(r.used) + number(r.available) == number(r.total), "rounded disk triple adds up, got \(r.used) \(r.available) \(r.total)")

    let tb = CapacityFormat.disk(total: 12_500_000_000_000, used: 4_000_000_000_000, purgeable: nil)
    expect(tb.unit == "TB" && tb.total == "12.50 TB" && tb.used == "4.00 TB" && tb.available == "8.50 TB", "TB switch, got \(tb.total) \(tb.used) \(tb.available)")
    expect(CapacityFormat.disk(total: 9_999_000_000_000, used: 1_000_000_000_000, purgeable: nil).unit == "GB", "below 10000 GB stays GB")

    let m = CapacityFormat.memory(total: 64 << 30, used: Int64(31.4 * Double(1 << 30)), split: nil)
    expect(m.total == "64 GB" && m.used == "31.4 GB" && m.available == "32.6 GB", "memory triple, got \(m.total) \(m.used) \(m.available)")
    expect(m.usedOfTotal == "已用 31.4 / 64 GB", "memory note, got \(m.usedOfTotal)")
    expect(number(m.used) + number(m.available) == number(m.total), "memory sum")
    let odd = CapacityFormat.memory(total: Int64(7.5 * Double(1 << 30)), used: 3 << 30, split: nil)
    expect(odd.total == "7.5 GB", "fractional total keeps the decimal, got \(odd.total)")

    for miss in [CapacityFormat.disk(total: nil, used: 1, purgeable: nil), CapacityFormat.disk(total: 1000, used: nil, purgeable: nil),
                 CapacityFormat.memory(total: nil, used: 1, split: nil)] {
        expect(miss.isMissing && miss.total == "—" && miss.used == "—" && miss.available == "—", "missing source gives three dashes")
        expect(miss.usedOfTotal == "已用 —", "missing note is 已用 —")
    }
    expect(CapacityFormat.disk(CurrentReadings()).isMissing, "empty readings: disk missing")
}
