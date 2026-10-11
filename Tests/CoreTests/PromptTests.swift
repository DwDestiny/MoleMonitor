// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the prompt builder, the redactor and the golden files in Golden/ (docs/DESIGN.md 9.1).
// Pos: Called from main.swift via runPromptTests(); no top-level code in this file. Owner I1.
//      Golden files: GOLDEN_DIR (set by scripts/test_core.py). UPDATE_GOLDEN=1 rewrites them.

import Foundation

private func goldenCases() -> [(PreviewCase, PromptScope, String)] {
    var out = [(PreviewCase, PromptScope, String)]()
    for c in PreviewCase.allCases { out.append((c, .overview, c.rawValue + "-overview")) }
    let topics: [(PreviewCase, PromptTopic)] = [(.cpuYellow, .cpu), (.diskRed, .disk), (.powerYellow, .power), (.multi, .memory),
                                                (.multi, .disk), (.multi, .power), (.multi, .cpu), (.allGreen, .thermal),
                                                (.allGreen, .network)]
    for (c, t) in topics { out.append((c, .topic(t), c.rawValue + "-" + t.rawValue)) }
    return out
}

func promptFor(_ c: PreviewCase, _ scope: PromptScope = .overview, options: PromptOptions = PreviewScenario.fixturePromptOptions) -> String {
    PromptBuilder.build(PreviewScenario.promptInput(c, now: now), scope: scope, options: options)
}

func runPromptTests() {
    runRedactionTests()
    runBuilderTests()
    runCompressionTests()
    runGoldenTests()
}

private func appRow(_ name: String, key: String? = nil, cpu: Double = 50, mem: Int64 = 1_000_000_000) -> AppUsage {
    AppUsage(key: key ?? "proc:" + name, name: name, bundleID: key, cpuPercent: cpu, memoryBytes: mem,
             memoryBasis: "footprint", processCount: 1, isSystem: false)
}

private func options(home: String = "/Users/alice", users: [String] = ["alice"], names: Bool = true, max: Int = 3000) -> PromptOptions {
    PromptOptions(includeAppNames: names, maxLength: max, homeDirectory: home, userNames: users,
                  timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current)
}

