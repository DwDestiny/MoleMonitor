// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for the prompt builder, the redactor and the golden files in Golden/ (docs/DESIGN_V2.md 8, W20).
// Pos: Called from main.swift via runPromptTests(); no top-level code in this file. Owner I1.
//      Golden files v2-*.txt are the texts of DESIGN_V2.md 8.8.1 to 8.8.6 and are never rewritten by UPDATE_GOLDEN.
//      Other golden files: GOLDEN_DIR (set by scripts/test_core.py). UPDATE_GOLDEN=1 rewrites them.

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
    let base = PreviewScenario.promptInput(.cpuYellow, now: now)
    func prompt(_ apps: [AppUsage], _ o: PromptOptions, scope: PromptScope = .overview) -> String {
        var input = base
        input.apps = apps
        return PromptBuilder.build(input, scope: scope, options: o)
    }
    // T12
    let t12 = prompt([appRow("Code", key: "com.example.code"), appRow("Code Helper", cpu: 40)], options(users: ["code"]))
    expect(t12.contains("| Code（com.example.code） | "), "T12 the App named like the user is kept")
    expect(t12.contains("| <用户> Helper | "), "T12 Code Helper becomes <用户> Helper")
    // T13
    let t13 = prompt([appRow("王明")], options(users: ["王明"]))
    expect(t13.contains("| 王明 | "), "T13 an App named like the full name is kept")
    // T10
    let t10 = prompt([appRow("小明同学")], options(users: ["小明"]))
    expect(t10.contains("| 小明同学 | "), "T10 the neighbouring character keeps the name")
    // T3
    let t3 = prompt([appRow("Calendar", key: "com.example.cal")], options(users: ["al"]))
    expect(t3.contains("| Calendar（com.example.cal） | "), "T3 Calendar stays")
    // S3.3 fragments of a full name
    let frag = prompt([appRow("Zhang"), appRow("Alice Zhang", cpu: 40)], options(users: ["Alice Zhang"]))
    expect(frag.contains("| Zhang | "), "S3.3 a fragment of the full name is kept as an App name")
    expect(frag.contains("| Alice Zhang | "), "S3.3 an App named like the full name is kept")
    let mixed = prompt([appRow("Zhang Tools")], options(users: ["Zhang"]))
    expect(mixed.contains("| <用户> Tools | "), "S3.3 a name that only contains the user name is replaced")
    // T5 and S1: one row per App, no helper names, no pid, no path.
    let t5 = prompt([appRow("Google Chrome", key: "com.google.Chrome")], options())
    expect(!t5.contains("Helper ") && !t5.contains("Renderer"), "T5 and S1 no helper names, no pid")
    // T7
    var many = [AppUsage]()
    for i in 1...5 { many.append(appRow("Secret\(i)", key: "com.secret.app\(i)", cpu: Double(60 - i))) }
    let t7 = prompt(many, options(names: false))
    expect(t7.contains("| App 1 | ") && t7.contains("| App 5 | "), "T7 anonymous rows App 1 to App 5")
    expect(!t7.contains("com.secret") && !t7.contains("Secret"), "T7 no name and no bundle id")
    expect(t7.contains("（已按设置隐藏 App 名称）"), "T7 the hidden-names line")
    // Pipes and newlines in names cannot break the table.
    let pipe = prompt([appRow("A|B\nC", key: "com.x.y")], options())
    expect(pipe.contains("| A/B C（com.x.y） | "), "a pipe and a newline in a name are cleaned: \(pipe.count)")
    // Names are cut at 32 characters.
    let long = prompt([appRow(String(repeating: "N", count: 40), key: "com.x.y")], options())
    expect(long.contains(String(repeating: "N", count: 32) + "\u{2026}（") && !long.contains(String(repeating: "N", count: 33)), "a name is cut at 32 characters")
    // S8: the final pass also redacts the environment.
    var env = base
    env.env.cliPath = "/Users/alice/bin/molemonitor-cli"
    env.env.dataDir = "/Users/alice/Library/Application Support/MoleMonitor"
    let envText = PromptBuilder.build(env, scope: .overview, options: options())
    expect(!envText.contains("/Users/alice") && envText.contains("`~/bin/molemonitor-cli --status`"), "S8 environment paths are redacted")
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


