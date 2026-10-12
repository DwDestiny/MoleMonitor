// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, current readings, top apps, disk writers, sleep blockers, anomaly records and the environment
//        (docs/DESIGN_V2.md 8).
// Output: The Chinese prompt text for "复制排查提示词" (structure 8.4, merge 8.5, compression 8.6), and the redaction of
//         private text (S1 to S8).
// Pos: Pure text building shared by the app and `molemonitor-cli prompt`; Foundation only. Owner WP-A.
//      The text depends only on the input and the options: the "now" of the text is `sampledAt`, the time zone
//      comes from the options, and no DateFormatter is used. Equal input gives equal output (App and CLI).
//      Length: Swift `String.count`, limit 3000. Only a longer text runs the compression levels L1 to L6.
//      Sections 0, 1, 2 and 4 (the safety rules) are never compressed. The golden texts of DESIGN_V2.md 8.8 are tests.

import Foundation

enum PromptTopic: String, CaseIterable { case disk, memory, cpu, thermal, power, network }
enum PromptScope: Equatable { case overview, topic(PromptTopic) }

struct PromptEnvironment: Codable, Equatable {
    var model: String?, chip: String?, memoryBytes: Int64?, os: String
    var appVersion: String, cliPath: String, dataDir: String
}

/// Data freshness for the prompt line. Not listed in DESIGN.md 8.1 at skeleton time: the `freshness` field needs it.
enum PromptFreshness: Equatable {
    case fresh
    case stale(minutes: Int)
    case notRunning(minutes: Int)
}

struct PromptInput: Equatable {
    var env: PromptEnvironment
    var sampledAt: Date
    var freshness: PromptFreshness            // fresh, stale(minutes), notRunning(minutes)
    var verdicts: [ItemVerdict]
    var current: CurrentReadings
    var apps: [AppUsage]
    var appsBasis: String
    var cpuSummary: CPUSummary?
    var diskGrowth: [String: DiskGrowth]
    /// Sleep records, any order. Used for "近 7 次睡眠". Empty when unknown.
    var sleeps: [SleepRecord] = []
    /// Memory pressure of the last 2 hours. Nil when no pressure percent was measured.
    var pressure2h: PressureSummary? = nil
    /// Top disk writers of the last 5 minutes. Nil: not read (the CLI cannot read it). Empty: nothing above 1 MB.
    var diskWriters: [AppDiskWriteTracker.Row]? = nil
    /// Apps that hold a sleep assertion now. Nil: not read (the CLI). Empty: none.
    var sleepBlockers: [SleepBlocker]? = nil
    /// Anomaly records of the last 7 days, including the open ones. Nil: not read.
    var events: [EventRecord]? = nil
}

/// Memory pressure of the last 2 hours, for the prompt (DESIGN_V2.md 8.8.2). Minutes per system level.
struct PressureSummary: Codable, Equatable {
    var mean: Double
    var peak: Double
    var normalMinutes: Int
    var warningMinutes: Int
    var criticalMinutes: Int

    /// From the coarse trend points of the last 2 hours. Nil when no point has a pressure percent.
    static func make(points: [TrendPoint], now: Date) -> PressureSummary? {
        let window = points.filter { $0.t > now.addingTimeInterval(-7200) && $0.t <= now }
        let values = window.compactMap { $0.pressurePercent }.map(Double.init)
        guard !values.isEmpty else { return nil }
        func minutes(_ level: MemoryPressure) -> Int {
            Int((Double(window.filter { $0.pressure == level }.count) * TrendBuffer.coarseInterval / 60).rounded())
        }
        return PressureSummary(mean: values.reduce(0, +) / Double(values.count), peak: values.max() ?? 0,
                               normalMinutes: minutes(.normal), warningMinutes: minutes(.warning),
                               criticalMinutes: minutes(.critical))
    }
}

/// `DiskGrowth` (DiskGrowth.swift) is only Codable. `PromptInput: Equatable` needs it, so the conformance lives here.
/// Compares every field. Keep this list in step with `DiskGrowth`; I1 may move `Equatable` to the declaration later.
extension DiskGrowth: Equatable {
    static func == (a: DiskGrowth, b: DiskGrowth) -> Bool {
        if a.window != b.window || a.bytes != b.bytes || a.netBytes != b.netBytes { return false }
        if a.fromMinAt != b.fromMinAt { return false }
        return a.coveredHours == b.coveredHours && a.status == b.status
    }
}

struct PromptOptions: Equatable {
    var includeAppNames = true
    var maxLength = 3000          // Only a longer text triggers the compression levels
    var homeDirectory: String
    var userNames: [String]
    /// Time zone of "采样于 …". Added to 8.1 so the text stays reproducible in tests.
    var timeZone = TimeZone.current
}

extension PromptOptions {
    /// Options for the user who runs the process: the home directory, the account name and the full name.
    /// The app and the CLI both call this, so both redact the same text.
    static func forCurrentUser(includeAppNames: Bool) -> PromptOptions {
        var names = [String]()
        let account: String = NSUserName()
        let full: String = NSFullUserName()
        if !account.isEmpty { names.append(account) }
        if !full.isEmpty && full != account { names.append(full) }
        return PromptOptions(includeAppNames: includeAppNames, maxLength: 3000, homeDirectory: NSHomeDirectory(),
                             userNames: names, timeZone: TimeZone.current)
    }
}

// MARK: - Redaction (DESIGN.md 7.5)

enum Redactor {
    static let userMark = "<用户>"

    /// S2: the home directory prefix becomes `~` (the prefix must be followed by `/`, a non-name character or the end).
    /// S3: user names are replaced as whole words by `<用户>`. Names shorter than 3 characters (2 for Chinese names) only
    /// get S2. App name protection (S3.3) is the job of the builder, because only it knows which text is an App name.
    static func redact(_ text: String, home: String, userNames: [String]) -> String {
        replaceNames(replaceHome(text, home: home), userNames: userNames)
    }

    // MARK: S2