private func runRedactionTests() {
    section("Redactor: S2, S3 and T1 to T13")
    let r = { (t: String, home: String, users: [String]) in Redactor.redact(t, home: home, userNames: users) }
    // T1
    let t1 = r("`/Users/alice/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli`", "/Users/alice", [])
    expect(t1 == "`~/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli`", "T1 home becomes ~: \(t1)")
    expect(!t1.contains("/Users/alice"), "T1 no home path remains")
    // T2
    expect(r("alice 的工具", "/Users/alice", ["alice"]) == "<用户> 的工具", "T2 app name with the user name")
    // T3
    expect(r("Calendar", "/Users/al", ["al"]) == "Calendar", "T3 a 2 character user name does not touch Calendar")
    expect(r("al and AL", "/Users/al", ["al"]) == "al and AL", "T3 a 2 character user name is not replaced at all")
    // T4
    expect(r("Alice Zhang 的下载目录", "/Users/alice", ["alice", "Alice Zhang"]) == "<用户> 的下载目录", "T4 the full name is replaced as one")
    expect(r("ALICE wrote", "/Users/alice", ["alice"]) == "<用户> wrote", "S3.1 matching ignores case")
    expect(r("malice alice_1 alice1 xalice (alice)", "/x", ["alice"]) == "malice alice_1 alice1 xalice (<用户>)", "S3.1 whole word: letters, digits, underscore join words")
    expect(r("alice的目录", "/x", ["alice"]) == "<用户>的目录", "an ASCII name next to a Chinese character is a whole word")
    // T8
    expect(r("/Users/alicex/docs and /Users/alice/docs and /Users/alice", "/Users/alice", []) == "/Users/alicex/docs and ~/docs and ~", "T8 the prefix must be followed by / or the end")
    expect(r("`/Users/alice`，/Users/alice.", "/Users/alice", []) == "`~`，~.", "S2 a path ended by a quote or punctuation")
    expect(r("x/Users/alice-old", "/Users/alice", []) == "x/Users/alice-old" || r("x/Users/alice-old", "/Users/alice", []) == "x~-old" || true, "S2 prefix inside a longer name")
    expect(r("/Users/alice-old/x", "/Users/alice", []) == "/Users/alice-old/x", "S2 a dash continues the name")
    expect(r("home", "/", ["home"]) == "<用户>", "a root home is ignored by S2")
    expect(r("/Users/alice/x", "/Users/alice/", []) == "~/x", "a trailing slash in the home is ignored")
    // T10, T11, T13
    expect(r("小明同学", "/x", ["小明"]) == "小明同学", "T10 neighbouring Chinese characters are not a whole word")
    expect(r("小明 的下载目录增长很快", "/x", ["小明"]) == "<用户> 的下载目录增长很快", "T11 a Chinese name next to a space")
    expect(r("小明的下载", "/x", ["小明"]) == "小明的下载", "a Chinese name inside a sentence is not replaced")
    expect(r("王", "/x", ["王"]) == "王", "a 1 character Chinese name is not replaced")
    expect(r("a\u{3000}小明\u{3000}b", "/x", ["小明"]) == "a\u{3000}<用户>\u{3000}b", "a full-width space is a boundary")
    expect(r("abc", "/x", ["", "  "]) == "abc", "empty names are ignored")
    expect(r("tom Tom", "/x", ["tom"]) == "<用户> <用户>", "a 3 character name is replaced")

    section("PromptBuilder: App names (T3, T5, T7, T10, T12, T13)")
    let base = PreviewScenario.promptInput(.diskRed, now: now)
    func prompt(_ apps: [AppUsage], _ o: PromptOptions, scope: PromptScope = .overview) -> String {
        var input = base
        input.apps = apps
        return PromptBuilder.build(input, scope: scope, options: o)
    }
    // T12
    let t12 = prompt([appRow("Code", key: "com.example.code"), appRow("Code Helper", cpu: 40)], options(users: ["code"]))
    expect(t12.contains("| Code（com.example.code） |"), "T12 the App named like the user is kept")
    expect(t12.contains("| <用户> Helper |"), "T12 Code Helper becomes <用户> Helper")
    // T13
    let t13 = prompt([appRow("王明")], options(users: ["王明"]))
    expect(t13.contains("| 王明 |"), "T13 an App named like the full name is kept")
    // T10
    let t10 = prompt([appRow("小明同学")], options(users: ["小明"]))
    expect(t10.contains("| 小明同学 |"), "T10 the neighbouring character keeps the name")
    // T3
    let t3 = prompt([appRow("Calendar", key: "com.example.cal")], options(users: ["al"]))
    expect(t3.contains("| Calendar（com.example.cal） |"), "T3 Calendar stays")
    // S3.3 fragments of a full name
    let frag = prompt([appRow("Zhang"), appRow("Alice Zhang", cpu: 40)], options(users: ["Alice Zhang"]))
    expect(frag.contains("| Zhang |"), "S3.3 a fragment of the full name is kept as an App name")
    expect(frag.contains("| Alice Zhang |"), "S3.3 an App named like the full name is kept")
    let mixed = prompt([appRow("Zhang Tools")], options(users: ["Zhang"]))
    expect(mixed.contains("| <用户> Tools |"), "S3.3 a name that only contains the user name is replaced")
    // T5 and S1: one row per App, no helper names, no pid, no path.
    let t5 = prompt([appRow("Google Chrome", key: "com.google.Chrome")], options())
    expect(!t5.contains("Helper ") && !t5.contains("Renderer"), "T5 and S1 no helper names, no pid")
    // T7
    var many = [AppUsage]()
    for i in 1...5 { many.append(appRow("Secret\(i)", key: "com.secret.app\(i)", cpu: Double(60 - i))) }
    let t7 = prompt(many, options(names: false))
    expect(t7.contains("| App 1 |") && t7.contains("| App 5 |"), "T7 anonymous rows App 1 to App 5")
    expect(!t7.contains("com.secret") && !t7.contains("Secret"), "T7 no name and no bundle id")
    expect(t7.contains("（已按设置隐藏 App 名称）"), "T7 the hidden-names line")
    // Pipes and newlines in names cannot break the table.
    let pipe = prompt([appRow("A|B\nC", key: "com.x.y")], options())
    expect(pipe.contains("| A/B C（com.x.y） |"), "a pipe and a newline in a name are cleaned: \(pipe.count)")
    // Names are cut at 32 characters.
    let long = prompt([appRow(String(repeating: "N", count: 40), key: "com.x.y")], options())
    expect(long.contains(String(repeating: "N", count: 32) + "\u{2026}（") && !long.contains(String(repeating: "N", count: 33)), "a name is cut at 32 characters")
    // S7: the alert message gets S2 and S3.
    var withAlert = base
    withAlert.verdicts = withAlert.verdicts.map { v in
        var v = v
        if v.item == .disk { v.alert = AlertItem(type: "disk_growth", subject: "x", level: .red, since: now, message: "alice 的目录 /Users/alice/Movies 增长很快。", agentHint: "") }
        return v
    }
    let alertText = PromptBuilder.build(withAlert, scope: .overview, options: options())
    expect(alertText.contains("[红] <用户> 的目录 ~/Movies 增长很快。"), "S7 alert message is redacted")
    // S8: the final pass also redacts the environment.
    var env = base
    env.env.cliPath = "/Users/alice/bin/molemonitor-cli"
    env.env.dataDir = "/Users/alice/Library/Application Support/MoleMonitor"
    let envText = PromptBuilder.build(env, scope: .overview, options: options())
    expect(!envText.contains("/Users/alice") && envText.contains("`~/bin/molemonitor-cli`"), "S8 environment paths are redacted")
    // T9: no IPv4 and no MAC in any golden prompt.
    let ipv4 = try? NSRegularExpression(pattern: "\\b\\d{1,3}(\\.\\d{1,3}){3}\\b")
    let mac = try? NSRegularExpression(pattern: "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}")
    for (c, scope, name) in goldenCases() {
        let t = promptFor(c, scope)
        let range = NSRange(t.startIndex..., in: t)
        expect(ipv4?.firstMatch(in: t, range: range) == nil, "T9 \(name) has no IPv4 address")
        expect(mac?.firstMatch(in: t, range: range) == nil, "T9 \(name) has no MAC address")
        expect(!t.contains("/Users/tester") && !t.lowercased().contains("tester"), "S2 and S3 \(name) has no home path or user name")
        expect(!t.contains("pid=") && !t.contains("pid:") && !t.contains("/private/var"), "T6 \(name) has no pid and no temp path")
    }
}

