// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: BubbleInput: data state, CPU, the number of readings collected, and the problems in order (docs/DESIGN_V3.md 4.1, DESIGN_V2.md 4.11).
// Output: BubbleText: the headline sentence, the evidence part, and its level. BubbleCopy.text(for:) builds them.
//         BubbleCopy.width(_:) counts width units (0.4: full-width 1, half-width 0.5). BubbleCopy.allTemplates lists every template at its worst value (W13).
//         BubbleText.wrapped is the text the view draws: a text longer than one line breaks once at its comma, so the system never splits a word.
//         BubbleCopy.subline(for:headline:sampledAt:now:) is the 13 pt second line under a one-line headline (new facts, never the headline again).
// Pos: The one source of the panel headline texts (the type name stays Bubble* from v2; the bubble itself was deleted by U10, 2026-10-18).
//      Foundation only. Line budget (v3): 17 pt type in a 320 pt content width holds 18.8 em, `lineEm` keeps a margin below that.
//      Copy rules: plain words; a problem text has an evidence number.

import Foundation

/// One problem as the headline needs it.
struct BubbleProblem: Equatable {
    var item: HealthItem
    var level: HealthLevel
    var reasonCode: String
    /// The evidence number of the template: percent (CPU, memory pressure, drain rate) or nil.
    var number: Double?
    /// App display name. Nil when the prompt setting "include app names" is off.
    var app: String?
    /// The evidence size in bytes: disk growth, disk free space, swap size or swap growth.
    var bytes: Int64? = nil
    /// How long the problem lasts, s ({D}).
    var seconds: Double? = nil

    init(item: HealthItem, level: HealthLevel, reasonCode: String, number: Double?, app: String?,
         bytes: Int64? = nil, seconds: Double? = nil) {
        self.item = item
        self.level = level
        self.reasonCode = reasonCode
        self.number = number
        self.app = app
        self.bytes = bytes
        self.seconds = seconds
    }
}

struct BubbleInput: Equatable {
    var dataState: DataState
    var cpuPercent: Double?
    /// Problems in `ProblemOrder`. The first one is the headline.
    var problems: [BubbleProblem]
    /// How many of the 6 readings (CPU, memory, disk, network, battery, temperature) have arrived. Used only while collecting.
    var collected: Int
    /// The calendar for {HH:mm}.
    var calendar: Calendar = .current

    init(dataState: DataState = .fresh, cpuPercent: Double? = nil, problems: [BubbleProblem] = [], collected: Int = 0,
         calendar: Calendar = .current) {
        self.dataState = dataState
        self.cpuPercent = cpuPercent
        self.problems = problems
        self.collected = collected
        self.calendar = calendar
    }
}

struct BubbleText: Equatable {
    /// At most 24 width units (DESIGN_V2.md 0.4). A problem text holds at least one digit.
    var main: String
    /// The part of `main` that shows the evidence ("314 GB", "87%"). The v3 headline does not color it (DESIGN_V3.md 4.1 rule 4).
    var emphasis: String? = nil
    /// Level of the emphasized part. Nil for texts without a problem.
    var level: HealthLevel? = nil

    /// The text as drawn: `main`, with one line break at the comma when the text is longer than one line (`BubbleCopy.wrapped`).
    var wrapped: String { BubbleCopy.wrapped(main) }

    init(main: String, emphasis: String? = nil, level: HealthLevel? = nil) {
        self.main = main
        self.emphasis = emphasis
        self.level = level
    }
}

enum BubbleCopy {
    static let maxWidth = 24.0
    static let appNameMaxWidth = 8.0

    /// Number of readings the collecting title counts (CPU, memory, disk, network, battery, temperature).
    static let readingCount = 6

