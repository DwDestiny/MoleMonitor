// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: events.json in the data directory (docs/DESIGN_V2.md 12.2 D2).
// Output: EventRecord (one problem stretch) and EventLog.read, which returns the records of the last N days.
// Pos: A1 contract skeleton: the types and the read signature are final, the read returns an empty result until A2 fills it in. Foundation only. Owner WP-A.
//      Only the display name of an app is kept. No path, no argument, no user name.

import Foundation

/// One problem stretch of one item.
struct EventRecord: Codable, Equatable {
    var item: HealthItem
    /// Level at the start and the worst level of the stretch.
    var first: HealthLevel
    var peak: HealthLevel
    var reasonCode: String
    var start: Date
    /// Nil while the problem goes on.
    var end: Date?
    var peakValue: Double?
    var unit: String?
    /// Display name only. Nil when the prompt setting "include app names" is off.
    var app: String?
    /// True when the end time was estimated (the app was not running when the problem ended).
    var endEstimated: Bool
}

enum EventLog {
    static let fileName = "events.json"
    static let version = 1
    /// At most 200 records and 30 days.
    static let maxRecords = 200
    static let maxDays = 30

    /// The records that overlap the last `days` days, newest first. Skeleton: always empty (filled in A2).
    static func read(dir: URL, days: Int, now: Date) -> [EventRecord] {
        []
    }
}