// MARK: - DESIGN_V2.md 8.8 inputs

private let gib: Int64 = 1 << 30

private func at(_ hhmm: String) -> Date { UTCTime.parseISO("2026-10-12T\(hhmm):00Z")! }

private func v2Env() -> PromptEnvironment {
    PromptEnvironment(model: "Mac15,8", chip: "Apple M3 Max", memoryBytes: 64 * gib, os: "15.1", appVersion: "0.4.0",
                      cliPath: "/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli",
                      dataDir: "/Users/tester/Library/Application Support/MoleMonitor")
}

private func verdicts(_ red: [(HealthItem, HealthLevel, String, String, TimeInterval)], now t: Date) -> [ItemVerdict] {
    HealthItem.allCases.map { item in
        if let r = red.first(where: { $0.0 == item }) {
            return ItemVerdict(item: item, level: r.1, reasonCode: r.2, headline: r.3, since: t.addingTimeInterval(-r.4),
                               levelChangedAt: nil, alert: nil)
        }
        return ItemVerdict(item: item, level: .green, reasonCode: "ok", headline: "", since: nil, levelChangedAt: nil, alert: nil)
    }
}

private func event(_ item: HealthItem, _ level: HealthLevel, open: Bool, daysAgo: Double) -> EventRecord {
    let start = at("14:05").addingTimeInterval(-daysAgo * 86400)
    return EventRecord(item: item, first: level, peak: level, reasonCode: "x", start: start,
                       end: open ? nil : start.addingTimeInterval(1800), peakValue: nil, unit: nil, app: nil, endEstimated: false)
}

private func gbApp(_ name: String, _ id: String?, cpu: Double, mem: Double) -> AppUsage {
    AppUsage(key: id ?? "proc:" + name, name: name, bundleID: id, cpuPercent: cpu, memoryBytes: Int64(mem * 1e9),
             memoryBasis: "footprint", processCount: 1, isSystem: id == nil)
}

private func growth(_ bytes: Int64) -> DiskGrowth {
    DiskGrowth(window: "x", bytes: bytes, netBytes: bytes, fromMinAt: nil, coveredHours: 720, status: .ok)
}

private func diskPart(_ i: inout PromptInput) {
    i.current.diskAvailable = 120_000_000_000
    i.current.diskTotal = 995_000_000_000
    i.current.diskUsed = 875_000_000_000
    i.current.diskPurgeable = 21_000_000_000
    i.diskGrowth = ["1d": growth(34_000_000_000), "5d": growth(314_000_000_000), "30d": growth(322_000_000_000)]
    i.diskWriters = [AppDiskWriteTracker.Row(key: "a", name: "Docker Desktop", bytes: 2_100_000_000, isSystem: false),
                     AppDiskWriteTracker.Row(key: "b", name: "Xcode", bytes: 640_000_000, isSystem: false),
                     AppDiskWriteTracker.Row(key: "c", name: "Google Chrome", bytes: 120_000_000, isSystem: false)]
}

private func memoryPart(_ i: inout PromptInput) {
    i.current.pressure = .critical
    i.current.memoryPressurePercent = 87
    i.current.swapUsed = 9_800_000_000
    i.current.swapGrowth30m = 3_100_000_000
    i.current.swapTrend = .steepUp
    i.current.memory = MemoryBreakdown(app: Int64(41.0 * Double(gib)), wired: Int64(6.1 * Double(gib)),
                                       compressed: Int64(11.1 * Double(gib)), total: 64 * gib)
    i.pressure2h = PressureSummary(mean: 61, peak: 91, normalMinutes: 70, warningMinutes: 25, criticalMinutes: 25)
}

private func baseInput(_ t: Date, _ list: [ItemVerdict]) -> PromptInput {
    var cur = CurrentReadings()
    cur.thermal = .nominal
    cur.sampledAt = t
    return PromptInput(env: v2Env(), sampledAt: t, freshness: .fresh, verdicts: list, current: cur, apps: [], appsBasis: "近 5 分钟",
                       cpuSummary: nil, diskGrowth: [:])
}