    private static func isPathChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return c == "_" || c == "-" || c == "." || c == "+" || c == "@"
    }

    static func replaceHome(_ text: String, home: String) -> String {
        var h = home.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        guard h.count > 1 else { return text }
        let pattern = Array(h)
        let chars = Array(text)
        var out = [Character]()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == pattern[0], i + pattern.count <= chars.count, Array(chars[i..<(i + pattern.count)]) == pattern {
                let end = i + pattern.count
                var continues = end < chars.count && chars[end] != "/" && isPathChar(chars[end])
                if continues && chars[end] == "." {
                    // A dot ends a sentence unless a letter or digit follows it.
                    let next = end + 1
                    continues = next < chars.count && (chars[next].isLetter || chars[next].isNumber)
                }
                if !continues {
                    out.append("~")
                    i = end
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    // MARK: S3

    private static func isHan(_ c: Character) -> Bool {
        for s in c.unicodeScalars {
            let v = s.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
                || (0xF900...0xFAFF).contains(v) { return true }
        }
        return false
    }

    private static func isAsciiWordChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_"
    }

    private struct NamePattern {
        var chars: [String]       // lowercased characters
        var chinese: Bool
    }

    private static func patterns(_ names: [String]) -> [NamePattern] {
        var seen = Set<String>()
        var out = [NamePattern]()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            let chinese = name.contains { isHan($0) }
            if name.count < (chinese ? 2 : 3) { continue }
            out.append(NamePattern(chars: name.map { String($0).lowercased() }, chinese: chinese))
        }
        return out.sorted { $0.chars.count > $1.chars.count }
    }

    static func replaceNames(_ text: String, userNames: [String]) -> String {
        let pats = patterns(userNames)
        guard !pats.isEmpty else { return text }
        let chars = Array(text)
        let lower = chars.map { String($0).lowercased() }
        func boundary(_ c: Character, chinese: Bool) -> Bool {
            chinese ? !(c.isLetter || c.isNumber) : !isAsciiWordChar(c)
        }
        var out = ""
        var i = 0
        while i < chars.count {
            var matched = false
            for p in pats {
                let n = p.chars.count
                guard i + n <= chars.count, lower[i] == p.chars[0] else { continue }
                var same = true
                var k = 1
                while k < n {
                    if lower[i + k] != p.chars[k] {
                        same = false
                        break
                    }
                    k += 1
                }
                guard same else { continue }
                let beforeOK = i == 0 || boundary(chars[i - 1], chinese: p.chinese)
                let afterOK = i + n == chars.count || boundary(chars[i + n], chinese: p.chinese)
                if beforeOK && afterOK {
                    out += userMark
                    i += n
                    matched = true
                    break
                }
            }
            if !matched {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - Builder

enum PromptBuilder {
    /// The topic chosen automatically: the topic of the first problem item. Nil when there is no problem item.
    static func autoTopic(_ verdicts: [ItemVerdict]) -> PromptTopic? {
        guard let first = ProblemOrder.problems(verdicts).first else { return nil }
        return ProblemOrder.topic(for: first.item)
    }

    /// The highest compression level (L6 plus "drop section 5").
    static let maxLevel = 7

    static func build(_ input: PromptInput, scope: PromptScope, options: PromptOptions) -> String {
        var text = ""
        for level in 0...maxLevel {
            text = render(input, scope: scope, options: options, level: level)
            if text.count <= options.maxLength { break }
        }
        return text
    }

    /// Number of characters at each compression level 0 to 7. Used by tests to check the steps.
    static func lengths(_ input: PromptInput, scope: PromptScope, options: PromptOptions) -> [Int] {
        (0...maxLevel).map { render(input, scope: scope, options: options, level: $0).count }
    }

    // MARK: Entries

    /// One line of section 1 and one block of section 3: a problem, or the topic of a topic scope.
    private struct Entry {
        var topic: PromptTopic
        var verdict: ItemVerdict?
        var isProblem: Bool { verdict?.isProblem ?? false }
        var item: HealthItem? { verdict?.item }
    }

    /// Items in the "其余正常" line, in this fixed order (DESIGN_V2.md 8.8).
    private static let restOrder: [HealthItem] = [.memory, .disk, .power, .cpu, .thermal]

    // MARK: Rendering

    private static func render(_ input: PromptInput, scope: PromptScope, options: PromptOptions, level: Int) -> String {
        let problems = ProblemOrder.problems(input.verdicts)
        var protect = AppNameProtection(userNames: options.userNames)
        var entries = [Entry]()
        var routine = false
        switch scope {
        case .overview:
            entries = problems.map { Entry(topic: ProblemOrder.topic(for: $0.item) ?? .cpu, verdict: $0) }
            routine = entries.isEmpty
        case .topic(let t):
            entries = problems.filter { ProblemOrder.topic(for: $0.item) == t }.map { Entry(topic: t, verdict: $0) }
            if entries.isEmpty { entries = [Entry(topic: t, verdict: input.verdicts.first { ProblemOrder.topic(for: $0.item) == t })] }
        }
        let cli = input.env.cliPath
        var text: String
        if hasNoData(input) {
            text = renderNoData(input, options: options)
        } else if routine {
            text = renderRoutine(input, options: options)
        } else {
            text = renderInvestigation(input, entries: entries, scope: scope, options: options, level: level, protect: &protect)
        }
        _ = cli
        // S8: the last step runs S2 and S3 on the whole text, then the App names return.
        text = Redactor.redact(text, home: options.homeDirectory, userNames: options.userNames)
        return protect.restore(text)
    }

    // MARK: Header

    private static func sampledLine(_ input: PromptInput, options: PromptOptions) -> String {
        let when: String = TextFormat.dateTime(input.sampledAt, timeZone: options.timeZone)
        let check = "数字可能不是现在的状态，请先运行 `\(input.env.cliPath) --status` 确认。"
        var line = "以下是 MoleMonitor 的只读监测数据。采样于 \(when)，"
        switch input.freshness {
        case .fresh: line += "数据新鲜。"
        case .stale(let m): line += "数据已过期 \(m) 分钟。" + check
        case .notRunning(let m): line += "App 未运行，最后数据在 \(m) 分钟前。" + check
        }
        return line
    }

    private static func isFresh(_ f: PromptFreshness) -> Bool { f == .fresh }

    // MARK: Investigation prompt (8.4)

    private static func renderInvestigation(_ input: PromptInput, entries: [Entry], scope: PromptScope, options: PromptOptions,
                                            level: Int, protect: inout AppNameProtection) -> String {
        let cli = input.env.cliPath
        let multi = entries.filter { $0.isProblem }.count > 1
        var lines = [String]()

        // Section 0.
        var title: String
        if case .topic(let t) = scope, !(entries.first?.isProblem ?? false) {
            title = "请帮我检查这台 Mac 的" + topicName(t)
        } else if let first = entries.first, let v = first.verdict {
            title = "请帮我排查这台 Mac：" + titleText(v, input: input, options: options)
            if multi { title += " 等 \(entries.count) 项问题" }
        } else {
            title = "请帮我检查这台 Mac 的网络"
        }
        lines.append("# " + title)
        lines.append(sampledLine(input, options: options))
        lines.append("")

        // Section 1.
        lines.append("## 1. 现在的问题")
        if case .topic(let t) = scope, !(entries.first?.isProblem ?? false) {
            lines.append("| 顺序 | 项目 | 级别 | 证据 | 已持续 |")
            lines.append("|---|---|---|---|---|")
            let word: String = entries.first?.verdict.map { TextFormat.levelWord($0.level) } ?? "无等级"
            let evidence: String = entries.first?.verdict.map { evidenceText($0, input: input, options: options, compact: false) }
                ?? ("\u{2193} " + RateText.text(input.current.rx) + " \u{2191} " + RateText.text(input.current.tx))
            lines.append("| 1 | \(topicName(t)) | \(word) | \(evidence) | \u{2014} |")
            _ = t
        } else {
            lines.append("| 顺序 | 项目 | 级别 | 证据 | 已持续 |")
            lines.append("|---|---|---|---|---|")
            for (n, e) in entries.enumerated() {
                guard let v = e.verdict else { continue }
                let since = TextFormat.duration(since: v.since, now: input.sampledAt)
                let evidence = evidenceText(v, input: input, options: options, compact: n > 0)
                lines.append("| \(n + 1) | \(v.item.label) | \(TextFormat.levelWord(v.level)) | \(evidence) | \(since) |")
            }
        }
        lines.append("")
        let listed = Set(entries.compactMap { $0.item })
        let rest = restOrder.filter { !listed.contains($0) }
        let greens = rest.filter { item in input.verdicts.first { $0.item == item }?.level == .green }
        let unknown = rest.filter { item in
            guard let v = input.verdicts.first(where: { $0.item == item }) else { return false }
            return v.level == .unknown || v.level == .stale
        }
        if !greens.isEmpty {
            lines.append("其余正常：" + greens.map { $0.label }.joined(separator: "、") + "。")
            lines.append("")
        }
        if !unknown.isEmpty {
            lines.append("未读到：" + unknown.map { $0.label }.joined(separator: "、") + "。")
            lines.append("")
        }

        // Section 2.
        lines.append("## 2. 你的任务")
        lines.append(multi ? "1. 按第 3 节的顺序只读诊断。先处理排在前面的问题。" : "1. 按第 3 节的步骤只读诊断，找出原因。")
        lines.append("2. 列出可以处理的对象：名称、大小或占用、理由、能否恢复。")
        lines.append("3. 等我确认后，才做任何改动。")
        let reply = "一句结论 → 证据 → 建议。每条建议标明“只读”或“会改动系统”。"
        lines.append(multi ? "4. 回复格式：每个问题一段，按顺序：" + reply : "4. 回复格式：" + reply)
        lines.append("")

        // Section 3.
        lines.append("## 3. 排查步骤")
        let shortScope = level >= 5
        let fullCount = min(entries.count, 2)
        for (n, e) in entries.enumerated() where n < fullCount {
            let word: String = e.verdict.map { TextFormat.levelWord($0.level) } ?? "无等级"
            var heading = "### 3.\(n + 1) " + topicName(e.topic)
            if e.isProblem { heading += n == 0 ? "（\(word)，最优先）" : "（\(word)）" }
            lines.append(heading)
            let detail = topicDetail(e.topic, first: n == 0, verdict: e.verdict)
            lines.append(shortScope ? firstSentence(detail.scope) : detail.scope)
            var steps = detail.steps(cli)
            if n == 1 && level >= 3 { steps = Array(steps.prefix(2)) }
            for (k, step) in steps.enumerated() { lines.append("\(k + 1). " + step) }
            lines.append("")
        }
        if entries.count > fullCount {
            let others = Array(entries[fullCount...])
            if level >= 4 {
                let names = others.map { topicName($0.topic) + "（" + ($0.verdict.map { TextFormat.levelWord($0.level) } ?? "") + "）" }
                lines.append("其余问题：" + names.joined(separator: "、") + "。先完成上面的步骤。")
            } else {
                lines.append("### 3.\(fullCount + 1) 其余问题（各做第一步）")
                for e in others {
                    let word: String = e.verdict.map { TextFormat.levelWord($0.level) } ?? ""
                    lines.append("- " + topicName(e.topic) + "（\(word)）：运行 " + topicDetail(e.topic, first: false, verdict: e.verdict).firstCommand(cli))
                }
            }
            lines.append("")
        }

        // Section 4.
        lines.append(contentsOf: safetyRules(cli: cli, dataDir: input.env.dataDir))
        lines.append("")

        // Section 5.
        if level < maxLevel {
            lines.append("## 5. 参考数据")
            lines.append("- 机器：" + machineLine(input.env, short: level >= 6))
            lines.append("")
            let table = appTable(input, entries: entries, rows: level >= 1 ? 3 : 5, options: options, protect: &protect)
            if !table.isEmpty {
                lines.append(contentsOf: table)
                lines.append("")
            }
            let metrics = metricRows(input, entries: entries, multi: multi, dropEvents: level >= 2, options: options, protect: &protect)
            if !metrics.isEmpty {
                lines.append("| 指标 | 值 |")
                lines.append("|---|---|")
                for (label, value) in metrics { lines.append("| \(label) | \(value) |") }
                lines.append("")
            }
        }

        // Section 6.
        lines.append("## 6. 我补充的现象")
        lines.append(supplementHint(entries: entries, multi: multi))
        return lines.joined(separator: "\n")
    }

    private static func supplementHint(entries: [Entry], multi: Bool) -> String {
        if multi { return "[可选：写下你注意到的现象]" }
        switch entries.first?.topic {
        case .disk?: return "[可选：写下你注意到的现象，例如“导入视频后空间少了很多”]"
        case .memory?: return "[可选：写下你注意到的现象，例如“切换窗口时卡顿”]"
        case .cpu?: return "[可选：写下你注意到的现象，例如“风扇一直在响”]"
        case .power?: return "[可选：写下你注意到的现象，例如“早上起来电量少了很多”]"
        case .thermal?: return "[可选：写下你注意到的现象，例如“机身发烫，风扇很响”]"
        case .network?: return "[可选：写下你注意到的现象，例如“网页打开很慢”]"
        case nil: return "[可选：写下你注意到的现象]"
        }
    }

    // MARK: Title and evidence

    private static func titleText(_ v: ItemVerdict, input: PromptInput, options: PromptOptions) -> String {
        let c = input.current
        switch v.item {
        case .disk:
            return v.item.label + " " + v.headline
        case .memory:
            if v.reasonCode.hasPrefix("pressure") {
                let tier: String = v.reasonCode == "pressure_critical" ? "严重" : "警告"
                if let p = c.memoryPressurePercent { return "内存压力 \(p)%，已到\(tier)档" }
                return "内存压力已到\(tier)档"
            }
            var text = "内存 swap " + TextFormat.bytes(c.swapUsed)
            if let g = c.swapGrowth30m, g > 0 { text += "，30 分钟 " + TextFormat.signedBytes(g) }
            return text
        case .cpu:
            if v.reasonCode == "app_saturated" {
                return options.includeAppNames ? "CPU " + v.headline : "CPU 有 App 占满一个核"
            }
            let window = v.reasonCode == "cpu_mean_10m" ? "10" : "5"
            let mean: Double? = v.reasonCode == "cpu_mean_10m" ? c.cpuMean10m : c.cpuMean5m
            guard let mean else { return "CPU " + v.headline }
            return "CPU \(window) 分钟均值 " + TextFormat.percent(mean)
        case .thermal:
            if let t = c.thermal { return "温度 系统热状态“\(t.label)”" }
            return "温度 " + v.headline
        case .power:
            if v.reasonCode == "sleep_drain", let rate = sleepRate(c.lastSleep) {
                return "睡眠时每小时掉电 " + String(format: "%.1f", rate) + "%"
            }
            if v.reasonCode == "awake_drain", let rate = c.awakeDrainPerHour {
                return "使用中每小时掉电 " + String(format: "%.0f", rate) + "%"
            }
            return "耗电 " + v.headline
        }
    }

    private static func sleepRate(_ s: SleepRecord?) -> Double? {
        guard let s else { return nil }
        let hours = s.wokeAt.timeIntervalSince(s.sleptAt) / 3600
        return hours > 0 ? (s.batteryBefore - s.batteryAfter) / hours : nil
    }

    /// The evidence cell of section 1. `compact` is true for the second and later problems of a merged prompt.
    private static func evidenceText(_ v: ItemVerdict, input: PromptInput, options: PromptOptions, compact: Bool) -> String {
        let dash = "\u{2014}"
        if v.level == .unknown || v.level == .stale { return dash }
        let c = input.current
        switch v.item {
        case .disk:
            var parts = [String]()
            if v.isProblem, v.reasonCode.hasPrefix("growth_") {
                let key = String(v.reasonCode.dropFirst("growth_".count))
                let days = key.hasSuffix("d") ? String(key.dropLast()) : key
                parts.append("\(days) 天 " + TextFormat.signedDiskGB(input.diskGrowth[key]?.bytes))
            }
            if let a = c.diskAvailable { parts.append("可用 " + ByteText.gb(a)) }
            return parts.isEmpty ? "未读到" : parts.joined(separator: "，")
        case .memory:
            var parts = [String]()
            let tier: String = c.pressure?.label ?? dash
            if let p = c.memoryPressurePercent {
                parts.append("压力 \(p)%（系统档位：\(tier)）")
            } else {
                parts.append("压力档位：\(tier)")
            }
            parts.append("swap " + TextFormat.bytes(c.swapUsed))
            if !compact, let g = c.swapGrowth30m, v.reasonCode.hasPrefix("swap") || c.pressure != .normal {
                parts.append("30 分钟 " + TextFormat.signedBytes(g))
            }
            return parts.joined(separator: "，")
        case .cpu:
            if v.reasonCode == "app_saturated" {
                return options.includeAppNames ? v.headline : "有 App 占满一个核"
            }
            let window = v.reasonCode == "cpu_mean_10m" ? "10" : "5"
            let mean: Double? = v.reasonCode == "cpu_mean_10m" ? c.cpuMean10m : c.cpuMean5m
            var text = "\(window) 分钟均值 " + TextFormat.percent(mean)
            if !compact, let s = input.cpuSummary { text += "，2 小时峰值 " + TextFormat.percent(s.peak) }
            return text
        case .thermal:
            guard let t = c.thermal else { return dash }
            return "热状态：" + t.label + "（" + t.rawValue + "）"
        case .power:
            if v.reasonCode == "sleep_drain", let s = c.lastSleep, let rate = sleepRate(s) {
                let span = TextFormat.span(seconds: s.wokeAt.timeIntervalSince(s.sleptAt))
                let levels = String(format: "%.0f%% \u{2192} %.0f%%", s.batteryBefore, s.batteryAfter)
                return "睡眠 " + span + "，电量 " + levels + "，" + String(format: "%.1f", rate) + "%/小时"
            }
            if v.reasonCode == "awake_drain", let rate = c.awakeDrainPerHour {
                var text = "电池供电，每小时掉电 " + String(format: "%.0f", rate) + "%"
                if !compact, let b = c.batteryPercent { text += "，电量 " + String(format: "%.0f%%", b) }
                return text
            }
            guard let b = c.batteryPercent else { return dash }
            return "电量 " + String(format: "%.0f%%", b)
        }
    }

    // MARK: Section 5 tables

    private static func machineLine(_ env: PromptEnvironment, short: Bool) -> String {
        var parts = [String]()
        if !short, let m = env.model, !m.isEmpty { parts.append(m) }
        if let c = env.chip, !c.isEmpty { parts.append(c) }
        if let bytes = env.memoryBytes {
            parts.append("内存 \(Int((Double(bytes) / 1_073_741_824).rounded())) GB")
        }
        if !short {
            parts.append("macOS \(env.os)")
            parts.append("MoleMonitor \(env.appVersion)")
        }
        return parts.joined(separator: " · ")
    }

    private static func appTable(_ input: PromptInput, entries: [Entry], rows: Int, options: PromptOptions,
                                 protect: inout AppNameProtection) -> [String] {
        let wanted: Set<HealthItem> = [.cpu, .memory, .thermal]
        let needs: Bool = entries.contains { e in e.item.map { wanted.contains($0) } ?? false }
            || entries.contains { $0.item == nil && $0.topic == .network && false }
        guard needs else { return [] }
        let memoryFirst: Bool = entries.first?.item == .memory
        let top = AppRanking.top(input.apps, by: memoryFirst ? .memory : .cpu, count: rows)
        guard !top.isEmpty else { return [] }
        var table = [String]()
        if !options.includeAppNames { table.append("（已按设置隐藏 App 名称）") }
        let columns: String = memoryFirst ? "| App（\(input.appsBasis)） | 内存 | CPU |" : "| App（\(input.appsBasis)） | CPU | 内存 |"
        table.append(columns)
        table.append("|---|---|---|")
        for (index, app) in top.enumerated() {
            let name = appLabel(app.name, bundleID: app.bundleID, index: index, options: options, protect: &protect)
            let cpu = TextFormat.percent(app.cpuPercent)
            let mem = appMemory(app.memoryBytes)
            table.append(memoryFirst ? "| \(name) | \(mem) | \(cpu) |" : "| \(name) | \(cpu) | \(mem) |")
        }
        return table
    }

    /// App memory: one decimal GB from 100 MB, whole MB below (the examples of DESIGN_V2.md 8.8 show "0.9 GB").
    private static func appMemory(_ value: Int64?) -> String {
        guard let value else { return "\u{2014}" }
        if value >= 95_000_000 { return String(format: "%.1f GB", Double(value) / 1e9) }
        return TextFormat.bytes(value)
    }

    private static func metricRows(_ input: PromptInput, entries: [Entry], multi: Bool, dropEvents: Bool, options: PromptOptions,
                                   protect: inout AppNameProtection) -> [(String, String)] {
        let c = input.current
        let missing = "未读到"
        var rows = [(String, String)]()
        var cpuSummaryDone = false
        for e in entries {
            switch e.topic {
            case .disk:
                var parts = [String]()
                var any = false
                for (key, label) in [("1d", "1 天"), ("5d", "5 天"), ("30d", "30 天")] {
                    let g: Int64? = input.diskGrowth[key]?.bytes
                    if g != nil { any = true }
                    parts.append(label + " " + TextFormat.signedDiskGB(g))
                }
                rows.append(("磁盘增长", any ? parts.joined(separator: " · ") : missing))
                if !multi { rows.append(("磁盘容量", diskCapacityText(c) ?? missing)) }
                if let writers = input.diskWriters {
                    if writers.isEmpty {
                        rows.append(("写入最多的 App（近 5 分钟）", "没有超过 1 MB 的写入"))
                    } else {
                        let list = writers.prefix(3).enumerated().map { (index, w) -> String in
                            appLabel(w.name, bundleID: nil, index: index, options: options, protect: &protect) + " " + TextFormat.bytes(w.bytes)
                        }
                        rows.append(("写入最多的 App（近 5 分钟）", list.joined(separator: " · ")))
                    }
                } else {
                    rows.append(("写入最多的 App（近 5 分钟）", missing))
                }
            case .memory:
                if !multi { rows.append(("内存容量", memoryCapacityText(c) ?? missing)) }
                var swap = c.swapUsed.map { TextFormat.bytes($0) } ?? missing
                if c.swapUsed != nil {
                    if let g = c.swapGrowth30m { swap += "，30 分钟 " + TextFormat.signedBytes(g) }
                    if let t = c.swapTrend { swap += "，趋势 " + t.arrow }
                }
                rows.append(("swap", swap))
                if !multi {
                    if let p = input.pressure2h {
                        rows.append(("内存压力（2 小时）", "均值 \(Int(p.mean.rounded()))%，峰值 \(Int(p.peak.rounded()))% · 正常 \(p.normalMinutes) 分钟 · 警告 \(p.warningMinutes) 分钟 · 严重 \(p.criticalMinutes) 分钟"))
                    } else {
                        rows.append(("内存压力（2 小时）", missing))
                    }
                }
            case .cpu, .thermal:
                if !cpuSummaryDone {
                    cpuSummaryDone = true
                    if let s = input.cpuSummary {
                        rows.append(("CPU 2 小时", "均值 " + TextFormat.percent(s.mean) + "，峰值 " + TextFormat.percent(s.peak)))
                    } else if e.topic == .cpu {
                        rows.append(("CPU 2 小时", missing))
                    }
                }
                if e.topic == .thermal || !multi {
                    let value: String = c.thermal.map { $0.label + "（" + $0.rawValue + "）" } ?? missing
                    rows.append(("热状态", value))
                }
            case .power:
                var battery = c.batteryPercent.map { String(format: "%.0f%%", $0) } ?? missing
                if c.batteryPercent != nil, let s = c.powerSource { battery += s == .ac ? "，接电源" : "，电池供电" }
                rows.append(("电量", battery))
                if let s = c.lastSleep {
                    let span = TextFormat.span(seconds: s.wokeAt.timeIntervalSince(s.sleptAt))
                    rows.append(("上次睡眠", span + "，" + String(format: "%.0f%% \u{2192} %.0f%%", s.batteryBefore, s.batteryAfter)))
                }
                let recent = input.sleeps.sorted { $0.wokeAt > $1.wokeAt }.prefix(7).compactMap { sleepRate($0) }
                if !recent.isEmpty {
                    rows.append(("近 7 次睡眠", recent.map { String(format: "%.1f", $0) + "%/小时" }.joined(separator: " · ")))
                }
                if let blockers = input.sleepBlockers {
                    if blockers.isEmpty {
                        rows.append(("阻止睡眠的进程（现在）", "无"))
                    } else {
                        let list = blockers.enumerated().map { (index, b) -> String in
                            appLabel(b.name, bundleID: nil, index: index, options: options, protect: &protect) + "（" + b.kindText + "）"
                        }
                        rows.append(("阻止睡眠的进程（现在）", list.joined(separator: "· ")))
                    }
                } else {
                    rows.append(("阻止睡眠的进程（现在）", missing))
                }
            case .network:
                rows.append(("网速", "\u{2193} " + RateText.text(c.rx) + " \u{2191} " + RateText.text(c.tx) + "（物理网卡合计）"))
            }
        }
        if !dropEvents, let text = eventSummary(input.events, entries: entries, order: input.verdicts) {
            rows.append(("近 7 天异常记录", text))
        }
        return rows
    }

    /// "磁盘 红 1 次（本次）· CPU 黄 2 次". Items of the prompt come first, then the others by fixed priority; yellow before
    /// red inside one item. "（本次）" marks the group of the open record only when the prompt has one problem.
    /// Nil when the records were not read. "无" when there are none.
    static func eventSummary(_ events: [EventRecord]?, entries problemItems: [HealthItem], single: Bool) -> String? {
        guard let events else { return nil }
        if events.isEmpty { return "无" }
        let rest = HealthItem.allCases.filter { !problemItems.contains($0) }.sorted { $0.fixedPriority < $1.fixedPriority }
        var parts = [String]()
        for item in problemItems + rest {
            for level in [HealthLevel.yellow, HealthLevel.red] {
                let group = events.filter { $0.item == item && $0.peak == level }
                if group.isEmpty { continue }
                var text = "\(item.label) \(TextFormat.levelWord(level)) \(group.count) 次"
                if single, group.contains(where: { $0.end == nil }) { text += "（本次）" }
                parts.append(text)
            }
        }
        // The text of DESIGN_V2.md 8.8 has no space before "·" after "（本次）".
        var text = ""
        for part in parts {
            if text.isEmpty { text = part } else { text += text.hasSuffix("（本次）") ? "· " + part : " · " + part }
        }
        return text
    }

    private static func eventSummary(_ events: [EventRecord]?, entries: [Entry], order: [ItemVerdict]) -> String? {
        let items = entries.compactMap { $0.item }
        return eventSummary(events, entries: items, single: entries.filter { $0.isProblem }.count == 1)
    }

    // MARK: Capacity text

    /// Total and used are rounded first, then available = total - used, so the shown numbers add up (DESIGN_V2.md 6.3).
    private static func diskCapacityText(_ c: CurrentReadings) -> String? {
        guard let total = c.diskTotal, let used = c.diskUsed else { return nil }
        let t = Int((Double(total) / 1e9).rounded())
        let u = Int((Double(used) / 1e9).rounded())
        var text = "共 \(t) GB · 已用 \(u) GB · 可用 \(max(0, t - u)) GB"
        if let purge = c.diskPurgeable, purge > 0 { text += "（含可清除 \(Int((Double(purge) / 1e9).rounded())) GB）" }
        return text
    }

    private static func gib1(_ bytes: Int64) -> Double { (Double(bytes) / 1_073_741_824 * 10).rounded() / 10 }

    private static func memoryCapacityText(_ c: CurrentReadings) -> String? {
        guard let m = c.memory, let total = m.total, let app = m.app, let wired = m.wired, let compressed = m.compressed else { return nil }
        let t = gib1(total)
        let u = gib1(app + wired + compressed)
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        return "共 \(one(t)) GB · 已用 \(one(u)) GB（App \(one(gib1(app))) · 联动 \(one(gib1(wired))) · 压缩 \(one(gib1(compressed)))）· 可用 \(one(max(0, ((t - u) * 10).rounded() / 10))) GB"
    }

    // MARK: Routine check (8.8.6)

    private static func renderRoutine(_ input: PromptInput, options: PromptOptions) -> String {
        let cli = input.env.cliPath
        let c = input.current
        let missing = "未读到"
        var lines = [String]()
        lines.append("# 请帮我给这台 Mac 做一次日常巡检")
        var second = sampledLine(input, options: options)
        if isFresh(input.freshness) { second += "现在没有异常。" }
        lines.append(second)
        lines.append("")
        lines.append("## 1. 现在的状态")
        lines.append("| 项目 | 当前 |")
        lines.append("|---|---|")
        lines.append("| CPU | " + (c.cpuMean10m.map { "10 分钟均值 " + TextFormat.percent($0) } ?? missing) + " |")
        var memory = missing
        if let p = c.memoryPressurePercent {
            memory = "压力 \(p)%"
            if let m = c.memory, let total = m.total, let used = m.used {
                memory += String(format: "，已用 %.1f / %.1f GB", gib1(used), gib1(total))
            }
            if let swap = c.swapUsed { memory += "，swap " + TextFormat.bytes(swap) }
        } else if let tier = c.pressure {
            memory = "压力档位：" + tier.label
        }
        lines.append("| 内存 | " + memory + " |")
        var disk = missing
        if let total = c.diskTotal, let used = c.diskUsed {
            disk = "已用 \(Int((Double(used) / 1e9).rounded())) / \(Int((Double(total) / 1e9).rounded())) GB"
            if let g = input.diskGrowth["5d"]?.bytes {
                disk += "，5 天 " + (g < 0 ? "-" : "+") + "\(Int((Double(abs(g)) / 1e9).rounded())) GB"
            }
        }
        lines.append("| 磁盘 | " + disk + " |")
        if input.verdicts.contains(where: { $0.item == .power }) || c.batteryPercent != nil {
            var battery = c.batteryPercent.map { String(format: "%.0f%%", $0) } ?? missing
            if c.batteryPercent != nil, let s = c.powerSource { battery += s == .ac ? "，接电源" : "，电池供电" }
            lines.append("| 电池 | " + battery + " |")
        }
        lines.append("")
        if let text = eventSummary(input.events, entries: [HealthItem](), single: false) {
            lines.append(text == "无" ? "近 7 天异常记录：无。" : "近 7 天异常记录：" + text + "。")
            lines.append("")
        }
        lines.append("## 2. 你的任务")
        lines.append("1. 只读体检，不做任何改动。")
        lines.append("2. 只汇报值得注意的发现，每条带证据。没有就说“没有发现”。")
        lines.append("")
        lines.append("## 3. 巡检步骤")
        lines.append("1. 运行 `\(cli) --disk-history --days 30`，看磁盘是否持续增长。")
        lines.append("2. 运行 `mo clean --dry-run`，汇报可清理空间的总大小。")
        lines.append("3. 运行 `pmset -g assertions`，看是否有进程长期阻止睡眠。")
        lines.append("")
        lines.append(contentsOf: safetyRules(cli: cli, dataDir: input.env.dataDir))
        lines.append("")
        lines.append("## 6. 我补充的现象")
        lines.append("[可选]")
        return lines.joined(separator: "\n")
    }

    // MARK: No data

    /// True when no verdict has a usable level: every item is still collecting or stale. Old but real levels
    /// are rendered with a notice instead (DESIGN_V2.md 8.4).
    static func hasNoData(_ input: PromptInput) -> Bool {
        if input.verdicts.isEmpty { return true }
        return input.verdicts.allSatisfy { $0.level == .unknown || $0.level == .stale }
    }

    private static func renderNoData(_ input: PromptInput, options: PromptOptions) -> String {
        let cli = input.env.cliPath
        var lines = [String]()
        lines.append("# 请先确认 MoleMonitor 的数据是否可用")
        lines.append(sampledLine(input, options: options))
        lines.append("")
        lines.append("## 1. 现在的情况")
        switch input.freshness {
        case .stale(let m): lines.append("监测数据已过期（\(m) 分钟前），当前读数不可信。")
        case .notRunning(let m): lines.append("MoleMonitor 未运行，最后数据在 \(m) 分钟前，当前读数不可信。")
        case .fresh: lines.append("MoleMonitor 刚开始运行，还在收集首批数据，当前没有可用读数。")
        }
        lines.append("不要根据这些数据判断问题，也不要推测问题。")
        lines.append("1. 运行 `\(cli) --status`，确认 App 在运行且数据是新的。")
        lines.append("2. 如果 App 未运行，告诉我，等我启动后再排查。不要自行启动或安装。")
        lines.append("3. 如果数据已是新的，按新数据重新判断。")
        lines.append("")
        lines.append(contentsOf: safetyRules(cli: cli, dataDir: input.env.dataDir))
        lines.append("")
        lines.append("## 6. 我补充的现象")
        lines.append("[可选]")
        return lines.joined(separator: "\n")
    }

    // MARK: Apps and names

    /// Protects App names that equal a user name or a part of it (S3.3). The names are swapped for one private-use
    /// character each before the redaction and swapped back afterwards.
    private struct AppNameProtection {
        var keys: Set<String>
        var tokens = [String: Character]()
        var originals = [Character: String]()

        init(userNames: [String]) {
            var set = Set<String>()
            for raw in userNames {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if name.isEmpty { continue }
                set.insert(name)
                for piece in name.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }) { set.insert(String(piece)) }
            }
            keys = set
        }

        mutating func guardText(_ text: String, force: Bool = false) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard force || keys.contains(trimmed.lowercased()) else { return text }
            if let t = tokens[text] { return String(t) }
            guard let scalar = UnicodeScalar(0xE100 + tokens.count) else { return text }
            let token = Character(scalar)
            tokens[text] = token
            originals[token] = text
            return String(token)
        }

        func restore(_ text: String) -> String {
            if originals.isEmpty { return text }
            var out = ""
            for ch in text {
                if let original = originals[ch] { out += original } else { out.append(ch) }
            }
            return out
        }
    }

    private static func clean(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "|" {
                out.append("/")
            } else if ch.isNewline || ch.unicodeScalars.contains(where: { $0.value < 32 }) {
                out.append(" ")
            } else {
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func appLabel(_ rawName: String, bundleID: String?, index: Int, options: PromptOptions,
                                 protect: inout AppNameProtection) -> String {
        if !options.includeAppNames { return "App \(index + 1)" }
        var name = clean(rawName)
        if name.count > 32 { name = String(name.prefix(32)) + "\u{2026}" }
        let guarded = protect.guardText(name)
        var label = guarded
        if let id = bundleID, !id.isEmpty {
            let cleanID = clean(id)
            let shownID = guarded == name ? cleanID : protect.guardText(cleanID, force: true)
            label += "（" + shownID + "）"
        }
        return label
    }

    // MARK: Topic texts (8.8)

    private static func topicName(_ t: PromptTopic) -> String {
        switch t {
        case .disk: return "磁盘"
        case .memory: return "内存"
        case .cpu: return "CPU"
        case .thermal: return "温度"
        case .power: return "耗电"
        case .network: return "网络"
        }
    }

    private static func firstSentence(_ text: String) -> String {
        guard let end = text.firstIndex(of: "。") else { return text }
        return String(text[...end])
    }

    private struct TopicDetail {
        var scope: String
        var steps: (String) -> [String]
        func firstCommand(_ cli: String) -> String {
            let first = steps(cli).first ?? ""
            return first.hasPrefix("运行 ") ? String(first.dropFirst(3)) : first
        }
    }

    /// Scope line and steps of one topic. `first` is true for the first problem of the prompt, false for the later ones
    /// (the memory text is shorter there, as in DESIGN_V2.md 8.8.5).
    private static func topicDetail(_ topic: PromptTopic, first: Bool, verdict: ItemVerdict?) -> TopicDetail {
        switch topic {
        case .disk:
            return TopicDetail(scope: "口径：真实已用不含可清除空间（快照、系统缓存）。增长量 = 当前值 − 窗口内最低值。", steps: { cli in [
                "运行 `\(cli) --disk-history --days 30`，找出增长集中的日期。",
                "运行 `mo analyze --json ~`，找出最大的目录。再对其中最大的子目录运行 `mo analyze --json <目录>`。不要省略 `--json`：交互模式可能把文件移到废纸篓。",
                "对照第 5 节的写入排行与增长日期，判断来源：下载、虚拟机镜像、Xcode 数据、容器镜像、照片库、本地备份。",
                "运行 `mo clean --dry-run` 与 `mo purge --dry-run`，只看预览结果。",
                "列出可回收项：路径（家目录写 ~）、大小、能否再生成。",
            ] })
        case .memory:
            let scope: String = first
                ? "口径：等级以系统压力档位为准。压力百分比 = 100 − `kern.memorystatus_level`，是近似读数。macOS 会把空闲内存用作文件缓存，所以不看“已用占比”。"
                : "口径：等级以系统压力档位为准。压力百分比是近似读数。不看“已用占比”。"
            return TopicDetail(scope: scope, steps: { _ in [
                first ? "运行 `memory_pressure`、`sysctl vm.swapusage` 与 `vm_stat`，确认压力、swap 与压缩内存。"
                      : "运行 `sysctl vm.swapusage` 与 `vm_stat`，确认 swap 与压缩内存。",
                "运行 `ps -Ao pid,rss,comm -m | head -n 15`，对照第 5 节的排行找出大户。",
                "5 分钟后再运行第 2 步。内存持续上涨的 App 可能有泄漏。",
                "建议顺序：保存后重启该 App（先问我）→ 减少标签页或扩展。不建议 `sudo purge` 或内存清理软件。",
            ] })
        case .cpu:
            return TopicDetail(scope: "口径：单个 App 的 CPU 以单核满载为 100%，多核可超过 100%。", steps: { _ in [
                "运行 `ps -Ao pid,pcpu,time,comm -r | head -n 15`，找出占用最高的进程。",
                "1 分钟后再运行一次，区分短时尖峰与持续占用。",
                "系统进程（mds_stores、mdworker、photoanalysisd、backupd）：说明用途。通常等它完成，不结束它。",
                "用户 App：先列出进程与理由，等我确认，再建议保存并正常退出。不要自行结束进程，不用 `kill -9`。",
            ] })
        case .thermal:
            return TopicDetail(scope: "口径：等级来自系统热状态 thermalState，不是传感器读数。SMC 温度只作参考。", steps: { _ in [
                "运行 `pmset -g therm`，确认是否有降频记录。",
                "对照第 5 节的 CPU 排行找出热源进程。",
                "检查环境：是否放在软面上、是否接外接显示器、是否在充电。",
                "只建议降低负载。不建议控制风扇，不改 SMC。",
            ] })
        case .power:
            let awake: Bool = verdict?.reasonCode == "awake_drain"
            let scope: String = awake
                ? "口径：耗电来自电池电量读数，不来自 CPU 估算。使用中掉电 = 近 60 分钟电量下降 ÷ 小时数。"
                : "口径：耗电来自电池电量读数，不来自 CPU 估算。睡眠掉电 = 睡眠前后电量差 ÷ 睡眠小时数。"
            return TopicDetail(scope: scope, steps: { _ in [
                "运行 `pmset -g batt`，确认电源、电量和充电状态。",
                "运行 `pmset -g assertions`，找出阻止睡眠的进程。对照第 5 节的名单。",
                "运行 `pmset -g log | tail -n 200`，查看最近的睡眠与唤醒记录。输出很长，必须截取。",
                "CPU 与内存只是线索，不能换算成耗电。",
                "只建议退出阻止睡眠的 App。不运行不带 `-g` 的 `pmset`，它会修改电源设置。",
            ] })
        case .network:
            return TopicDetail(scope: "口径：网速是物理网卡合计，不含 VPN 隧道。macOS 不开放每 App 网络数据。", steps: { _ in [
                "运行 `nettop -P -L 1`，找出流量最多的进程。",
                "判断是否为系统更新、iCloud 同步、备份或下载。",
                "只给建议，不修改网络设置。",
            ] })
        }
    }

    // MARK: Safety rules (section 4, never compressed)

    private static func safetyRules(cli: String, dataDir: String) -> [String] {
        [
            "## 4. 安全规则（必须遵守）",
            "1. 先只读诊断，再给建议。",
            "2. 删除、卸载、清理、结束进程、退出 App 之前，先列清单（对象、大小或占用、理由），等我确认。",
            "3. 不用 sudo。不改 SIP、登录项、风扇、SMC 或电源设置。",
            "4. Mole 清理只用预览：`mo clean --dry-run`、`mo purge --dry-run`、`mo installer --dry-run`。不运行 `mo optimize`、`mo uninstall`，也不运行不带 `--dry-run` 的 `mo clean`、`mo purge`、`mo installer`。找不到 `mo` 时告诉我，不要自行安装。",
            "5. 命令报错时，先看 `<命令> --help` 或 `man <命令>`。不猜命令名或参数。",
            "6. 只读工具：`\(cli) --status`、`--disk-history --days 30`、`--events --days 7`（三者都用同一个 CLI 路径），以及 `mo status --json`、`mo history --json`。数据目录：`\(dataDir)`。",
        ]
    }
}
