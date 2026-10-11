// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: StatusFile, alerts and the notification authorization string from MonitorEngine.
// Output: SwiftUI status card (320 pt wide): summary, disk, traffic, alerts, authorization row, CLI hint, quit.
// Pos: Stage 1 status card (docs/PROJECT.md 4.2); no timers inside, missing values show as a dash or "统计中".

import AppKit
import SwiftUI

/// Binds the engine to the pure `Panel`. Created on each popover open and released on close.
struct PanelContainer: View {
    @ObservedObject var engine: MonitorEngine
    var onQuit: () -> Void

    var body: some View {
        Panel(status: engine.status,
              alerts: engine.alerts,
              authorization: engine.authorization,
              onEnableNotifications: { engine.requestNotificationAuthorization() },
              onQuit: onQuit)
    }
}

/// Pure view: all inputs are values, so the preview renderer needs no engine.
struct Panel: View {
    var status: StatusFile?
    var alerts: [AlertItem]
    var authorization: String
    var onEnableNotifications: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            diskCard
            trafficBlock
            Divider()
            alertsBlock
            authorizationBlock
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("MoleMonitor").font(.headline)
                Spacer()
                Text(PanelFormat.dataTime(status)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle().fill(PanelFormat.color(status?.overall.level ?? .unknown)).frame(width: 8, height: 8)
                Text(status?.overall.summary ?? "正在统计")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Disk

    private var diskCard: some View {
        let disk = status?.items.disk
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("磁盘").font(.subheadline.weight(.semibold))
                Spacer()
                Text(PanelFormat.levelText(disk?.level ?? .unknown))
                    .font(.caption)
                    .foregroundStyle(PanelFormat.color(disk?.level ?? .unknown))
            }
            Text("\(PanelFormat.bytes(disk?.used)) / \(PanelFormat.bytes(disk?.total))")
                .font(.system(.title3, design: .rounded))
                .monospacedDigit()
            usageBar(used: disk?.used.value, total: disk?.total.value, level: disk?.level ?? .unknown)
            detailRow("重要用途可用", PanelFormat.bytes(disk?.availableImportant))
            ForEach(PanelFormat.windows) { window in
                growthRow(label: window.label, growth: disk?.growth[window.key])
            }
            if let purgeable = disk?.purgeableEstimate.value, purgeable > 0 {
                Text("另有约 \(ByteText.gb(purgeable)) 可清除空间（快照、缓存），系统需要时会自动释放")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func usageBar(used: Int64?, total: Int64?, level: HealthLevel) -> some View {
        let known = (used != nil && total != nil)
        let fraction: Double
        if let used, let total, total > 0 {
            fraction = min(1, max(0, Double(used) / Double(total)))
        } else {
            fraction = 0
        }
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if known {
                    Capsule()
                        .fill(PanelFormat.color(level))
                        .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                }
            }
        }
        .frame(height: 6)
    }

    private func growthRow(label: String, growth: DiskGrowth?) -> some View {
        let shown = PanelFormat.growth(growth)
        return HStack {
            Text("\(label)增长").foregroundStyle(.secondary)
            Spacer()
            if let note = shown.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Text(shown.text).monospacedDigit()
        }
        .font(.caption)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    // MARK: Traffic

    private var trafficBlock: some View {
        let traffic = status?.items.network.traffic
        return VStack(alignment: .leading, spacing: 3) {
            Text("流量").font(.caption.weight(.semibold))
            trafficRow("今天", traffic?["today"])
            trafficRow("近 5 天", traffic?["5d"])
        }
    }

    private func trafficRow(_ label: String, _ totals: TrafficTotals?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(PanelFormat.traffic(totals)).monospacedDigit()
        }
        .font(.caption)
    }

    // MARK: Alerts

    private var alertsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("提醒").font(.subheadline.weight(.semibold))
            if alerts.isEmpty {
                Text("当前没有提醒").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(alerts.indices, id: \.self) { index in
                    alertRow(alerts[index])
                }
            }
        }
    }

    private func alertRow(_ alert: AlertItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(PanelFormat.color(alert.level)).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("自 \(PanelFormat.dateTime(alert.since)) 起")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Notification authorization

    @ViewBuilder
    private var authorizationBlock: some View {
        switch authorization {
        case "not_determined":
            VStack(alignment: .leading, spacing: 6) {
                Text("MoleMonitor 在磁盘异常增长等情况下发送系统通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onEnableNotifications) { Text("开启通知") }
                    .buttonStyle(PillButtonStyle())
            }
        case "denied":
            Text("通知已关闭，可在系统设置 > 通知中打开")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case "unavailable":
            Text("此环境无法发送通知，提醒只显示在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("命令行读取状态").font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: "molemonitor-cli --status --brief")
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
            Button(action: onQuit) { Text("退出") }
                .buttonStyle(PillButtonStyle())
        }
    }
}

/// Pure SwiftUI button look, so the same view also renders in ImageRenderer.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08))
            .clipShape(Capsule())
    }
}

/// Text and color helpers. Missing values give a dash or "统计中", never 0.
private enum PanelFormat {
    struct Window: Identifiable {
        var key: String
        var label: String
        var id: String { key }
    }

    static let windows = [Window(key: "1d", label: "1 天"), Window(key: "5d", label: "5 天"),
                          Window(key: "30d", label: "30 天")]

    // Fixed format and locale, so output does not depend on the user's region settings.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func dateTime(_ d: Date) -> String { dateTimeFormatter.string(from: d) }

