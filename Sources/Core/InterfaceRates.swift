// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Two readings of the interface counters, the seconds between them and a map from BSD name to display name.
// Output: One InterfaceRate per physical interface (docs/DESIGN_V2.md 6.6, 12.2 D9).
// Pos: Pure logic behind the network sidebar; Foundation only. Physical interfaces come from NetworkFilter.isPhysical,
//      so VPN tunnels are never counted twice. Owner WP-A.

import Foundation

/// The speed and the totals of one physical interface.
struct InterfaceRate: Equatable {
    /// BSD name, for example "en0".
    var name: String
    /// Name for the person ("Wi-Fi"). Falls back to the BSD name when the system gives none.
    var displayName: String
    /// Bytes per second. Nil when there is no earlier reading, the counter went down (reset or wrap) or the time is
    /// not valid. Nil means "not measured", never 0.
    var downBytesPerSec: Double?
    var upBytesPerSec: Double?
    /// Counter values since the interface came up (since boot for most interfaces), as read now.
    var totalDown: Int64
    var totalUp: Int64
}

enum InterfaceRates {
    /// One entry per physical interface in `current`, sorted by BSD name. An interface that is gone from `current` has no
    /// entry. A new interface (not in `previous`) has nil rates for its first reading.
    static func make(previous: [InterfaceCounters]?, current: [InterfaceCounters], seconds: TimeInterval,
                     displayNames: [String: String]) -> [InterfaceRate] {
        var before = [String: InterfaceCounters]()
        for c in previous ?? [] { before[c.name] = c }
        var out = [InterfaceRate]()
        var seen = Set<String>()
        for c in current where NetworkFilter.isPhysical(c.name) && !seen.contains(c.name) {
            seen.insert(c.name)
            var down: Double?, up: Double?
            if let p = before[c.name], seconds > 0, seconds.isFinite {
                if c.rxBytes >= p.rxBytes { down = Double(c.rxBytes - p.rxBytes) / seconds }
                if c.txBytes >= p.txBytes { up = Double(c.txBytes - p.txBytes) / seconds }
            }
            let shown = displayNames[c.name].flatMap { $0.isEmpty ? nil : $0 } ?? c.name
            out.append(InterfaceRate(name: c.name, displayName: shown, downBytesPerSec: down, upBytesPerSec: up,
                                     totalDown: Int64(min(c.rxBytes, UInt64(Int64.max))),
                                     totalUp: Int64(min(c.txBytes, UInt64(Int64.max)))))
        }
        return out.sorted { $0.name < $1.name }
    }
}
