// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Raw page counts and `kern.memorystatus_level` from the sampler (Mac only); this file does the arithmetic.
// Output: MemoryBreakdown (app, wired and compressed memory in bytes, with the derived used and available values),
//         PressurePercent.from(level:) and DiskCapacity (the disk triple with total = used + available).
// Pos: Memory capacity vocabulary for the v2 capacity area (docs/DESIGN_V2.md 6.3, 12.2 D6); Foundation only. Owner WP-A. Nil means "not measured", never zero.

import Foundation

/// Memory split of the Activity Monitor style (DESIGN_V2.md 6.3). All values are bytes.
/// Used = app + wired + compressed. Available = total - used (it includes file cache and free pages).
struct MemoryBreakdown: Codable, Equatable {
    /// (`internal_page_count` - `purgeable_count`) x page size.
    var app: Int64?
    /// `wire_count` x page size.
    var wired: Int64?
    /// `compressor_page_count` x page size.
    var compressed: Int64?
    /// `hw.memsize`.
    var total: Int64?

    init(app: Int64? = nil, wired: Int64? = nil, compressed: Int64? = nil, total: Int64? = nil) {
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.total = total
    }

    /// Nil when any of the three parts is missing: a partial sum would look like a measured value.
    var used: Int64? {
        guard let app, let wired, let compressed else { return nil }
        return app + wired + compressed
    }

    /// Nil when the total or the used value is missing. Never negative.
    var available: Int64? {
        guard let total, let used else { return nil }
        return max(0, total - used)
    }
}

extension MemoryBreakdown {
    /// Builds the split from the raw `host_statistics64` counts (DESIGN_V2.md 6.3):
    /// app = (internal - purgeable) pages, wired = wire pages, compressed = compressor pages. All counts are pages.
    /// A missing or negative count gives nil for the part it feeds. A missing page size or total gives nil for all parts:
    /// without the page size no byte value exists. `purgeable` greater than `internal` clamps the app part to 0.
    static func make(internalPages: Int64?, purgeablePages: Int64?, wirePages: Int64?, compressorPages: Int64?,
                     pageSize: Int64?, total: Int64?) -> MemoryBreakdown {
        guard let pageSize, pageSize > 0 else { return MemoryBreakdown(total: total) }
        func bytes(_ pages: Int64?) -> Int64? {
            guard let pages, pages >= 0 else { return nil }
            let (product, overflow) = pages.multipliedReportingOverflow(by: pageSize)
            return overflow ? nil : product
        }
        var app: Int64?
        if let internalPages, let purgeablePages, internalPages >= 0, purgeablePages >= 0 {
            app = bytes(max(0, internalPages - purgeablePages))
        }
        return MemoryBreakdown(app: app, wired: bytes(wirePages), compressed: bytes(compressorPages), total: total)
    }
}

/// Memory pressure percent (DESIGN_V2.md 5.4). An approximate reading: the color follows the system pressure level.
enum PressurePercent {
    /// 100 - `kern.memorystatus_level`. Nil when the level is missing or outside 0...100. Never a guess.
    static func from(level: Int?) -> Int? {
        guard let level, (0...100).contains(level) else { return nil }
        return 100 - level
    }
}

/// The disk capacity triple of the capacity area (DESIGN_V2.md 6.3). `used` is the real used space
/// (total - available for important usage), so used + available = total. `purgeable` is a part of `available`.
struct DiskCapacity: Equatable {
    var total: Int64?
    var used: Int64?
    var available: Int64?
    var purgeable: Int64?

    /// From the three raw volume values. Nil values stay nil. The used value is derived from the total and the
    /// available value, so the sum is exact. An available value above the total, or a negative one, is not trusted.
    static func make(total: Int64?, availableImportant: Int64?, availableNow: Int64?) -> DiskCapacity {
        guard let total, total > 0 else { return DiskCapacity() }
        guard let availableImportant, availableImportant >= 0, availableImportant <= total else {
            return DiskCapacity(total: total)
        }
        var purgeable: Int64?
        if let availableNow, availableNow >= 0, availableImportant >= availableNow { purgeable = availableImportant - availableNow }
        return DiskCapacity(total: total, used: total - availableImportant, available: availableImportant, purgeable: purgeable)
    }
}