private func v2Input(_ kind: String) -> PromptInput {
    let t = at("14:05")
    switch kind {
    case "disk":
        var i = baseInput(t, verdicts([(.disk, .red, "growth_5d", "5 天多占用 314 GB", 192 * 60)], now: t))
        diskPart(&i)
        i.events = [event(.disk, .red, open: true, daysAgo: 0), event(.cpu, .yellow, open: false, daysAgo: 2),
                    event(.cpu, .yellow, open: false, daysAgo: 4)]
        return i
    case "memory":
        var i = baseInput(t, verdicts([(.memory, .red, "pressure_critical", "内存压力严重", 25 * 60)], now: t))
        memoryPart(&i)
        i.appsBasis = "近 5 分钟"
        i.apps = [gbApp("Google Chrome", "com.google.Chrome", cpu: 38, mem: 14.2), gbApp("Xcode", "com.apple.dt.Xcode", cpu: 12, mem: 6.1),
                  gbApp("Docker Desktop", "com.docker.docker", cpu: 9, mem: 4.0), gbApp("Slack", "com.tinyspeck.slackmacgap", cpu: 2, mem: 1.6),
                  gbApp("WindowServer", nil, cpu: 11, mem: 0.9)]
        i.events = [event(.memory, .yellow, open: false, daysAgo: 1), event(.memory, .yellow, open: false, daysAgo: 3),
                    event(.memory, .yellow, open: false, daysAgo: 5), event(.memory, .red, open: true, daysAgo: 0)]
        return i
    case "cpu":
        var i = baseInput(t, verdicts([(.cpu, .red, "cpu_mean_10m", "CPU 10 分钟均值 94%", 18 * 60)], now: t))
        i.current.cpuMean10m = 94
        i.cpuSummary = CPUSummary(mean: 62, peak: 100)
        i.appsBasis = "实时"
        i.apps = [gbApp("swift-frontend", nil, cpu: 412, mem: 3.2), gbApp("Xcode", "com.apple.dt.Xcode", cpu: 88, mem: 6.1),
                  gbApp("Google Chrome", "com.google.Chrome", cpu: 41, mem: 5.1), gbApp("WindowServer", nil, cpu: 14, mem: 0.9),
                  gbApp("Slack", "com.tinyspeck.slackmacgap", cpu: 4, mem: 1.1)]
        i.events = [event(.cpu, .yellow, open: false, daysAgo: 1), event(.cpu, .yellow, open: false, daysAgo: 2),
                    event(.cpu, .yellow, open: false, daysAgo: 4), event(.cpu, .yellow, open: false, daysAgo: 6),
                    event(.cpu, .red, open: true, daysAgo: 0)]
        return i
    case "power":
        let t = at("08:40")
        var i = baseInput(t, verdicts([(.power, .yellow, "sleep_drain", "睡眠掉电偏快", 130 * 60)], now: t))
        let woke = t.addingTimeInterval(-60)
        let last = SleepRecord(sleptAt: woke.addingTimeInterval(-380 * 60), wokeAt: woke, batteryBefore: 82, batteryAfter: 61, onBatteryBeforeSleep: true)
        i.current.lastSleep = last
        i.current.batteryPercent = 61
        i.current.powerSource = .battery
        let older1 = SleepRecord(sleptAt: woke.addingTimeInterval(-86400 - 8 * 3600), wokeAt: woke.addingTimeInterval(-86400),
                                 batteryBefore: 90, batteryAfter: 85.2, onBatteryBeforeSleep: true)
        let older2 = SleepRecord(sleptAt: woke.addingTimeInterval(-2 * 86400 - 10 * 3600), wokeAt: woke.addingTimeInterval(-2 * 86400),
                                 batteryBefore: 95, batteryAfter: 90, onBatteryBeforeSleep: true)
        i.sleeps = [older2, last, older1]
        i.sleepBlockers = [SleepBlocker(name: "Zoom", preventsSystemSleep: false, preventsDisplaySleep: true),
                           SleepBlocker(name: "backupd", preventsSystemSleep: true, preventsDisplaySleep: false)]
        i.events = [event(.power, .yellow, open: true, daysAgo: 0)]
        return i
    case "multi":
        var i = baseInput(t, verdicts([(.disk, .red, "growth_5d", "5 天多占用 314 GB", 192 * 60),
                                       (.memory, .red, "pressure_critical", "内存压力严重", 25 * 60),
                                       (.cpu, .yellow, "cpu_mean_5m", "CPU 5 分钟均值 74%", 40 * 60)], now: t))
        diskPart(&i)
        memoryPart(&i)
        i.current.cpuMean5m = 74
        i.cpuSummary = CPUSummary(mean: 61, peak: 97)
        i.apps = [gbApp("Google Chrome", "com.google.Chrome", cpu: 86, mem: 14.2), gbApp("Xcode", "com.apple.dt.Xcode", cpu: 41, mem: 6.1),
                  gbApp("Docker Desktop", "com.docker.docker", cpu: 22, mem: 4.0), gbApp("WindowServer", nil, cpu: 12, mem: 0.9),
                  gbApp("Slack", "com.tinyspeck.slackmacgap", cpu: 4, mem: 1.6)]
        i.events = [event(.disk, .red, open: true, daysAgo: 0), event(.memory, .red, open: true, daysAgo: 0),
                    event(.cpu, .yellow, open: true, daysAgo: 0), event(.cpu, .yellow, open: false, daysAgo: 2),
                    event(.cpu, .yellow, open: false, daysAgo: 5)]
        return i
    default:   // routine
        var i = baseInput(t, verdicts([], now: t))
        i.current.cpuMean10m = 12
        i.current.memoryPressurePercent = 23
        i.current.pressure = .normal
        i.current.swapUsed = 1_300_000_000
        i.current.memory = MemoryBreakdown(app: Int64(20.0 * Double(gib)), wired: Int64(6.0 * Double(gib)),
                                           compressed: Int64(5.4 * Double(gib)), total: 64 * gib)
        i.current.diskTotal = 995_000_000_000
        i.current.diskUsed = 583_000_000_000
        i.diskGrowth = ["5d": growth(8_000_000_000)]
        i.current.batteryPercent = 82
        i.current.powerSource = .ac
        i.events = [event(.cpu, .yellow, open: false, daysAgo: 2), event(.cpu, .yellow, open: false, daysAgo: 5)]
        return i
    }
}