    /// `now` only matters for stale data: the headline names how many minutes nothing new arrived.
    static func text(for input: BubbleInput, now: Date = Date()) -> BubbleText {
        if case .stale(let at) = input.dataState {
            return BubbleText(main: "数据已经 \(duration(now.timeIntervalSince(at)))没更新")
        }
        if case .collecting = input.dataState { return BubbleText(main: collectingText(done: input.collected)) }
        if let first = input.problems.first {
            return problemText(first)
        }
        return quietText(input)
    }

    /// The title while the first readings arrive (DESIGN_V3.md 4.1 rule 6).
    static func collectingText(done: Int) -> String {
        "正在检查，已完成 \(max(0, min(done, readingCount)))/\(readingCount) 项"
    }

    // MARK: Subline

    /// The 13 pt second line under a one-line headline (DESIGN_V3.md 4.1). It adds a fact the headline does not say:
    /// fresh data gives the clock of the last reading ("10:42 更新"), stale data gives the clock of the last reading
    /// ("最后一次读数在 13:40", the headline has the age). Collecting has no subline: no new fact is available, the view leaves
    /// the space empty. A two-line headline has no subline, and fresh data without a reading time has none either.
    /// The clock uses the calendar of the input.
    static func subline(for input: BubbleInput, headline: BubbleText, sampledAt: Date?, now: Date) -> String? {
        guard !wrapped(headline.main).contains("\n") else { return nil }
        switch input.dataState {
        case .collecting:
            return nil
        case .stale(let at):
            let c = input.calendar.dateComponents([.hour, .minute], from: at)
            return String(format: "最后一次读数在 %02d:%02d", c.hour ?? 0, c.minute ?? 0)
        case .fresh:
            guard let at = sampledAt else { return nil }
            let c = input.calendar.dateComponents([.hour, .minute], from: at)
            return String(format: "%02d:%02d 更新", c.hour ?? 0, c.minute ?? 0)
        }
    }

    // MARK: Quiet texts

    /// No problem. CPU steps follow the old gait steps (10, 40, 80).
    static func quietText(_ input: BubbleInput) -> BubbleText {
        guard let cpu = input.cpuPercent else { return BubbleText(main: "一切正常") }
        let p = percent(cpu)
        if cpu >= 80 { return BubbleText(main: "一切正常，CPU 冲到 \(p)") }
        if cpu >= 40 { return BubbleText(main: "一切正常，CPU \(p)") }
        if cpu >= 10 { return BubbleText(main: "一切正常，电脑在干活") }
        return BubbleText(main: "一切正常")
    }

    // MARK: Problem texts

    static func problemText(_ v: BubbleProblem) -> BubbleText {
        func make(_ before: String, _ evidence: String, _ after: String) -> BubbleText {
            BubbleText(main: before + evidence + after, emphasis: evidence, level: v.level)
        }
        let d = duration(v.seconds)
        switch v.item {
        case .disk:
            if v.reasonCode == "growth_1d" || v.reasonCode == "growth_5d", let b = v.bytes {
                let n = v.reasonCode == "growth_1d" ? 1 : 5
                return make("磁盘 \(n) 天胖了 ", size(b), "，该让 Agent 看看了")
            }
            if let b = v.bytes {
                return v.level == .red ? make("磁盘只剩 ", size(b), "，快装不下了") : make("磁盘只剩 ", size(b), "，开始挤了")
            }
            return BubbleText(main: "磁盘需要留意，该让 Agent 看看了", level: v.level)
        case .memory:
            let critical = v.reasonCode == "pressure_critical" || (v.reasonCode != "swap_growth" && v.level == .red)
            if v.reasonCode == "swap_growth", let b = v.bytes { return make("swap 半小时涨了 ", size(b), "，有点沉") }
            if let m = v.number {
                return critical ? make("内存压力 ", percent(m), "，我快背不动了") : make("内存压力 ", percent(m), "，有点挤了")
            }
            if let b = v.bytes {
                return critical ? make("内存严重不足，swap 已到 ", size(b), "") : make("内存有点挤，swap 已到 ", size(b), "")
            }
            return BubbleText(main: critical ? "内存严重不足，我快背不动了" : "内存有点挤，我走慢点", level: v.level)
        case .cpu:
            if v.reasonCode == "app_saturated" {
                let p = v.number.map { percent($0) } ?? "—"
                if let app = v.app, !app.isEmpty, width(app) <= appNameMaxWidth {
                    return BubbleText(main: "\(app) 一直占着 \(p) CPU", emphasis: p, level: v.level)
                }
                return BubbleText(main: "有个 App 一直占着 \(p) CPU", emphasis: p, level: v.level)
            }
            if v.level == .red { return make("CPU 满负荷 ", d, "了，我快跑不动了") }
            let p = v.number.map { percent($0) } ?? "—"
            return BubbleText(main: "CPU 忙了 \(d)，均值 \(p)", emphasis: p, level: v.level)
        case .thermal:
            return v.level == .red ? make("热到降速了，已持续 ", d, "") : make("有点热，已经 ", d, "了")
        case .power:
            let r = v.number.map { rate($0) } ?? "—"
            if v.reasonCode == "sleep_drain" { return make("合盖时每小时掉电 ", r, "，偏快") }
            return BubbleText(main: "1 小时掉了 \(r) 电，有点快", emphasis: r, level: v.level)
        }
    }