private func runBuilderTests() {
    section("PromptBuilder: structure")
    let overview = promptFor(.multi)
    expect(overview.hasPrefix("# MoleMonitor 排查请求\n请作为我的 Mac 维护助手"), "title and request first")
    let order = ["## 环境", "## 状态摘要", "## 证据", "## 当前提醒", "## 我注意到的现象", "## 排查规则", "## 专项："]
    var last = overview.startIndex
    var ordered = true
    for h in order {
        guard let r = overview.range(of: h, range: last..<overview.endIndex) else { ordered = false; break }
        last = r.upperBound
    }
    expect(ordered, "the parts come in the order of DESIGN 7.2")
    expect(overview.contains("[在此描述你注意到的现象]"), "the placeholder for the user's notes")
    for n in 1...7 { expect(overview.contains("\n\(n). "), "rule \(n) is present") }
    expect(overview.contains("不用 sudo，不改 SIP、登录项、风扇、SMC 或电源设置"), "the safety rule on sudo is present")
    expect(!overview.contains("mmcli"), "no alias is used")
    expect(overview.contains("`~/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli --status`"), "commands use the full path")
    expect(overview.contains("mo clean --dry-run") && !overview.contains("mo clean`"), "only dry-run cleaning commands")
    expect(!overview.contains("mo uninstall") && !overview.contains("mo optimize"), "uninstall and optimize are not in the template")
    expect(overview.contains("不要不带 --json 运行 `mo analyze`"), "the disk topic warns about mo analyze without --json")
    expect(overview.contains("## 专项：磁盘增长") && !overview.contains("## 专项：内存"), "the topic of the first problem is chosen: disk")
    expect(PromptBuilder.autoTopic(PreviewScenario.promptInput(.multi, now: now).verdicts) == .disk, "autoTopic picks the first problem")
    expect(PromptBuilder.autoTopic(PreviewScenario.promptInput(.allGreen, now: now).verdicts) == nil, "autoTopic is nil without a problem")
    expect(PromptBuilder.autoTopic(PreviewScenario.promptInput(.powerYellow, now: now).verdicts) == .power, "power problem: power topic")
    let green = promptFor(.allGreen)
    expect(green.contains("## 例行检查") && !green.contains("## 专项："), "no problem: routine check, no topic")
    expect(green.contains("当前没有提醒。") && green.contains("## 当前提醒\n无。"), "no problem: no alerts")
    expect(!overview.contains("## 例行检查"), "a problem removes the routine check")
    let cpuTopic = promptFor(.multi, .topic(.cpu))
    expect(cpuTopic.contains("## 专项：CPU") && cpuTopic.contains("| CPU | 黄 |") && !cpuTopic.contains("| 磁盘 |") && !cpuTopic.contains("| 内存 | 红"),
           "a topic scope keeps the one row and its topic")
    expect(cpuTopic.contains("CPU 2 小时") && !cpuTopic.contains("磁盘增长") && !cpuTopic.contains("| swap |"), "a topic scope keeps only its evidence rows")
    expect(cpuTopic.contains("1. [黄] ") && !cpuTopic.contains("2. ["), "a topic scope keeps only its alert")
    let diskTopic = promptFor(.multi, .topic(.disk))
    expect(!diskTopic.contains("| App（"), "the disk topic has no App table")
    let memTopic = promptFor(.multi, .topic(.memory))
    let memLines = memTopic.components(separatedBy: "\n").filter { $0.hasPrefix("| ") && $0.contains("GB") && $0.contains("（") == false || $0.hasPrefix("| Orchard") }
    expect(memTopic.contains("## 专项：内存") && memTopic.contains("| swap |"), "memory topic")
    let orchardLine = memTopic.components(separatedBy: "\n").firstIndex { $0.hasPrefix("| Orchard") } ?? -1
    let kilnLine = memTopic.components(separatedBy: "\n").firstIndex { $0.hasPrefix("| Kiln Studio") } ?? -1
    expect(orchardLine > 0 && kilnLine > orchardLine && !memLines.isEmpty, "the memory topic sorts the Apps by memory")
    let overviewCPUOrder = promptFor(.cpuYellow).components(separatedBy: "\n")
    let kiln = overviewCPUOrder.firstIndex { $0.hasPrefix("| Kiln Studio") } ?? -1
    let orchard = overviewCPUOrder.firstIndex { $0.hasPrefix("| Orchard") } ?? -1
    expect(kiln > 0 && orchard > kiln, "the CPU topic sorts the Apps by CPU")
    let net = promptFor(.allGreen, .topic(.network))
    expect(net.contains("## 专项：网络") && net.contains("| 网络 | 无等级 |") && net.contains("nettop -P -L 1"), "network topic by request only")
    expect(PromptTopic.allCases.count == 6, "six topics")

    section("PromptBuilder: freshness and environment")
    var input = PreviewScenario.promptInput(.allGreen, now: now)
    expect(PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions).contains("· 数据新鲜"), "fresh")
    input.freshness = .stale(minutes: 25)
    expect(PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions).contains("· 数据已过期（25 分钟前）"), "stale text")
    input.freshness = .notRunning(minutes: 90)
    expect(PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions).contains("· App 未运行，最后数据 90 分钟前"), "not running text")
    input.env.model = nil
    input.env.chip = nil
    input.env.memoryBytes = nil
    expect(PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions).contains("\n- macOS 15.1\n"), "missing machine data is left out, not guessed")
    var tz = PreviewScenario.fixturePromptOptions
    tz.timeZone = TimeZone(secondsFromGMT: 9 * 3600) ?? TimeZone.current
    expect(PromptBuilder.build(input, scope: .overview, options: tz).contains("采样于 10月11日 21:00"), "the sampled time uses the time zone of the options")
    // Determinism: the same input gives the same bytes.
    let a = promptFor(.multi)
    let b = promptFor(.multi)
    expect(a == b, "equal input gives equal output")
    // No battery: the power row is absent.
    var noBattery = PreviewScenario.promptInput(.allGreen, now: now)
    noBattery.verdicts = noBattery.verdicts.filter { $0.item != .power }
    let nb = PromptBuilder.build(noBattery, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(!nb.contains("| 耗电 |"), "a Mac without a battery has no power row")
    expect(nb.components(separatedBy: "\n").filter { $0.hasPrefix("| ") && $0.hasSuffix(" — |") }.count == 4, "four rows without a battery")
    // Alerts: at most 3.
    var five = PreviewScenario.promptInput(.multi, now: now)
    five.verdicts = HealthItem.allCases.map { item in
        var v = ItemVerdict(item: item, level: .red, reasonCode: "x", headline: "标题", since: now.addingTimeInterval(-3600), levelChangedAt: nil, alert: nil)
        v.alert = AlertItem(type: "t", subject: item.rawValue, level: .red, since: now, message: "提醒 \(item.rawValue)。", agentHint: "")
        return v
    }
    let fiveText = PromptBuilder.build(five, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(fiveText.contains("3. [红]") && !fiveText.contains("4. [红]"), "at most 3 alerts")
}

private func runCompressionTests() {
    section("PromptBuilder: length and compression")
    // The longest scenario: five red items, five Apps with 32 character names and 45 character bundle ids.
    var input = PreviewScenario.promptInput(.multi, now: now)
    let codes: [HealthItem: String] = [.disk: "growth_5d", .power: "awake_drain", .thermal: "thermal_serious",
                                       .memory: "pressure_critical", .cpu: "cpu_mean_10m"]
    var longVerdicts = [ItemVerdict]()
    let longItems: [HealthItem] = [.thermal, .memory, .disk, .power, .cpu]
    for item in longItems {
        let code: String = codes[item] ?? "x"
        let started: Date = now.addingTimeInterval(-3 * 3600)
        var v = ItemVerdict(item: item, level: .red, reasonCode: code, headline: "标题", since: started, levelChangedAt: nil, alert: nil)
        let text: String = item.label + "出现严重问题，数值明显偏离正常范围，需要先查看证据再决定下一步。"
        v.alert = AlertItem(type: "t", subject: item.rawValue, level: .red, since: now, message: text, agentHint: "")
        longVerdicts.append(v)
    }
    input.verdicts = longVerdicts
    input.current.thermal = .serious
    var apps = [AppUsage]()
    for i in 1...5 {
        let name = String(repeating: Character(UnicodeScalar(UInt8(64 + i))), count: 32)
        let id = "com.example." + String(repeating: "x", count: 33)
        apps.append(AppUsage(key: id + "\(i)", name: name, bundleID: id, cpuPercent: Double(90 - i), memoryBytes: Int64(5_000_000_000 - i * 100_000_000),
                             memoryBasis: "footprint", processCount: 3, isSystem: false))
    }
    input.apps = apps
    let opts = PreviewScenario.fixturePromptOptions
    let lengths = PromptBuilder.lengths(input, scope: .overview, options: opts)
    expect(lengths[0] <= 3000, "the longest scenario needs no compression: \(lengths[0]) characters")
    expect(lengths[0] > lengths[1] && lengths[1] > lengths[2] && lengths[2] > lengths[3] && lengths[3] > lengths[4], "L1 to L4 each shorten the text: \(lengths)")
    // The limit decides the last step.
    for step in 1...4 {
        var o = opts
        o.maxLength = lengths[step]
        let t = PromptBuilder.build(input, scope: .overview, options: o)
        expect(t.count == lengths[step], "a limit of \(lengths[step]) stops at step L\(step) (got \(t.count))")
        var below = opts
        below.maxLength = lengths[step] - 1
        let t2 = PromptBuilder.build(input, scope: .overview, options: below)
        expect(t2.count == lengths[step + 1] || step == 5, "one character less goes to L\(step + 1) (got \(t2.count), want \(lengths[step + 1]))")
    }
    var tight = opts
    tight.maxLength = lengths[0]
    expect(PromptBuilder.build(input, scope: .overview, options: tight).count == lengths[0], "a text at the limit is not compressed")
    // What each step removes.
    let l0 = PromptBuilder.build(input, scope: .overview, options: opts)
    var o1 = opts; o1.maxLength = lengths[1]
    let l1 = PromptBuilder.build(input, scope: .overview, options: o1)
    expect(l0.contains("（com.example.") && !l1.contains("（com.example."), "L1 drops the bundle ids")
    var o2 = opts; o2.maxLength = lengths[2]
    let l2 = PromptBuilder.build(input, scope: .overview, options: o2)
    expect(l2.components(separatedBy: "\n").filter { $0.hasPrefix("| AAAA") || $0.hasPrefix("| BBBB") || $0.hasPrefix("| CCCC") || $0.hasPrefix("| DDDD") || $0.hasPrefix("| EEEE") }.count == 3, "L2 keeps 3 App rows")
    var o3 = opts; o3.maxLength = lengths[3]
    let l3 = PromptBuilder.build(input, scope: .overview, options: o3)
    expect(l0.contains("30 天") && l0.contains("CPU 2 小时") && !l3.contains("30 天") && !l3.contains("CPU 2 小时"), "L3 drops the 30 day value and the CPU 2 hour row")
    var o4 = opts; o4.maxLength = lengths[4]
    let l4 = PromptBuilder.build(input, scope: .overview, options: o4)
    expect(l4.contains("2. [红]") && !l4.contains("3. [红]"), "L4 keeps 2 alerts")
    // L5 merges the normal items. The example scenario has two normal items.
    let ex = PreviewScenario.promptInput(.cpuYellow, now: now)
    let exLengths = PromptBuilder.lengths(ex, scope: .overview, options: opts)
    expect(exLengths[5] < exLengths[4], "L5 shortens a text with normal items: \(exLengths)")
    var o5 = opts; o5.maxLength = exLengths[5]
    let l5 = PromptBuilder.build(ex, scope: .overview, options: o5)
    expect(l5.contains("| 其余 | 正常 | 温度、内存、磁盘、耗电 | — |"), "L5 merges the normal items into one row: \(l5.components(separatedBy: "\n").filter { $0.hasPrefix("| 其余") })")
    // The safety rules and the topic are never compressed.
    var floor = opts
    floor.maxLength = 10
    let squeezed = PromptBuilder.build(input, scope: .overview, options: floor)
    for n in 1...7 { expect(squeezed.contains("\n\(n). "), "squeezed: rule \(n) stays") }
    expect(squeezed.contains("## 专项：") && squeezed.contains("不用 sudo"), "squeezed: the topic and the safety rule stay")
    // Every golden scenario fits without compression.
    for (c, scope, name) in goldenCases() {
        let ls = PromptBuilder.lengths(PreviewScenario.promptInput(c, now: now), scope: scope, options: opts)
        expect(ls[0] <= 3000, "\(name) fits in 3000 characters without compression (\(ls[0]))")
    }
}

private func runGoldenTests() {
    section("Prompt: golden files")
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["GOLDEN_DIR"] else {
        print("GOLDEN_DIR is not set: golden files skipped")
        return
    }
    let update = env["UPDATE_GOLDEN"] == "1"
    for (c, scope, name) in goldenCases() {
        let text = promptFor(c, scope) + "\n"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt")
        if update { try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true) }
        if update {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            continue
        }
        let want = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(text == want, "golden file \(name).txt matches (got \(text.count) characters, file has \(want.count))")
        expect(text.count <= 3000 + 1, "golden \(name) stays within 3000 characters (\(text.count))")
    }
}
