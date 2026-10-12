// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Command-line arguments; MOLEMONITOR_DATA_DIR; status.json and disk NDJSON files in the data directory.
// Output: JSON or one Chinese line on stdout; usage on stderr; exit code 0/2/3/4 (docs/PROJECT.md 8.4). `--events` prints the anomaly records.
// Pos: molemonitor-cli, the read-only command-line client. Foundation and Sources/Core only; no AppKit, no threads, no writes.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let usageText = """
用法：molemonitor-cli <命令>
  --status                 输出完整状态 JSON
  --status --brief         输出一行中文摘要
  --disk-history [--days N]  输出每天的磁盘真实已用与增长量 JSON（默认 30 天，最大 60 天）
  --events [--days N]      输出最近的异常记录 JSON（默认 7 天，最大 30 天，最新在前）
  prompt [--topic T]       输出给 agent 的排查提示词（T 为 disk、memory、cpu、thermal、power、network）
  prompt --apps|--no-apps  强制包含或隐藏 App 名称（默认按 App 中的设置）
  --schema                 输出字段说明与口径说明 JSON
  --version                输出版本
  --help                   输出本说明
退出码：0 数据新鲜，2 参数错误，3 数据过期或 App 未运行（仍输出最后的数据），4 尚无任何记录。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n" + usageText + "\n").utf8))
    exit(2)
}

func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func prettyEncoder() -> JSONEncoder {
    let e = CoreJSON.encoder()
    e.outputFormatting.insert(.prettyPrinted)
    return e
}

func localMidnight(_ now: Date) -> Date {
    var t = time_t(now.timeIntervalSince1970)
    var parts = tm()
    localtime_r(&t, &parts)
    return now.addingTimeInterval(-Double(Int(parts.tm_hour) * 3600 + Int(parts.tm_min) * 60 + Int(parts.tm_sec)))
}

let schemaDocument: [String: Any] = [
    "schema_version": 1,
    "description": "molemonitor-cli 只读。字段名为 snake_case，时间为 ISO 8601 UTC，字节为十进制整数。",
    "top_level_fields": [
        "read_at": "CLI 读取数据的时间",
        "age_seconds": "read_at 减 written_at，单位秒",
        "app_running": "写入 status.json 的进程是否仍在运行",
        "fresh": "App 在运行且 age_seconds 不超过 420 为 true",
        "recomputed": "true 表示磁盘与网络流量由 CLI 从 NDJSON 历史重新计算，其他内容来自旧的 status.json",
        "overall": "整体等级与一句话原因",
        "items": "disk 与 network，以及 memory、cpu、thermal、power（App 0.3 起写入；旧文件没有这四项）",
        "top_apps": "占用前几名的 App：CPU 前 8 与内存前 8 的并集，最多 16 项。含 sampled_at、basis、coverage",
        "env": "机型、芯片、内存大小、系统版本",
        "prompt_prefs": "include_app_names：提示词是否包含 App 名称",
        "active_alerts": "当前提醒，每项含 type、subject、level、since、message、agent_hint；不输出已恢复的提醒",
        "notifications": "通知授权状态",
    ] as [String: Any],
    "events": "--events 输出异常记录数组，最新在前。键：v、item、first、peak、reason、start、end（null 表示仍在持续）、peakValue、unit、app、endEstimated。",
    "measured_fields": "{value, unit, status, sampled_at}。只有 status 为 ok 时 value 才有意义，其他情况 value 为 null。测得的 0 与取不到的值不同。",
    "status_values": [
        "ok": "测得的值，可以是 0",
        "collecting": "尚无第一个样本",
        "insufficient_window": "有样本，但窗口覆盖不足",
        "missing": "设备没有该传感器",
        "failed": "读取出错",
        "stale": "样本比允许时间旧",
        "not_applicable": "不适用",
    ] as [String: Any],
    "exit_codes": ["0": "数据新鲜", "2": "参数错误", "3": "数据过期或 App 未运行，仍输出最后的数据", "4": "没有状态文件也没有磁盘记录"] as [String: Any],
    "definitions": [
        "real_used": "总容量减 available_important（含可清除空间的可用量）。快照与缓存等可清除空间不算已用。",
        "growth": "窗口内当前真实已用减去窗口内最低真实已用。窗口为 1d、5d、30d。",
        "net_change": "窗口内当前真实已用减去窗口内最早一个样本的真实已用，可为负数。例：200 GB、150 GB、450 GB 的增长量是 300 GB，净变化是 250 GB。",
        "growth_lower_bound": "窗口覆盖不足但有 2 个以上样本时，bytes 仍给出，是下限，status 为 insufficient_window。",
        "network_interfaces": "物理网卡合计（Wi-Fi、有线、蜂窝）。排除 lo、utun、awdl、llw、bridge、ap，不重复计入 VPN 隧道。共享或桥接场景可能重复计数。",
        "traffic": "相邻两个样本的累计字节差之和。开机时间变化或计数变小时，跳过该对样本。today 从本地零点起算。",
        "disk_records": "每 15 分钟一行；失败的读取不当作 0。CLI 最多读取最近 35 天。",
    ] as [String: Any],
    "not_recorded": "完整进程参数、序列号、用户名、家目录路径、凭据。volume 字段只是卷挂载点。",
]