    // MARK: Formats (4.11 placeholder table)

    /// {P}, {M}: whole percent, "87%".
    static func percent(_ v: Double) -> String { "\(Int(max(0, v).rounded()))%" }

    /// {R}: one decimal, a trailing ".0" dropped: "3.3%", "18%".
    static func rate(_ v: Double) -> String {
        let r = (max(0, v) * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))%" }
        return String(format: "%.1f%%", r)
    }

    /// {X}: decimal units like the rows (ByteText.gb). Below 10 one decimal, then whole numbers up to 999, then the next unit.
    static func size(_ bytes: Int64) -> String {
        let v = Double(max(0, bytes))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB")]
        for (scale, unit) in units where v >= scale * 0.9995 || unit == "MB" {
            let x = v / scale
            if x < 9.95 { return String(format: "%.1f %@", x, unit) }
            return "\(Int(x.rounded())) \(unit)"
        }
        return "0 MB"
    }

    /// {D}: below 60 minutes "N 分钟", below 24 hours "N 小时", then "N 天". At least 1 minute.
    static func duration(_ seconds: Double?) -> String {
        let s = max(60, seconds ?? 60)
        if s < 3600 { return "\(Int(s / 60)) 分钟" }
        if s < 86400 { return "\(Int(s / 3600)) 小时" }
        return "\(Int(s / 86400)) 天"
    }

    // MARK: Line break

    /// Text width in em at the headline font. Digits are tabular (0.62 em), so the estimate is above the 0.5 units of `width`.
    static func em(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { sum, u in
            guard u.isASCII else { return sum + 1 }
            switch u {
            case "0"..."9": return sum + 0.62
            case " ": return sum + 0.28
            case "A"..."Z": return sum + 0.68
            case "%": return sum + 0.88
            case ".", ":", ",": return sum + 0.3
            case "/": return sum + 0.35
            default: return sum + 0.55
            }
        }
    }

    /// One line of the headline holds 18.8 em (320 pt content width, 17 pt type). `lineEm` keeps a margin below that, for the
    /// semibold digits and Latin letters. A text up to this size stays on one line. A broken line may reach `maxLineEm`.
    static let lineEm = 17.5
    static let maxLineEm = 18.4
    static let oneLineEm = lineEm

    /// Breaks a long text once, at the comma, so a word never splits across the lines ("该 / 让 Agent 看看了" is the bug this fixes).
    /// A text without a comma breaks after "一直占着". The comma stays at the end of line 1. A text that fits one line, or has
    /// no break point, stays as it is.
    static func wrapped(_ main: String) -> String {
        guard em(main) > oneLineEm else { return main }
        var cuts = [String.Index]()
        var i = main.startIndex
        while i < main.endIndex {
            if main[i] == "，" { cuts.append(main.index(after: i)) }
            i = main.index(after: i)
        }
        if let r = main.range(of: "一直占着 ") { cuts.append(main.index(before: r.upperBound)) }
        let best = cuts.min { a, b in
            max(em(String(main[..<a])), em(String(main[a...]))) < max(em(String(main[..<b])), em(String(main[b...])))
        }
        guard let cut = best else { return main }
        let first = String(main[..<cut])
        var rest = String(main[cut...])
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return first + "\n" + rest
    }

    /// Width units (0.4): every character outside ASCII counts 1, ASCII counts 0.5.
    static func width(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 0.5 : 1) }
    }

    // MARK: Worst values (W13)

    /// Every template of 4.11 at its worst value, with a name. Problem templates are marked.
    static var allTemplates: [(name: String, text: BubbleText, problem: Bool)] {
        var out = [(String, BubbleText, Bool)]()
        func add(_ name: String, _ input: BubbleInput, problem: Bool = false) { out.append((name, text(for: input, now: Date(timeIntervalSince1970: 86340 + 3540)), problem)) }
        func p(_ item: HealthItem, _ level: HealthLevel, _ code: String, number: Double? = nil, app: String? = nil,
               bytes: Int64? = nil, seconds: Double? = nil) -> BubbleInput {
            BubbleInput(problems: [BubbleProblem(item: item, level: level, reasonCode: code, number: number, app: app,
                                                 bytes: bytes, seconds: seconds)])
        }
        let worstBytes: Int64 = 999_400_000_000      // "999 GB"
        let worstD = 59.0 * 60                          // "59 分钟"
        add("空闲", BubbleInput(cpuPercent: 3))
        add("忙", BubbleInput(cpuPercent: 25))
        add("很忙", BubbleInput(cpuPercent: 79))
        add("满载", BubbleInput(cpuPercent: 100))
        add("磁盘增长", p(.disk, .red, "growth_5d", bytes: worstBytes), problem: true)
        add("磁盘红", p(.disk, .red, "low_space", bytes: worstBytes), problem: true)
        add("磁盘黄", p(.disk, .yellow, "low_space", bytes: worstBytes), problem: true)
        add("内存红", p(.memory, .red, "pressure_critical", number: 100), problem: true)
        add("内存黄", p(.memory, .yellow, "pressure_warning", number: 100), problem: true)
        add("内存红（回退）", p(.memory, .red, "pressure_critical", bytes: worstBytes), problem: true)
        add("内存黄（回退）", p(.memory, .yellow, "pressure_warning", bytes: worstBytes), problem: true)
        add("内存 swap 增长", p(.memory, .yellow, "swap_growth", bytes: worstBytes), problem: true)
        add("CPU 红", p(.cpu, .red, "cpu_mean_10m", number: 100, seconds: worstD), problem: true)
        add("CPU 黄", p(.cpu, .yellow, "cpu_mean_5m", number: 100, seconds: worstD), problem: true)
        add("单 App 占 CPU", p(.cpu, .yellow, "app_saturated", number: 1000, app: "Xcode 16"), problem: true)
        add("单 App 占 CPU（长名）", p(.cpu, .yellow, "app_saturated", number: 1000, app: "Google Chrome Helper"), problem: true)
        add("温度红", p(.thermal, .red, "thermal_critical", seconds: worstD), problem: true)
        add("温度黄", p(.thermal, .yellow, "thermal_fair", seconds: worstD), problem: true)
        add("睡眠掉电", p(.power, .red, "sleep_drain", number: 10.5), problem: true)
        add("使用掉电", p(.power, .yellow, "awake_drain", number: 10.5), problem: true)
        add("采集中", BubbleInput(dataState: .collecting, collected: 6))
        add("过期", BubbleInput(dataState: .stale(Date(timeIntervalSince1970: 86340))))
        return out
    }
}
