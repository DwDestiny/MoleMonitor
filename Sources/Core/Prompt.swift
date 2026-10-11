// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, current readings, top apps and environment data (docs/DESIGN.md 7, 8.1).
// Output: The Chinese prompt text for "复制给 Agent", and the redaction of private text (S1 to S8).
// Pos: Pure text building shared by the app and `molemonitor-cli prompt`; Foundation only. Owner I1.
//      The text depends only on the input and the options: the "now" of the text is `sampledAt`, the time zone
//      comes from the options, and no DateFormatter is used. Equal input gives equal output (App and CLI).
//      Length: Swift `String.count`, limit 3000. Only a longer text runs the compression steps L1 to L5.
//      The safety rules and the topic section are never compressed.

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
    var maxLength = 3000          // Only a longer text triggers the L1 to L5 compression
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

    static func build(_ input: PromptInput, scope: PromptScope, options: PromptOptions) -> String {
        var text = ""
        for step in 0...5 {
            text = render(input, scope: scope, options: options, compression: Compression(level: step))
            if text.count <= options.maxLength { break }
        }
        return text
    }

    /// Number of characters at each compression level 0 to 5. Used by tests to check the steps.
    static func lengths(_ input: PromptInput, scope: PromptScope, options: PromptOptions) -> [Int] {
        (0...5).map { render(input, scope: scope, options: options, compression: Compression(level: $0)).count }
    }

    // MARK: Compression steps (DESIGN.md 7.6)

    struct Compression {
        var level: Int
        var dropBundleID: Bool { level >= 1 }       // L1
        var appRows: Int { level >= 2 ? 3 : 5 }     // L2
        var trimMetrics: Bool { level >= 3 }        // L3
        var alertCount: Int { level >= 4 ? 2 : 3 }  // L4
        var mergeNormal: Bool { level >= 5 }        // L5
    }

    // MARK: Rendering

    private static func render(_ input: PromptInput, scope: PromptScope, options: PromptOptions,
                               compression c: Compression) -> String {
        let now = input.sampledAt
        let ordered = ProblemOrder.all(input.verdicts)
        let problems = ProblemOrder.problems(input.verdicts)

        // Scope: which verdicts and which topic.
        var shown = ordered
        var shownProblems = problems
        var topic: PromptTopic?
        var routine = false
        var topicScope = false
        switch scope {
        case .overview:
            topic = autoTopic(input.verdicts)
            routine = problems.isEmpty
        case .topic(let t):
            topic = t
            topicScope = true
            shown = ordered.filter { ProblemOrder.topic(for: $0.item) == t }
            shownProblems = problems.filter { ProblemOrder.topic(for: $0.item) == t }
        }

        let noData = hasNoData(input)
        var protect = AppNameProtection(userNames: options.userNames)
        var lines = [String]()
        lines.append("# MoleMonitor 排查请求")
        lines.append("请作为我的 Mac 维护助手，根据以下只读监测数据排查问题，并给出优化建议。")
        lines.append("")

        // Environment.
        lines.append("## 环境")
        lines.append("- " + environmentLine(input.env))
        let sampled: String = TextFormat.dateTime(input.sampledAt, timeZone: options.timeZone)
        lines.append("- MoleMonitor \(input.env.appVersion) · 采样于 \(sampled) · " + freshnessText(input.freshness))
        lines.append("- CLI：`\(input.env.cliPath)`")
        lines.append("")

        // Summary.
        lines.append("## 状态摘要")
        lines.append("| 项 | 等级 | 当前 | 已持续 |")
        lines.append("|---|---|---|---|")
        lines.append(contentsOf: summaryRows(input, shown: shown, networkRow: topicScope && topic == .network,
                                             options: options, mergeNormal: c.mergeNormal, now: now))
        lines.append("")

        if noData {
            // No usable data: no evidence table and no alert list. The agent must not judge from old or missing values.
            lines.append("## 数据不可用")
            lines.append(contentsOf: noDataLines(input.freshness, cli: input.env.cliPath))
            lines.append("")
        } else {
            // Evidence.
            lines.append("## 证据")
            var evidence = [String]()
            if showsApps(topicScope: topicScope, topic: topic) {
                let key: AppSortKey = topic == .memory ? .memory : .cpu
                let top = AppRanking.top(input.apps, by: key, count: c.appRows)
                if !top.isEmpty {
                    var table = [String]()
                    if !options.includeAppNames { table.append("（已按设置隐藏 App 名称）") }
                    table.append("| App（\(input.appsBasis)） | CPU | 内存 |")
                    table.append("|---|---|---|")
                    for (index, app) in top.enumerated() {
                        let name = appLabel(app, index: index, options: options, dropBundleID: c.dropBundleID, protect: &protect)
                        table.append("| \(name) | \(TextFormat.percent(app.cpuPercent)) | \(TextFormat.bytes(app.memoryBytes)) |")
                    }
                    evidence.append(table.joined(separator: "\n"))
                }
            }
            let metrics = metricRows(input, topicScope: topicScope, topic: topic, trim: c.trimMetrics, options: options)
            if !metrics.isEmpty {
                var table = ["| 指标 | 值 |", "|---|---|"]
                for (label, value) in metrics { table.append("| \(label) | \(value) |") }
                evidence.append(table.joined(separator: "\n"))
            }
            if evidence.isEmpty { evidence.append("暂无数据。") }
            lines.append(evidence.joined(separator: "\n\n"))
            lines.append("")

            // Alerts.
            lines.append("## 当前提醒")
            let alertRows = alertTexts(shownProblems, options: options)
            if alertRows.isEmpty {
                lines.append("无。")
            } else {
                for (n, row) in alertRows.prefix(c.alertCount).enumerated() { lines.append("\(n + 1). \(row)") }
            }
            lines.append("")
        }

        // Notes placeholder and routine check.
        lines.append("## 我注意到的现象")
        lines.append("[在此描述你注意到的现象]")
        lines.append("")
        if routine && !noData {
            lines.append("## 例行检查")
            lines.append("当前没有提醒。请做一次快速体检：")
            lines.append("1. 运行 `\(input.env.cliPath) --disk-history --days 30`，看磁盘是否持续增长。")
            lines.append("2. 运行 `mo status --json`，看是否有长期高占用的进程。")
            lines.append("3. 只汇报发现，不做任何改动。")
            lines.append("")
        }

        // Rules.
        lines.append("## 排查规则")
        lines.append(contentsOf: rules(cli: input.env.cliPath, dataDir: input.env.dataDir))
        var text = lines.joined(separator: "\n")
        if let topic, !noData {
            text += "\n" + topicSection(topic, cli: input.env.cliPath)
            if !topicScope {
                let extra = otherProblems(problems, mainTopic: topic, cli: input.env.cliPath)
                if !extra.isEmpty { text += "\n" + extra }
            }
        }

        // S8: the last step runs S2 and S3 on the whole text, then the App names return.
        text = Redactor.redact(text, home: options.homeDirectory, userNames: options.userNames)
        return protect.restore(text)
    }

    // MARK: Environment

    private static func environmentLine(_ env: PromptEnvironment) -> String {
        var parts = [String]()
        if let m = env.model, !m.isEmpty { parts.append(m) }
        if let c = env.chip, !c.isEmpty { parts.append(c) }
        if let bytes = env.memoryBytes {
            let gb: Int = Int((Double(bytes) / 1_073_741_824).rounded())
            parts.append("内存 \(gb) GB")
        }
        parts.append("macOS \(env.os)")
        return parts.joined(separator: " · ")
    }

    private static func freshnessText(_ f: PromptFreshness) -> String {
        switch f {
        case .fresh: return "数据新鲜"
        case .stale(let m): return "数据已过期（\(m) 分钟前）"
        case .notRunning(let m): return "App 未运行，最后数据 \(m) 分钟前"
        }
    }

    // MARK: Summary rows

    private static func summaryRows(_ input: PromptInput, shown: [ItemVerdict], networkRow: Bool, options: PromptOptions,
                                    mergeNormal: Bool, now: Date) -> [String] {
        var rows = [String]()
        var normalNames = [String]()
        let normalCount = shown.filter { $0.level == .green }.count
        let merge = mergeNormal && normalCount >= 2
        let dash = "\u{2014}"
        for v in shown {
            if merge && v.level == .green {
                normalNames.append(v.item.label)
                continue
            }
            let since: String = v.isProblem ? TextFormat.duration(since: v.since, now: now) : dash
            let current = currentText(v, input: input, options: options)
            rows.append("| \(v.item.label) | \(TextFormat.levelWord(v.level)) | \(current) | \(since) |")
        }
        if merge {
            rows.append("| 其余 | 正常 | \(normalNames.joined(separator: "、")) | \(dash) |")
        }
        if networkRow {
            rows.append("| 网络 | 无等级 | \(networkText(input.current)) | \(dash) |")
        }
        return rows
    }

    private static func networkText(_ cur: CurrentReadings) -> String {
        "\u{2193} " + RateText.text(cur.rx) + " \u{2191} " + RateText.text(cur.tx)
    }

    static func currentText(_ v: ItemVerdict, input: PromptInput, options: PromptOptions) -> String {
        let dash = "\u{2014}"
        if v.level == .unknown || v.level == .stale { return dash }
        let cur = input.current
        switch v.item {
        case .cpu:
            if v.reasonCode == "app_saturated" {
                return options.includeAppNames ? v.headline : "有 App 占满一个核"
            }
            return "10 分钟均值 " + TextFormat.percent(cur.cpuMean10m)
        case .memory:
            let pressure: String = cur.pressure?.label ?? dash
            var text = "压力" + pressure + "，swap " + TextFormat.bytes(cur.swapUsed)
            if let trend = cur.swapTrend { text += " " + trend.arrow }
            return text
        case .thermal:
            guard let t = cur.thermal else { return dash }
            return t.label + "（" + t.rawValue + "）"
        case .disk:
            return diskText(v, input: input)
        case .power:
            return powerText(v, cur: cur)
        }
    }

    private static func diskText(_ v: ItemVerdict, input: PromptInput) -> String {
        var avail: String?
        if let a = input.current.diskAvailable { avail = "可用 " + ByteText.gb(a) }
        if v.isProblem, v.reasonCode.hasPrefix("growth_") {
            let key = String(v.reasonCode.dropFirst("growth_".count))
            let days = key.hasSuffix("d") ? String(key.dropLast()) : key
            let growth: Int64? = input.diskGrowth[key]?.bytes
            var text = "\(days) 天 " + TextFormat.signedDiskGB(growth)
            if let avail { text += "，" + avail }
            return text
        }
        return avail ?? "\u{2014}"
    }

    private static func powerText(_ v: ItemVerdict, cur: CurrentReadings) -> String {
        if v.reasonCode == "sleep_drain", let s = cur.lastSleep {
            let seconds = s.wokeAt.timeIntervalSince(s.sleptAt)
            let rate: Double = seconds > 0 ? (s.batteryBefore - s.batteryAfter) / (seconds / 3600) : 0
            let span = TextFormat.span(seconds: seconds)
            let levels = String(format: "%.0f%% \u{2192} %.0f%%", s.batteryBefore, s.batteryAfter)
            return "睡眠 " + span + "，" + levels + "，" + String(format: "%.1f", rate) + "%/小时"
        }
        if v.reasonCode == "awake_drain", let rate = cur.awakeDrainPerHour {
            return "电池供电，掉电 " + String(format: "%.0f", rate) + "%/小时"
        }
        guard let b = cur.batteryPercent else { return "\u{2014}" }
        return "电量 " + String(format: "%.0f%%", b)
    }

    // MARK: Evidence

    private static func showsApps(topicScope: Bool, topic: PromptTopic?) -> Bool {
        if !topicScope { return true }
        guard let topic else { return false }
        return topic == .cpu || topic == .memory || topic == .thermal || topic == .power
    }

    private static func metricRows(_ input: PromptInput, topicScope: Bool, topic: PromptTopic?, trim: Bool,
                                   options: PromptOptions) -> [(String, String)] {
        let cur = input.current
        func want(_ t: PromptTopic) -> Bool { !topicScope || topic == t }
        func problem(_ item: HealthItem) -> ItemVerdict? { input.verdicts.first { $0.item == item && $0.isProblem } }
        var rows = [(String, String)]()

        if want(.memory), let swap = cur.swapUsed {
            var value = TextFormat.bytes(swap)
            if let g = cur.swapGrowth30m { value += "，30 分钟 " + TextFormat.signedBytes(g) }
            rows.append(("swap", value))
        }
        if want(.disk) {
            var parts = [String]()
            var any = false
            for (key, label) in [("1d", "1 天"), ("5d", "5 天"), ("30d", "30 天")] {
                let g: Int64? = input.diskGrowth[key]?.bytes
                if g != nil { any = true }
                if trim && key == "30d" { continue }
                parts.append(label + " " + TextFormat.signedDiskGB(g))
            }
            if any { rows.append(("磁盘增长", parts.joined(separator: " · "))) }
        }
        if want(.cpu), !trim, let s = input.cpuSummary {
            rows.append(("CPU 2 小时", "均值 " + TextFormat.percent(s.mean) + "，峰值 " + TextFormat.percent(s.peak)))
        }
        let thermalWanted: Bool = (topicScope && topic == .thermal) || (!topicScope && problem(.thermal) != nil)
        if thermalWanted, let t = cur.thermal {
            var value = t.label + "（" + t.rawValue + "）"
            if let p = problem(.thermal), let since = p.since {
                value += "，问题开始于 " + TextFormat.dateTime(since, timeZone: options.timeZone)
            }
            rows.append(("热状态", value))
        }
        let powerProblem = problem(.power)
        let powerWanted: Bool = (topicScope && topic == .power) || (!topicScope && powerProblem != nil)
        if powerWanted {
            if let b = cur.batteryPercent {
                var value = String(format: "%.0f%%", b)
                if let s = cur.powerSource { value += s == .ac ? "，接电源" : "，电池供电" }
                rows.append(("电量", value))
            }
            if let s = cur.lastSleep {
                let span = TextFormat.span(seconds: s.wokeAt.timeIntervalSince(s.sleptAt))
                rows.append(("上次睡眠", span + "，" + String(format: "%.0f%% \u{2192} %.0f%%", s.batteryBefore, s.batteryAfter)))
            }
            if let d = cur.awakeDrainPerHour, powerProblem?.reasonCode == "awake_drain" || topic == .power {
                rows.append(("近 60 分钟", "电量约下降 " + String(format: "%.0f", d) + "%"))
            }
        }
        if topicScope && topic == .network {
            rows.append(("网速", networkText(cur) + "（物理网卡合计）"))
        }
        return rows
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

    private static func appLabel(_ app: AppUsage, index: Int, options: PromptOptions, dropBundleID: Bool,
                                 protect: inout AppNameProtection) -> String {
        if !options.includeAppNames { return "App \(index + 1)" }
        var name = clean(app.name)
        if name.count > 32 { name = String(name.prefix(32)) + "\u{2026}" }
        let guarded = protect.guardText(name)
        var label = guarded
        if !dropBundleID, let id = app.bundleID, !id.isEmpty {
            let cleanID = clean(id)
            let shownID = guarded == name ? cleanID : protect.guardText(cleanID, force: true)
            label += "（" + shownID + "）"
        }
        return label
    }

    // MARK: Alerts

    private static func alertTexts(_ problems: [ItemVerdict], options: PromptOptions) -> [String] {
        var out = [String]()
        for v in problems {
            var message: String = v.alert?.message ?? (v.item.label + "：" + v.headline)
            if !options.includeAppNames && v.reasonCode == "app_saturated" { message = "有 App 持续占满一个核。" }
            let line = "[" + TextFormat.levelWord(v.level) + "] " + clean(message)
            // S7: the message gets S2 and S3 on its own, before the final pass.
            out.append(Redactor.redact(line, home: options.homeDirectory, userNames: options.userNames))
        }
        return out
    }

    // MARK: Fixed text

    // MARK: No data and other problems

    /// True when the numbers cannot be trusted: stale data, a stopped App, or every item still collecting or stale.
    static func hasNoData(_ input: PromptInput) -> Bool {
        switch input.freshness {
        case .stale, .notRunning: return true
        case .fresh: break
        }
        if input.verdicts.isEmpty { return false }
        return input.verdicts.allSatisfy { $0.level == .unknown || $0.level == .stale }
    }

    private static func noDataLines(_ f: PromptFreshness, cli: String) -> [String] {
        var out = [String]()
        switch f {
        case .stale(let m): out.append("监测数据已过期（\(m) 分钟前），当前读数不可信。")
        case .notRunning(let m): out.append("MoleMonitor 未运行，最后数据在 \(m) 分钟前，当前读数不可信。")
        case .fresh: out.append("MoleMonitor 刚开始运行，还在收集首批数据，当前没有可用读数。")
        }
        out.append("不要根据这些数据判断问题，也不要推测问题。")
        out.append("1. 运行 `\(cli) --status`，确认 App 在运行且数据是新的。")
        out.append("2. 如果 App 未运行，告诉我，等我启动后再排查。不要自行启动或安装。")
        out.append("3. 如果数据已是新的，按新数据重新判断。")
        return out
    }

    /// The first read-only step of a topic, for the problems that get no topic section.
    private static func firstStep(_ topic: PromptTopic, cli: String) -> String {
        switch topic {
        case .disk: return "运行 `\(cli) --disk-history --days 30`，找出增长集中的日期。"
        case .memory: return "运行 `sysctl vm.swapusage` 与 `vm_stat`，确认 swap 与压缩内存。"
        case .cpu: return "运行 `ps -Ao pid,pcpu,time,comm -r | head -n 15`，找出占用最高的进程。"
        case .thermal: return "运行 `pmset -g therm`，确认是否有降频记录。"
        case .power: return "运行 `pmset -g batt`，确认电源、电量和充电状态。"
        case .network: return "运行 `nettop -P -L 1`，找出流量最多的进程。"
        }
    }

    /// One line for each problem that the topic section does not cover, in problem order.
    private static func otherProblems(_ problems: [ItemVerdict], mainTopic: PromptTopic, cli: String) -> String {
        var rows = [String]()
        for v in problems {
            guard let topic = ProblemOrder.topic(for: v.item), topic != mainTopic else { continue }
            let level: String = v.level == .red ? "红" : "黄"
            rows.append("- [\(level)] \(topicName(topic))：\(firstStep(topic, cli: cli))")
        }
        if rows.isEmpty { return "" }
        let head = "\n## 其他问题\n上面的专项只展开了排在最前的问题。下面的问题也要排查，每个只给第一条只读命令。回复时按严重程度汇报全部问题："
        return head + "\n" + rows.joined(separator: "\n")
    }

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

    private static func rules(cli: String, dataDir: String) -> [String] {
        var out = [String]()
        out.append("1. 先只读诊断，再给建议。")
        out.append("2. 删除、卸载、清理、结束进程、退出 App 前，都先列清单（对象、大小、理由），等我确认。")
        out.append("3. 不用 sudo，不改 SIP、登录项、风扇、SMC 或电源设置。")
        out.append("4. 只读工具：`\(cli) --status`、`\(cli) --disk-history --days 30`、`mo status --json`、`mo history --json`。数据目录：`\(dataDir)`。")
        out.append("5. Mole 清理只用预览：`mo clean --dry-run`、`mo purge --dry-run`、`mo installer --dry-run`。不运行 `mo optimize`、`mo uninstall`，也不运行不带 `--dry-run` 的 `mo clean`、`mo purge`、`mo installer`。如果找不到 `mo`，说明我没有安装 Mole，不要自行安装。")
        out.append("6. 命令报错时先运行 `<命令> --help` 或 `man <命令>`，不猜命令名或参数。")
        out.append("7. 回复：结论一句 \u{2192} 证据 \u{2192} 下一步（标明是否改动系统）。")
        return out
    }

    /// The topic section starts with an empty line, like the template.
    static func topicSection(_ topic: PromptTopic, cli: String) -> String {
        switch topic {
        case .disk:
            return """

            ## 专项：磁盘增长
            口径：真实已用已排除可清除空间。增长量 = 当前值 − 窗口内最低值。
            1. 运行 `\(cli) --disk-history --days 30`，找出增长集中的日期。
            2. 运行 `mo analyze --json ~` 找最大目录，再对其中最大的子目录运行 `mo analyze --json <目录>`。不要不带 --json 运行 `mo analyze`，交互模式可能把文件移到废纸篓。
            3. 对照日期判断来源：下载、虚拟机镜像、Xcode 数据、容器镜像、照片库、本地备份。
            4. 列出可回收项：路径（家目录写 ~）、大小、能否再生成。只用 dry-run 预览。
            """
        case .memory:
            return """

            ## 专项：内存
            口径：看内存压力与 swap 增长，不看已用百分比。
            1. 运行 `sysctl vm.swapusage` 与 `vm_stat`，确认 swap 与压缩内存。
            2. 运行 `ps -Ao pid,rss,comm -m | head -n 15`，对照上表找出大户。
            3. 5 分钟后再运行第 2 步。持续上涨的 App 可能有泄漏。
            4. 建议顺序：重启该 App（先问我）→ 减少标签页或扩展。不建议 `sudo purge` 或内存清理软件。
            """
        case .cpu:
            return """

            ## 专项：CPU
            口径：单核满载为 100%，多核可超过 100%。
            1. 运行 `ps -Ao pid,pcpu,time,comm -r | head -n 15`，找出占用最高的进程。
            2. 1 分钟后再运行一次，区分短时尖峰与持续占用。
            3. 系统进程（mds_stores、mdworker、photoanalysisd、backupd）：说明用途，通常等它完成，不结束它。
            4. 用户 App：先列出进程与理由，等我确认后，再建议保存并正常退出。不要自行结束进程，不直接 `kill -9`。
            """
        case .thermal:
            return """

            ## 专项：温度
            口径：等级来自系统热状态 thermalState，不是传感器读数。
            1. 运行 `pmset -g therm`，确认是否有降频记录。
            2. 对照上表的 CPU 占用找出热源进程。
            3. 检查环境：是否放在软面上、是否接外接显示器、是否在充电。
            4. 只建议降低负载，不建议控制风扇或修改 SMC。
            """
        case .power:
            return """

            ## 专项：耗电
            口径：耗电来自电池电量读数，不来自 CPU 估算。睡眠掉电 = 睡眠前后电量差 ÷ 睡眠小时数。
            1. 运行 `pmset -g batt`，确认电源、电量和充电状态。
            2. 运行 `pmset -g assertions`，找出阻止睡眠的进程。
            3. 运行 `pmset -g log | tail -n 200`，查看最近的睡眠与唤醒记录。输出很长，必须截取。
            4. 上表的 CPU 与内存只是线索，不能换算成耗电。
            5. 只建议退出阻止睡眠的 App。不运行不带 -g 的 pmset，它会修改电源设置。
            """
        case .network:
            return """

            ## 专项：网络
            口径：网速是物理网卡合计，不含 VPN 隧道。
            1. 运行 `nettop -P -L 1`，找出流量最多的进程。
            2. 判断是否为系统更新、iCloud 同步、备份或下载。
            3. 只给建议，不修改网络设置。
            """
        }
    }
}