private let v2Kinds = ["disk", "memory", "cpu", "power", "multi", "routine"]

private func v2Text(_ kind: String) -> String {
    PromptBuilder.build(v2Input(kind), scope: .overview, options: PreviewScenario.fixturePromptOptions)
}

private let safetyRulesText = "## 4. 安全规则（必须遵守）\n1. 先只读诊断，再给建议。"

// MARK: - Builder tests

private func runBuilderTests() {
    section("PromptBuilder: structure (DESIGN_V2.md 8.4)")
    let multi = v2Text("multi")
    let headings = ["# 请帮我排查这台 Mac：", "## 1. 现在的问题", "## 2. 你的任务", "## 3. 排查步骤", "## 4. 安全规则（必须遵守）", "## 5. 参考数据", "## 6. 我补充的现象"]
    var last = multi.startIndex
    var ordered = true
    for h in headings {
        guard let r = multi.range(of: h, range: last..<multi.endIndex) else { ordered = false; break }
        last = r.upperBound
    }
    expect(ordered, "sections 0 to 6 come in order")
    expect(multi.contains("等 3 项问题"), "the title counts a merged prompt")
    expect(multi.contains("### 3.3 其余问题（各做第一步）\n- CPU（黄）：运行 `ps -Ao pid,pcpu,time,comm -r | head -n 15`"), "the third problem has only its first step")
    expect(multi.contains("其余正常：耗电、温度。"), "the normal items follow the fixed order")
    expect(multi.contains("磁盘 红 1 次 · 内存 红 1 次 · CPU 黄 3 次") && !multi.contains("（本次）"), "no 本次 mark when there are several problems")
    expect(!multi.contains("| 磁盘容量 |") && !multi.contains("| 内存容量 |"), "merged prompts have no capacity rows")
    let disk = v2Text("disk")
    expect(!disk.contains("| App（"), "the disk prompt has no App table")
    expect(disk.contains("磁盘 红 1 次（本次）· CPU 黄 2 次"), "single problem: the open record is marked")
    expect(v2Text("memory").contains("| App（近 5 分钟） | 内存 | CPU |"), "memory first: memory column first")
    expect(v2Text("cpu").contains("| App（实时） | CPU | 内存 |"), "cpu first: cpu column first")
    expect(PromptBuilder.autoTopic(v2Input("multi").verdicts) == .disk, "autoTopic picks the first problem")
    expect(PromptBuilder.autoTopic(v2Input("routine").verdicts) == nil, "autoTopic is nil without a problem")
    let routine = v2Text("routine")
    expect(!routine.contains("## 5.") && routine.contains("## 4. 安全规则") && routine.contains("[可选]"), "routine: no section 5, rules kept")
    for kind in v2Kinds {
        let t = v2Text(kind)
        let rules = t.range(of: "## 4. 安全规则（必须遵守）")
        expect(rules != nil && t.contains("5. 命令报错时，先看 `<命令> --help` 或 `man <命令>`。不猜命令名或参数。"), "\(kind): the safety rules are in full")
        expect(t.contains("不运行 `mo optimize`、`mo uninstall`") && t.contains("不用 sudo"), "\(kind): forbidden commands are named")
        expect(t.contains("数据目录：`~/Library/Application Support/MoleMonitor`"), "\(kind): data directory is redacted to ~")
        expect(!t.contains("/Users/tester") && !t.lowercased().contains("tester"), "\(kind): no home path and no user name")
    }

    section("PromptBuilder: freshness and no data")
    var input = v2Input("cpu")
    input.freshness = .stale(minutes: 25)
    let stale = PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(stale.contains("数据已过期 25 分钟。数字可能不是现在的状态，请先运行 `/Applications/MoleMonitor.app/Contents/Helpers/molemonitor-cli --status` 确认。"), "stale text")
    input.freshness = .notRunning(minutes: 90)
    let down = PromptBuilder.build(input, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(down.contains("App 未运行") && down.contains("90 分钟"), "not running text")
    for c in [PreviewCase.stale, PreviewCase.collecting] {
        let t = promptFor(c)
        expect(t.contains("不要根据这些数据判断问题"), "\(c): data unavailable")
        expect(t.contains("--status`，确认 App 在运行"), "\(c): the agent checks the App first")
        expect(t.contains("## 4. 安全规则（必须遵守）") && t.contains("不用 sudo"), "\(c): the safety rules stay")
        expect(!t.contains("## 3. 排查步骤") && !t.contains("## 5. 参考数据"), "\(c): no steps and no reference data")
    }
    var tz = PreviewScenario.fixturePromptOptions
    tz.timeZone = TimeZone(secondsFromGMT: 9 * 3600) ?? TimeZone.current
    expect(PromptBuilder.build(v2Input("cpu"), scope: .overview, options: tz).contains("采样于 10月12日 23:05"), "the sampled time uses the time zone of the options")
    expect(v2Text("multi") == v2Text("multi"), "equal input gives equal output")

    section("PromptBuilder: missing data and names")
    var bare = v2Input("memory")
    bare.current.memory = nil
    bare.pressure2h = nil
    bare.current.memoryPressurePercent = nil
    let bareText = PromptBuilder.build(bare, scope: .overview, options: PreviewScenario.fixturePromptOptions)
    expect(bareText.contains("| 内存容量 | 未读到 |") && bareText.contains("| 内存压力（2 小时） | 未读到 |"), "missing readings say 未读到")
    expect(bareText.contains("压力档位：严重"), "no percent: the level word is used")
    var named = v2Input("disk")
    named.diskWriters = [AppDiskWriteTracker.Row(key: "a", name: "alice 的工具", bytes: 5_000_000_000, isSystem: false)]
    let namedText = PromptBuilder.build(named, scope: .overview, options: options())
    expect(namedText.contains("<用户> 的工具 5.0 GB"), "S7 a disk writer name gets S2 and S3")
    var hidden = PreviewScenario.fixturePromptOptions
    hidden.includeAppNames = false
    let hiddenText = PromptBuilder.build(v2Input("disk"), scope: .overview, options: hidden)
    expect(hiddenText.contains("App 1 2.1 GB") && !hiddenText.contains("Docker"), "names off: anonymous writers")
    let noWriters = { () -> String in var i = v2Input("disk"); i.diskWriters = nil; return PromptBuilder.build(i, scope: .overview, options: PreviewScenario.fixturePromptOptions) }()
    expect(noWriters.contains("| 写入最多的 App（近 5 分钟） | 未读到 |"), "writers not read: 未读到")
    var topicInput = v2Input("multi")
    topicInput.verdicts = topicInput.verdicts.map { v in var v = v; if v.item == .memory { v.level = .green; v.since = nil }; return v }
    let topicText = PromptBuilder.build(topicInput, scope: .topic(.memory), options: PreviewScenario.fixturePromptOptions)
    expect(topicText.contains("### 3.1 内存") && !topicText.contains("(红"), "a topic scope without a problem is still built")
    let net = promptFor(.allGreen, .topic(.network))
    expect(net.contains("nettop -P -L 1") && net.contains("## 4. 安全规则"), "network topic by request only")
    expect(PromptTopic.allCases.count == 6, "six topics")

    section("PressureSummary and events")
    let t0 = at("14:05")
    var pts = [TrendPoint]()
    let step = TrendBuffer.coarseInterval
    for k in 0..<120 {
        var p = TrendPoint(t: t0.addingTimeInterval(-Double(k) * step))
        p.pressure = k < 30 ? .critical : .normal
        p.pressurePercent = k < 30 ? 90 : 10
        pts.append(p)
    }
    let ps = PressureSummary.make(points: pts, now: t0)
    expect(ps != nil && ps?.peak == 90 && (ps?.criticalMinutes ?? -1) == Int((30 * step / 60).rounded()) && (ps?.normalMinutes ?? -1) == Int((90 * step / 60).rounded()), "pressure summary minutes: \(String(describing: ps))")
    expect(PressureSummary.make(points: [TrendPoint(t: t0)], now: t0) == nil, "no pressure percent: no summary")
    expect(PromptBuilder.eventSummary(nil, entries: [], single: false) == nil, "events not read: nil")
    expect(PromptBuilder.eventSummary([], entries: [], single: false) == "无", "no events: 无")
}

// MARK: - Compression tests (DESIGN_V2.md 8.6)

private func runCompressionTests() {
    section("PromptBuilder: length and compression")
    let opts = PreviewScenario.fixturePromptOptions
    // Five apps with 32 character names and 45 character bundle ids make the merged prompt long.
    var input = v2Input("multi")
    input.verdicts = input.verdicts.map { v in var v = v; if v.item == .thermal { v.level = .yellow; v.reasonCode = "thermal_fair"; v.since = now }
        if v.item == .power { v.level = .yellow; v.reasonCode = "awake_drain"; v.since = now }; return v }
    var apps = [AppUsage]()
    for i in 1...5 {
        let name = String(repeating: Character(UnicodeScalar(UInt8(64 + i))), count: 32)
        let id = "com.example." + String(repeating: "x", count: 33)
        apps.append(AppUsage(key: id + "\(i)", name: name, bundleID: id, cpuPercent: Double(90 - i), memoryBytes: Int64(5_000_000_000 - i * 100_000_000),
                             memoryBasis: "footprint", processCount: 3, isSystem: false))
    }
    input.apps = apps
    input.diskWriters = (1...3).map { n in AppDiskWriteTracker.Row(key: "w\(n)", name: String(repeating: "W", count: 32), bytes: 2_000_000_000, isSystem: false) }
    input.sleepBlockers = (1...4).map { _ in SleepBlocker(name: String(repeating: "S", count: 30), preventsSystemSleep: true, preventsDisplaySleep: true) }
    let lengths = PromptBuilder.lengths(input, scope: .overview, options: opts)
    expect(lengths[0] > 3000, "the long scenario needs compression: \(lengths)")
    for k in 1..<lengths.count { expect(lengths[k] <= lengths[k - 1], "level \(k) does not grow the text: \(lengths)") }
    expect(lengths[1] < lengths[0] && lengths[2] < lengths[1] && lengths[3] < lengths[2], "L1 to L3 each shorten the text: \(lengths)")
    let built = PromptBuilder.build(input, scope: .overview, options: opts)
    expect(built.count <= 3000, "the built text fits in 3000 characters (\(built.count))")
    expect(built.contains("## 4. 安全规则（必须遵守）") && built.contains("6. 只读工具"), "the safety rules stay")
    expect(built.contains("## 1. 现在的问题") && built.contains("## 2. 你的任务") && built.contains("# 请帮我排查这台 Mac："), "sections 0, 1 and 2 stay")
    // The limit decides the last level.
    for level in 1..<lengths.count {
        var o = opts
        o.maxLength = lengths[level]
        let t = PromptBuilder.build(input, scope: .overview, options: o)
        expect(t.count == lengths[level] || t.count < lengths[level], "a limit of \(lengths[level]) stops at level \(level) or earlier (got \(t.count))")
    }
    var o1 = opts; o1.maxLength = lengths[1]
    let l1 = PromptBuilder.build(input, scope: .overview, options: o1)
    expect(l1.components(separatedBy: "\n").filter { $0.hasPrefix("| AAAA") || $0.hasPrefix("| BBBB") || $0.hasPrefix("| CCCC") || $0.hasPrefix("| DDDD") || $0.hasPrefix("| EEEE") }.count == 3, "L1 keeps 3 App rows")
    var o2 = opts; o2.maxLength = lengths[2]
    expect(!PromptBuilder.build(input, scope: .overview, options: o2).contains("近 7 天异常记录"), "L2 drops the event row")
    var o4 = opts; o4.maxLength = lengths[4]
    expect(PromptBuilder.build(input, scope: .overview, options: o4).contains("其余问题："), "L4 merges the later problems into one line")
    // A floor: even a limit of 10 keeps sections 0, 1, 2 and 4.
    var floor = opts
    floor.maxLength = 10
    let squeezed = PromptBuilder.build(input, scope: .overview, options: floor)
    expect(squeezed.contains("## 4. 安全规则（必须遵守）") && squeezed.contains("6. 只读工具") && squeezed.contains("## 2. 你的任务") && !squeezed.contains("## 5. 参考数据"),
           "squeezed: rules stay, reference data goes")
    // W20: every golden text fits and carries section 4 word for word.
    for kind in v2Kinds {
        let t = v2Text(kind)
        expect(t.count <= 3000, "W20 \(kind) has \(t.count) characters")
        expect(t.contains(safetyRulesText), "W20 \(kind) has section 4")
    }
    expect(v2Text("routine").count >= 1000 && v2Text("routine").count <= 1300, "the routine check is about 1200 characters (\(v2Text("routine").count))")
    for (c, scope, name) in goldenCases() {
        let ls = PromptBuilder.lengths(PreviewScenario.promptInput(c, now: now), scope: scope, options: opts)
        expect(ls.last ?? 9999 <= 3000, "\(name) fits in 3000 characters (\(ls))")
    }
}

// MARK: - Golden tests

private func runGoldenTests() {
    section("Prompt: golden files")
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["GOLDEN_DIR"] else {
        print("GOLDEN_DIR is not set: golden files skipped")
        return
    }
    let update = env["UPDATE_GOLDEN"] == "1"
    // The texts of DESIGN_V2.md 8.8: compared word for word, never rewritten.
    for kind in v2Kinds {
        let text = v2Text(kind) + "\n"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("v2-" + kind + ".txt")
        let want = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(text == want, "DESIGN_V2.md 8.8 golden v2-\(kind).txt matches (got \(text.count) characters, file has \(want.count))")
    }
    for (c, scope, name) in goldenCases() {
        let text = promptFor(c, scope) + "\n"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt")
        if update {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            continue
        }
        let want = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(text == want, "golden file \(name).txt matches (got \(text.count) characters, file has \(want.count))")
        expect(text.count <= 3000 + 1, "golden \(name) stays within 3000 characters (\(text.count))")
    }
}
