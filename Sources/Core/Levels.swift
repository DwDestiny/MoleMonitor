// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Raw values and timestamps from callers.
// Output: Health levels, value statuses, the Measured wrapper, UTC date helpers and shared JSON coders.
// Pos: Core vocabulary shared by the app and the CLI; Foundation only.

import Foundation

enum HealthLevel: String, Codable {
    case green, yellow, red, unknown, stale
    case notApplicable = "not_applicable"

    /// Badness order used for "worst level" roll-ups: green < unknown < stale < yellow < red.
    var severity: Int {
        switch self {
        case .notApplicable: return -1
        case .green: return 0
        case .unknown: return 1
        case .stale: return 2
        case .yellow: return 3
        case .red: return 4
        }
    }

    /// 0/1/2 for green/yellow/red; nil for levels that carry no measurement.
    var colorRank: Int? {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .red: return 2
        default: return nil
        }
    }

    static func fromColorRank(_ r: Int) -> HealthLevel { r >= 2 ? .red : (r == 1 ? .yellow : .green) }

    /// Worst level of the list; ignores not_applicable; empty list gives unknown.
    static func worst(_ levels: [HealthLevel]) -> HealthLevel {
        let counted = levels.filter { $0 != .notApplicable }
        return counted.max { $0.severity < $1.severity } ?? .unknown
    }

    /// Chinese label for one-line output.
    var label: String {
        switch self {
        case .green: return "绿"
        case .yellow: return "黄"
        case .red: return "红"
        case .unknown: return "未知"
        case .stale: return "过期"
        case .notApplicable: return "不适用"
        }
    }
}

enum ValueStatus: String, Codable {
    case ok, collecting
    case insufficientWindow = "insufficient_window"
    case missing, failed, stale
    case notApplicable = "not_applicable"
}

/// A value with unit and status. `value` is always written; it is null when absent.
struct Measured<T: Codable>: Codable {
    var value: T?
    var unit: String
    var status: ValueStatus
    var sampledAt: Date?

    enum CodingKeys: String, CodingKey {
        case value, unit, status
        case sampledAt = "sampled_at"
    }

    init(value: T?, unit: String, status: ValueStatus, sampledAt: Date? = nil) {
        self.value = value
        self.unit = unit
        self.status = status
        self.sampledAt = sampledAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(T.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        status = try c.decode(ValueStatus.self, forKey: .status)
        sampledAt = try c.decodeIfPresent(Date.self, forKey: .sampledAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(unit, forKey: .unit)
        try c.encode(status, forKey: .status)
        try c.encode(sampledAt, forKey: .sampledAt)
    }

    static func ok(_ v: T, unit: String, at: Date?) -> Measured<T> {
        Measured(value: v, unit: unit, status: .ok, sampledAt: at)
    }

    static func absent(unit: String, status: ValueStatus, at: Date? = nil) -> Measured<T> {
        Measured(value: nil, unit: unit, status: status, sampledAt: at)
    }
}

/// UTC calendar math without DateFormatter: seconds-precision ISO 8601 and day/month keys.
enum UTCTime {
    static func dayIndex(_ d: Date) -> Int64 { floorDiv(Int64(d.timeIntervalSince1970.rounded(.down)), 86400) }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func civil(fromDayIndex z0: Int64) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (Int(y), Int(m), Int(d))
    }

    static func dayIndex(year y0: Int, month m: Int, day d: Int) -> Int64 {
        let y = Int64(y0) - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mm = Int64(m)
        let doy = (153 * (mm + (mm > 2 ? -3 : 9)) + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func pad(_ n: Int, _ w: Int) -> String {
        let s = String(n)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }

    static func dayString(dayIndex: Int64) -> String {
        let c = civil(fromDayIndex: dayIndex)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }

    static func dayString(_ d: Date) -> String { dayString(dayIndex: dayIndex(d)) }

    static func month(_ d: Date) -> (year: Int, month: Int) {
        let c = civil(fromDayIndex: dayIndex(d))
        return (c.year, c.month)
    }

    static func monthString(year: Int, month: Int) -> String { "\(pad(year, 4))-\(pad(month, 2))" }

    static func previousMonth(of m: (year: Int, month: Int)) -> (year: Int, month: Int) {
        m.month == 1 ? (m.year - 1, 12) : (m.year, m.month - 1)
    }

    /// "YYYY-MM-DDTHH:MM:SSZ"
    static func iso(_ d: Date) -> String {
        let secs = Int64(d.timeIntervalSince1970.rounded(.down))
        let day = floorDiv(secs, 86400)
        let rem = Int(secs - day * 86400)
        return dayString(dayIndex: day) + "T" + pad(rem / 3600, 2) + ":" + pad(rem % 3600 / 60, 2) + ":" + pad(rem % 60, 2) + "Z"
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS` with optional fraction and `Z` or `+hh:mm` offset. Returns nil on bad input.
    static func parseISO(_ s: String) -> Date? {
        let b = Array(s.utf8)
        var i = 0
        func num(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in 0..<n {
                let ch = b[i + k]
                guard ch >= 48 && ch <= 57 else { return nil }
                v = v * 10 + Int(ch - 48)
            }
            i += n
            return v
        }
        func lit(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }
        guard let y = num(4), lit(45), let mo = num(2), lit(45), let d = num(2),
              lit(84), let h = num(2), lit(58), let mi = num(2), lit(58), let se = num(2) else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se <= 60 else { return nil }
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            var digits = 0
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
                digits += 1
            }
            if digits == 0 { return nil }
        }
        var offset = 0
        if lit(90) {
            offset = 0
        } else if i < b.count, b[i] == 43 || b[i] == 45 {
            let sign = b[i] == 43 ? 1 : -1
            i += 1
            guard let oh = num(2), lit(58), let om = num(2), oh < 24, om < 60 else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        let day = dayIndex(year: y, month: mo, day: d)
        let secs = day * 86400 + Int64(h * 3600 + mi * 60 + se) - Int64(offset)
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }
}

/// Shared JSON coders: sorted keys, unescaped slashes, ISO 8601 UTC dates with second precision.
enum CoreJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(UTCTime.iso(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = UTCTime.parseISO(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO 8601 date")
            }
            return date
        }
        return d
    }
}