    static func dataTime(_ status: StatusFile?) -> String {
        guard let status else { return "尚无数据" }
        let age = Date().timeIntervalSince(status.writtenAt)
        let stamp = "数据 \(timeFormatter.string(from: status.writtenAt))"
        return age > StatusStore.freshSeconds ? stamp + "（已过期）" : stamp
    }

    static func color(_ level: HealthLevel) -> Color {
        switch level {
        case .green: return Color.green
        case .yellow: return Color.orange
        case .red: return Color.red
        default: return Color.gray
        }
    }

    static func levelText(_ level: HealthLevel) -> String {
        switch level {
        case .green: return "正常"
        case .yellow: return "需留意"
        case .red: return "异常"
        case .stale: return "数据过期"
        case .unknown, .notApplicable: return "统计中"
        }
    }

    static func bytes(_ m: Measured<Int64>?) -> String {
        guard let m, m.status == .ok, let v = m.value else { return "—" }
        return ByteText.gb(v)
    }

    /// "已记录 N 小时" under one day, otherwise "已记录 N.N 天".
    static func recorded(hours: Double) -> String {
        if hours < 1 { return "已记录不足 1 小时" }
        if hours < 24 { return "已记录 \(Int(hours)) 小时" }
        return String(format: "已记录 %.1f 天", hours / 24)
    }

    static func growth(_ g: DiskGrowth?) -> (text: String, note: String?) {
        guard let g else { return ("统计中", nil) }
        switch g.status {
        case .ok:
            if let b = g.bytes { return ("+" + ByteText.gb(b), nil) }
            return ("—", nil)
        case .insufficientWindow, .collecting:
            let note: String? = g.coveredHours > 0 ? recorded(hours: g.coveredHours) : nil
            if let b = g.bytes { return ("至少 +" + ByteText.gb(b), note) }
            return ("统计中", note)
        default:
            return ("—", nil)
        }
    }

    static func trafficBytes(_ v: Int64) -> String {
        if v >= 1_000_000_000 { return ByteText.gb(v) }
        if v >= 1_000_000 { return String(format: "%.0f MB", Double(v) / 1e6) }
        return String(format: "%.0f KB", Double(v) / 1e3)
    }

    static func traffic(_ t: TrafficTotals?) -> String {
        guard let t, let rx = t.rx, let tx = t.tx else { return "统计中" }
        let prefix = (t.status == .ok) ? "" : "至少 "
        return "\(prefix)下行 \(trafficBytes(rx)) · 上行 \(trafficBytes(tx))"
    }
}

/// Hand-built data for `--preview`. It does not touch the engine or the data directory.
/// Main actor: it builds a SwiftUI view, and its only caller (PreviewRenderer) is on the main actor.
@MainActor
enum PanelSample {
    static func status(now: Date = Date()) -> StatusFile {
        let gb: Int64 = 1_000_000_000
        let total = 995 * gb
        let availImportant = 412 * gb
        func growth(_ key: String, _ bytes: Int64, _ net: Int64, hours: Double) -> DiskGrowth {
            DiskGrowth(window: key, bytes: bytes, netBytes: net,
                       fromMinAt: now.addingTimeInterval(-hours * 3600), coveredHours: hours, status: .ok)
        }
        let disk = DiskItem(
            level: .red, reasonCode: "growth_5d", reason: "5 天内真实已用增长 291 GiB",
            since: now.addingTimeInterval(-3 * 3600), levelChangedAt: now.addingTimeInterval(-3 * 3600),
            volume: "/System/Volumes/Data",
            total: .ok(total, unit: "bytes", at: now),
            used: .ok(total - availImportant, unit: "bytes", at: now),
            availableImportant: .ok(availImportant, unit: "bytes", at: now),
            availableNow: .ok(398 * gb, unit: "bytes", at: now),
            purgeableEstimate: .ok(14 * gb, unit: "bytes", at: now),
            growth: [
                "1d": growth("1d", 24 * gb, 20 * gb, hours: 24),
                "5d": growth("5d", 312 * gb, 250 * gb, hours: 119),
                "30d": DiskGrowth(window: "30d", bytes: 330 * gb, netBytes: 280 * gb,
                                  fromMinAt: now.addingTimeInterval(-9 * 86400), coveredHours: 9 * 24,
                                  status: .insufficientWindow),
            ],
            historyDays: 9, lastSampleAt: now)
        let network = NetworkItem(traffic: [
            "today": TrafficTotals(rx: 3_200_000_000, tx: 410_000_000, coveredHours: 9, status: .ok),
            "5d": TrafficTotals(rx: 41_000_000_000, tx: 5_600_000_000, coveredHours: 119, status: .ok),
        ], note: NetworkItem.defaultNote)
        let alert = AlertItem(
            type: "disk_growth", subject: "/System/Volumes/Data", level: .red,
            since: now.addingTimeInterval(-3 * 3600),
            message: "磁盘 5 天多占用了 312 GB。已排除可清除空间（快照、缓存）。",
            agentHint: "")
        return StatusFile(appVersion: AppInfo.version, writtenAt: now, writerPid: 0,
                          overall: .init(level: .red, summary: "磁盘 5 天多占用了 312 GB"),
                          items: .init(disk: disk, network: network),
                          activeAlerts: [alert],
                          notifications: .init(authorization: "not_determined"))
    }

    static func panel(now: Date = Date()) -> Panel {
        let s = status(now: now)
        return Panel(status: s, alerts: s.activeAlerts, authorization: s.notifications.authorization,
                     onEnableNotifications: {}, onQuit: {})
    }
}