func schemaText() -> String {
    let data = (try? JSONSerialization.data(withJSONObject: schemaDocument,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Argument parsing

enum Command { case status, diskHistory, events, schema, version, help, prompt }

var command: Command?
var brief = false
var days = 30
var daysGiven = false
var topic: PromptTopic?
var appsOverride: Bool?
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
func setCommand(_ c: Command, _ arg: String) {
    if command != nil && command != c { fail("参数冲突：\(arg) 不能与其他命令同时使用") }
    command = c
}
while i < args.count {
    let a = args[i]
    switch a {
    case "prompt", "--prompt":
        if a == "prompt" && i != 0 { fail("未知参数：\(a)") }
        setCommand(.prompt, a)
    case "--topic":
        i += 1
        guard i < args.count, let t = PromptTopic(rawValue: args[i]) else {
            fail("--topic 需要 disk、memory、cpu、thermal、power 或 network")
        }
        topic = t
    case "--apps", "--no-apps":
        let wanted = a == "--apps"
        if let existing = appsOverride, existing != wanted { fail("--apps 与 --no-apps 不能同时使用") }
        appsOverride = wanted
    case "--status": setCommand(.status, a)
    case "--brief": brief = true
    case "--disk-history": setCommand(.diskHistory, a)
    case "--events": setCommand(.events, a)
    case "--days":
        i += 1
        guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("--days 需要 1 到 60 的整数") }
        days = min(n, 60)
        daysGiven = true
    case "--schema": setCommand(.schema, a)
    case "--version": setCommand(.version, a)
    case "--help", "-h": setCommand(.help, a)
    default: fail("未知参数：\(a)")
    }
    i += 1
}
guard let command else { fail("缺少命令") }
if brief && command != .status { fail("--brief 只能与 --status 一起使用") }
if daysGiven && command != .diskHistory && command != .events { fail("--days 只能与 --disk-history 或 --events 一起使用") }
if (topic != nil || appsOverride != nil) && command != .prompt { fail("--topic、--apps、--no-apps 只能与 prompt 一起使用") }

// MARK: - Run

switch command {
case .help:
    emit(usageText)
    exit(0)
case .version:
    emit("molemonitor-cli \(AppInfo.version)")
    exit(0)
case .schema:
    emit(schemaText())
    exit(0)
case .status:
    let dir = MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)
    let now = Date()
    guard let result = StatusReportBuilder.build(dir: dir, now: now, todayStart: localMidnight(now),
                                                 pidAlive: StatusStore.processAlive) else {
        emit(brief ? StatusReportBuilder.neverRunText : StatusReportBuilder.neverRunJSON)
        exit(4)
    }
    if brief {
        emit(Brief.line(result.report.status, freshness: result.report.freshness))
    } else if let data = try? prettyEncoder().encode(result.report) {
        emit(String(decoding: data, as: UTF8.self))
    } else {
        FileHandle.standardError.write(Data("无法编码状态\n".utf8))
        exit(1)
    }
    exit(result.exitCode)
case .prompt:
    let dir = MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)
    let now = Date()
    guard let result = StatusReportBuilder.build(dir: dir, now: now, todayStart: localMidnight(now),
                                                 pidAlive: StatusStore.processAlive) else {
        emit(StatusReportBuilder.neverRunText)
        exit(4)
    }
    let status = result.report.status
    let cliPath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let input = StatusExtras.promptInput(status: status, freshness: result.report.freshness, cliPath: cliPath,
                                         dataDir: dir.path, timeZone: TimeZone.current)
    let include: Bool = appsOverride ?? status.promptPrefs?.includeAppNames ?? true
    let options = PromptOptions.forCurrentUser(includeAppNames: include)
    let scope: PromptScope = topic.map { PromptScope.topic($0) } ?? PromptScope.overview
    // The CLI cannot read disk writers, sleep blockers or the 2 hour pressure: they stay nil ("未读到").
    var promptInput = input
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent(EventLog.fileName).path) {
        promptInput.events = EventLog.read(dir: dir, days: 7, now: now)
    }
    var text = PromptBuilder.build(promptInput, scope: scope, options: options)
    while text.hasSuffix("\n") { text.removeLast() }
    emit(text)
    exit(result.exitCode)
case .events:
    let dir = MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)
    let records = EventLog.read(dir: dir, days: daysGiven ? min(days, EventLog.maxDays) : 7, now: Date())
    let objects = records.map { EventLog.object($0) }
    let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
    emit(String(decoding: data, as: UTF8.self))
    exit(0)
case .diskHistory:
    let dir = MoleMonitorPaths.dataDir(environment: ProcessInfo.processInfo.environment)
    let now = Date()
    let samples = DiskHistory.load(dir: dir, now: now, days: days + 1).samples
    if samples.isEmpty {
        emit("[]")
        exit(4)
    }
    let rows = DiskReport.daily(samples: samples, days: days, now: now)
    emit(String(decoding: (try? prettyEncoder().encode(rows)) ?? Data("[]".utf8), as: UTF8.self))
    exit(0)
}
