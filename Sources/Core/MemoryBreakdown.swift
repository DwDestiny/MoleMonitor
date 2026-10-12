// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: None (type definitions; the sampler fills them in A2).
// Output: MemoryBreakdown: app, wired and compressed memory in bytes, with the derived used and available values.
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
