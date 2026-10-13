// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Total, used and purgeable bytes of the disk, or total, used and the split of the memory (docs/DESIGN_V2.md 5.3, 6.3).
// Output: CapacityText: total, used and available as strings with one unit, the used-of-total line, and the bar segments.
// Pos: One formatter for the main column note ("已用 593 / 995 GB") and the sidebar capacity area, so both show the same strings (gate W19).
//      Foundation only. Owner WP-C. Disk uses decimal GB (10^9 B, like Finder). Memory uses binary GB (2^30 B, like Activity Monitor).
//      The displayed used plus the displayed available always equal the displayed total: the available value is the difference.

import Foundation

/// One part of the capacity bar. The fractions of all segments add up to 1 (within rounding).
struct CapacitySegment: Equatable {
    enum Kind: String, Equatable {
        case used, purgeable, free            // Disk
        case app, wired, compressed           // Memory (free is shared)
    }
    var kind: Kind
    var fraction: Double
}

struct CapacityText: Equatable {
    /// "995 GB", "64 GB", "12.50 TB". "—" when a source value is missing.
    var total: String
    var used: String
    var available: String
    /// Disk only: "21 GB". Nil for memory and when the value is missing.
    var purgeable: String?
    /// "GB" or "TB". Empty when missing.
    var unit: String
    var isMissing: Bool
    /// Number part of the used value ("593", "31.4"). "—" when missing.
    var usedNumber: String
    var segments: [CapacitySegment]

    static let missing = CapacityText(total: "—", used: "—", available: "—", purgeable: nil, unit: "", isMissing: true,
                                      usedNumber: "—", segments: [])

    /// The note line of the main column: "已用 593 / 995 GB". "已用 —" when a source value is missing (gate W19).
    var usedOfTotal: String {
        isMissing ? "已用 —" : "已用 " + usedNumber + " / " + total
    }

    /// The note line with the free part: "已用 875 / 995 GB，可用 120 GB". "已用 —" when a source value is missing.
    /// The free value is total minus used, the same string as the sidebar (gate W19).
    var usedOfTotalAvailable: String {
        isMissing ? "已用 —" : usedOfTotal + "，可用 " + available
    }

    /// The same value for a spoken label: "已用 593 吉字节，总容量 995 吉字节" is not needed. Plain text is enough.
    var accessibilityText: String {
        isMissing ? "容量不可用" : "总容量 " + total + "，已用 " + used + "，可用 " + available
    }
}

enum CapacityFormat {
    /// Integer value with `decimals` implied decimals: 5937 with 1 gives "593.7".
    static func fixed(_ value: Int64, decimals: Int) -> String {
        guard decimals > 0 else { return String(value) }
        var scale: Int64 = 1
        for _ in 0..<decimals { scale *= 10 }
        let whole = value / scale
        let part = value % scale
        var fraction = String(part)
        while fraction.count < decimals { fraction = "0" + fraction }
        return String(whole) + "." + fraction
    }

    private static func rounded(_ bytes: Int64, per unit: Double) -> Int64 {
        Int64((Double(bytes) / unit).rounded())
    }

    /// Disk capacity in decimal units. Total >= 10000 GB switches to TB with 2 decimals (DESIGN_V2.md 6.3).
    /// `used` is the real used space (total - available for important usage), `purgeable` the part of the free space
    /// that the system can release.
    static func disk(total: Int64?, used: Int64?, purgeable: Int64?) -> CapacityText {
        guard let total, let used, total > 0, used >= 0 else { return .missing }
        let useTB = Double(total) >= 10_000 * 1e9
        let unitBytes: Double = useTB ? 1e10 : 1e9        // hundredths of a TB, or whole GB
        let decimals = useTB ? 2 : 0
        let unit = useTB ? "TB" : "GB"
        let t = rounded(total, per: unitBytes)
        let u = min(t, rounded(used, per: unitBytes))
        let a = t - u
        var purgeText: String?
        var purgeValue: Int64 = 0
        if let purgeable, purgeable >= 0 {
            purgeValue = min(a, rounded(purgeable, per: unitBytes))
            purgeText = fixed(purgeValue, decimals: decimals) + " " + unit
        }
        let tf = Double(total)
        let usedFraction = min(1, Double(used) / tf)
        let purgeFraction = min(1 - usedFraction, Double(max(0, purgeable ?? 0)) / tf)
        let segments = [CapacitySegment(kind: .used, fraction: usedFraction),
                        CapacitySegment(kind: .purgeable, fraction: purgeFraction),
                        CapacitySegment(kind: .free, fraction: max(0, 1 - usedFraction - purgeFraction))]
        return CapacityText(total: fixed(t, decimals: decimals) + " " + unit, used: fixed(u, decimals: decimals) + " " + unit,
                            available: fixed(a, decimals: decimals) + " " + unit, purgeable: purgeText, unit: unit,
                            isMissing: false, usedNumber: fixed(u, decimals: decimals), segments: segments)
    }

    /// Memory capacity in binary GB with one decimal. A whole total is written without the decimal ("64 GB").
    /// `used` is app + wired + compressed (`MemoryBreakdown.used`).
    static func memory(total: Int64?, used: Int64?, split: MemoryBreakdown? = nil) -> CapacityText {
        guard let total, let used, total > 0, used >= 0 else { return .missing }
        let gib = Double(1 << 30) / 10          // tenths of a GB
        let t = rounded(total, per: gib)
        let u = min(t, rounded(used, per: gib))
        let a = t - u
        let totalText = (t % 10 == 0) ? String(t / 10) : fixed(t, decimals: 1)
        let tf = Double(total)
        var segments = [CapacitySegment]()
        if let split, let app = split.app, let wired = split.wired, let compressed = split.compressed {
            let fa = min(1, Double(app) / tf)
            let fw = min(1 - fa, Double(wired) / tf)
            let fc = min(1 - fa - fw, Double(compressed) / tf)
            segments = [CapacitySegment(kind: .app, fraction: fa), CapacitySegment(kind: .wired, fraction: fw),
                        CapacitySegment(kind: .compressed, fraction: fc),
                        CapacitySegment(kind: .free, fraction: max(0, 1 - fa - fw - fc))]
        } else {
            let fu = min(1, Double(used) / tf)
            segments = [CapacitySegment(kind: .used, fraction: fu), CapacitySegment(kind: .free, fraction: max(0, 1 - fu))]
        }
        return CapacityText(total: totalText + " GB", used: fixed(u, decimals: 1) + " GB",
                            available: fixed(a, decimals: 1) + " GB", purgeable: nil, unit: "GB", isMissing: false,
                            usedNumber: fixed(u, decimals: 1), segments: segments)
    }

    /// Disk capacity from the current readings.
    static func disk(_ r: CurrentReadings) -> CapacityText {
        disk(total: r.diskTotal, used: r.diskUsed, purgeable: r.diskPurgeable)
    }

    /// Memory capacity from the current readings. The total falls back to the physical memory.
    static func memory(_ r: CurrentReadings) -> CapacityText {
        let total = r.memory?.total ?? r.physicalMemory
        return memory(total: total, used: r.memory?.used, split: r.memory)
    }
}
