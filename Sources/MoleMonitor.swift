// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Mole NDJSON and read-only macOS sensors.
// Output: Native menu-bar monitor or headless diagnostics.
// Pos: UI and process lifecycle; no cleanup or privileged commands.
import AppKit
import SwiftUI
import Foundation

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    var cpu: Double
    var memory: Double
    var count: Int
}

struct Snapshot {
    var receivedAt = Date()
    var cpu: Double?
    var memory: Double?
    var usedMemory: Double?
    var totalMemory: Double?
    var download: Double?
    var upload: Double?
    var freeDisk: Double?
    var sensors: SupplementalSample?
    var applications: [AppUsage] = []
    var applicationsAt: Date?

    static func decode(_ data: Data) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MoleMonitor", code: 1)
        }
        var s = Snapshot()
        guard let timestamp = root["collected_at"] as? String else {
            throw NSError(domain: "MoleMonitor", code: 2)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var sampledAt = formatter.date(from: timestamp)
        if sampledAt == nil {
            formatter.formatOptions = [.withInternetDateTime]
            sampledAt = formatter.date(from: timestamp)
        }
        guard let sampledAt else { throw NSError(domain: "MoleMonitor", code: 3) }
        s.receivedAt = sampledAt
        func value(_ object: [String: Any]?, _ key: String) -> Double? {
            guard let n = object?[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        let cpu = root["cpu"] as? [String: Any]
        let mem = root["memory"] as? [String: Any]
        let cpuCount = value(cpu, "logical_cpu") ?? value(cpu, "core_count") ?? 0
        if cpuCount > 0, let n = value(cpu, "usage"), (0...100).contains(n) { s.cpu = n }
        if let n = value(mem, "total"), n > 0 {
            s.totalMemory = n; s.usedMemory = value(mem, "used")
            s.memory = value(mem, "used_percent").flatMap { (0...100).contains($0) ? $0 : nil }
        }
        // Mole selects the default route/tunnel. Summing interfaces would double-count VPN.
        let history = root["network_history"] as? [String: Any]
        let interfaces = root["network"] as? [[String: Any]] ?? []
        if !interfaces.isEmpty, let rx = history?["rx_history"] as? [Double], rx.count > 1 {
            s.download = rx.last.flatMap { $0 >= 0 ? $0 : nil }
        }
        if !interfaces.isEmpty, let tx = history?["tx_history"] as? [Double], tx.count > 1 {
            s.upload = tx.last.flatMap { $0 >= 0 ? $0 : nil }
        }
        let disks = root["disks"] as? [[String: Any]] ?? []
        let disk = disks.first { ($0["mount"] as? String) == "/System/Volumes/Data" }
            ?? disks.first { ($0["mount"] as? String) == "/" }
        if let total = value(disk, "total"), total > 0, let used = value(disk, "used"), used >= 0, used <= total {
            s.freeDisk = total - used
        }
        return s
    }
}

enum ProcessSampler {
    static func read() -> [AppUsage] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,pcpu=,rss=,comm="] // executable paths only; never arguments.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"; p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); timeout.cancel()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        var grouped: [String: AppUsage] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let cpu = Double(parts[1]), let rss = Double(parts[2]),
                  cpu.isFinite, rss.isFinite, cpu >= 0, rss >= 0 else { continue }
            let path = String(parts[3])
            let name: String
            if let end = path.range(of: ".app/") {
                name = URL(fileURLWithPath: String(path[..<end.lowerBound])).lastPathComponent
            } else { name = URL(fileURLWithPath: path).lastPathComponent }
            guard !name.isEmpty else { continue }
            var app = grouped[name] ?? AppUsage(name: name, cpu: 0, memory: 0, count: 0)
            app.cpu += cpu; app.memory += rss * 1024; app.count += 1
            grouped[name] = app
        }
        return Array(grouped.values)
    }
}

final class MonitorService {
    let queue = DispatchQueue(label: "MoleMonitor.collect", qos: .utility)
    var onSnapshot: ((Snapshot) -> Void)?
    var onState: ((String) -> Void)?
    private var child: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var buffer = Data()
    private var stopping = false
    private var generation = 0
    private var retries = 0
    private var lastSensors = Date.distantPast
    private var lastApps = Date.distantPast
    private var sensors: SupplementalSample?
    private var apps: [AppUsage] = []
    private var lastValid = Date.distantPast
    private var watchdog: DispatchSourceTimer?
    var backendURL: URL {
        if CommandLine.arguments.contains("--diagnose"),
           let path = ProcessInfo.processInfo.environment["MOLE_MONITOR_TEST_BACKEND"] {
            return URL(fileURLWithPath: path)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("mole-status"),
           FileManager.default.isExecutableFile(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../Vendor/mole-status").standardizedFileURL
    }
    func start() {
        queue.async { [self] in
            self.stopping = false; self.launch()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopping else { return }
                if Date().timeIntervalSince(self.lastValid) > 20 {
                    self.notifyState("数据过期，重新采集")
                    self.terminateBackend()
                }
            }
            self.watchdog = timer; timer.resume()
        }
    }
    func stop() {
        queue.sync {
            stopping = true; generation += 1; watchdog?.cancel(); watchdog = nil
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            if let child, child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            self.child = nil
        }
    }
    func resumeAfterWake() {
        queue.async {
            self.lastValid = .distantPast; self.lastSensors = .distantPast; self.lastApps = .distantPast
            if let p = self.child, p.isRunning { self.terminateBackend() }
            else if !self.stopping { self.launch() }
        }
    }
    private func terminateBackend() {
        guard let p = child, p.isRunning else { return }
        let token = generation
        p.terminate()
        queue.asyncAfter(deadline: .now() + 3) {
            guard token == self.generation, let current = self.child, current === p, p.isRunning else { return }
            Darwin.kill(p.processIdentifier, SIGKILL)
        }
    }
    private func notifyState(_ state: String) { DispatchQueue.main.async { self.onState?(state) } }
    private func launch() {
        guard !stopping, child == nil else { return }
        generation += 1; let token = generation
        buffer.removeAll(keepingCapacity: true); lastValid = Date()
        let p = Process(); let out = Pipe(); let err = Pipe()
        p.executableURL = backendURL
        p.arguments = ["--watch", "--interval", "2s", "--proc-cpu-alerts=false"]
        var env = ProcessInfo.processInfo.environment
        env["MOLE_TEST_NO_AUTH"] = "1"; env["LC_ALL"] = "C"; p.environment = env
        p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(data, token: token) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, token == self.generation else { return }
                self.child = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self.scheduleRestart()
            }
        }
        child = p; stdoutPipe = out; stderrPipe = err
        do { try p.run(); notifyState("正在采集") }
        catch {
            child = nil
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            notifyState("采集程序不可用"); scheduleRestart()
        }
    }
    private func scheduleRestart() {
        guard !stopping else { return }
        retries = min(retries + 1, 5)
        let delay = min(pow(2.0, Double(retries)), 30)
        notifyState("采集中断，\(Int(delay)) 秒后重试")
        queue.asyncAfter(deadline: .now() + delay) { self.launch() }
    }
    private func consume(_ data: Data, token: Int) {
        guard token == generation, !stopping else { return }
        buffer.append(data)
        if buffer.count > 2_000_000 { buffer.removeAll(); notifyState("数据格式异常"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(buffer.startIndex...newline)
            guard var s = try? Snapshot.decode(line), s.cpu != nil || s.totalMemory != nil else { continue }
            let now = Date()
            let age = now.timeIntervalSince(s.receivedAt)
            guard age >= -5, age < 15 else { continue }
            if now.timeIntervalSince(lastSensors) >= 5 {
                sensors = SupplementalSensors.read(); lastSensors = now
            }
            if now.timeIntervalSince(lastApps) >= 8 { apps = ProcessSampler.read(); lastApps = now }
            s.sensors = sensors; s.applications = apps; s.applicationsAt = lastApps
            lastValid = s.receivedAt; retries = 0
            DispatchQueue.main.async { self.onSnapshot?(s) }
        }
    }
}

final class MonitorModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var state = "正在采集"
    @Published var clock = Date()
    var stale: Bool { snapshot.map { clock.timeIntervalSince($0.receivedAt) > 15 } ?? true }
    private var diskAt: Date?
    private var diskFree: Double?
    private var ticker: Timer?
    private var wakeAt = Date.distantPast
    let service = MonitorService()
    var onChange: (() -> Void)?
    init() {
        service.onSnapshot = { [weak self] sample in
            guard let self else { return }
            guard sample.receivedAt >= self.wakeAt else { return }
            var sample = sample
            if let free = sample.freeDisk { self.diskAt = sample.receivedAt; self.diskFree = free }
            else if let at = self.diskAt, Date().timeIntervalSince(at) < 65 { sample.freeDisk = self.diskFree }
            self.snapshot = sample; self.state = "实时"; self.onChange?()
        }
        service.onState = { [weak self] in self?.state = $0; self?.onChange?() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.clock = Date(); self?.onChange?()
        }
    }
    func wake() {
        wakeAt = Date(); clock = wakeAt; snapshot = nil; diskAt = nil; diskFree = nil
        state = "唤醒后重新采集"; onChange?(); service.resumeAfterWake()
    }
    deinit { ticker?.invalidate() }
}

func percent(_ n: Double?) -> String { n.map { String(format: "%.0f%%", $0) } ?? "—" }
func capacity(_ n: Double?) -> String {
    guard let n, n.isFinite, n >= 0, n < Double(Int64.max) else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
}
func speed(_ n: Double?, short: Bool = false) -> String {
    guard let n, n.isFinite, n >= 0 else { return "—" }
    return n >= 1 ? String(format: short ? "%.1fM" : "%.1f MiB/s", n)
        : String(format: short ? "%.0fK" : "%.0f KiB/s", n * 1024)
}

struct MonitorPanel: View {
    @ObservedObject var model: MonitorModel
    @State private var ranking = 0
    var s: Snapshot? { model.stale ? nil : model.snapshot }
    var pressure: String {
        switch s?.sensors?.memoryPressure {
        case "normal": return "正常"
        case "warn", "warning": return "偏高"
        case "critical": return "高"
        default: return "未取得"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mole Monitor").font(.headline)
                    Text(model.stale ? model.state == "实时" ? "数据已过期" : model.state : "只读监控 · 实时更新")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.stale ? Color.orange : Color.green).frame(width: 7, height: 7)
            }
            HStack(spacing: 10) {
                metric("CPU", percent(s?.cpu), "全机平均", "cpu")
                metric("内存", percent(s?.memory), pressure, "memorychip")
            }
            HStack {
                Label(speed(s?.download), systemImage: "arrow.down")
                Spacer()
                Label(speed(s?.upload), systemImage: "arrow.up")
            }.font(.caption).monospacedDigit()
            Divider()
            VStack(spacing: 8) {
                detail("内存用量", "\(capacity(s?.usedMemory)) / \(capacity(s?.totalMemory))")
                detail("内存压力", pressure)
                detail("磁盘剩余", capacity(s?.freeDisk))
                detail("电池电量", percent(s?.sensors?.batteryPercent))
                detail("电池状态", batteryState)
                detail("电池循环", s?.sensors?.batteryCycles.map { "\($0) 次" } ?? "未取得")
                detail("CPU 温度", temperature(s?.sensors?.cpuTemperature))
                detail("电池温度", temperature(s?.sensors?.batteryTemperature))
                detail("风扇转速", fanText)
            }
            if let note = s?.sensors?.sensorNote, !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("应用与进程").font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 3) {
                    choice("CPU", index: 0)
                    choice("内存", index: 1)
                }.padding(3).background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            VStack(spacing: 7) {
                if s?.applications.isEmpty != false {
                    Text("正在读取应用占用").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array((s?.applications ?? []).sorted {
                        ranking == 0 ? $0.cpu > $1.cpu : $0.memory > $1.memory
                    }.prefix(5))) { app in
                        HStack {
                            Text(app.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ranking == 0 ? String(format: "%.1f%%", app.cpu) : capacity(app.memory))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }.frame(minHeight: 94, alignment: .top)
            Text(ranking == 0 ? "按应用归并进程；单核满载为 100%，多核可超过 100%。"
                 : "按应用归并 RSS；共享内存可能重复计入，与活动监视器口径不同。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("Mole V1.59.1 · 本机采集").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("退出").font(.caption).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { NSApplication.shared.terminate(nil) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { NSApplication.shared.terminate(nil) }
            }
        }.padding(18).frame(width: 350)
    }
    private var batteryState: String {
        guard let b = s?.sensors else { return "未取得" }
        if b.charging == true { return "充电中" }
        if b.externalPower == true { return "已接通电源" }
        if b.externalPower == false { return "使用电池" }
        return "未取得"
    }
    private var fanText: String {
        guard let fans = s?.sensors?.fanRPMs else { return "未取得" }
        if fans.isEmpty { return "未检测到风扇" }
        return fans.enumerated().map { "\(fans.count > 1 ? "\($0.offset + 1): " : "")\(Int($0.element)) RPM" }.joined(separator: "  ")
    }
    private func temperature(_ n: Double?) -> String {
        guard let n, n > 0 else { return "未取得" }
        return String(format: "%.1f °C", n)
    }
    private func metric(_ title: String, _ value: String, _ subtitle: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func detail(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
    private func choice(_ label: String, index: Int) -> some View {
        Text(label).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
            .background(ranking == index ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle()).onTapGesture { ranking = index }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(label) 占用排行")
            .accessibilityAction { ranking = index }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    var status: NSStatusItem!
    let popover = NSPopover()
    var wakeObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(togglePanel)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MonitorPanel(model: model))
        model.onChange = { [weak self] in self?.refreshTitle() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.model.wake() }
        refreshTitle(); model.service.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        model.service.stop()
    }
    private func refreshTitle() {
        guard !model.stale, let s = model.snapshot else { status.button?.title = "◌ 采集中"; return }
        status.button?.title = "CPU \(percent(s.cpu))  M \(percent(s.memory))  ↓\(speed(s.download, short: true)) ↑\(speed(s.upload, short: true))"
        status.button?.toolTip = "点击查看电池、内存压力、温度、风扇和应用占用"
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}

@main @MainActor enum MoleMonitorMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { selfTest(); return }
        if CommandLine.arguments.contains("--diagnose") { diagnose(); return }
        let app = NSApplication.shared; let delegate = AppDelegate()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    static func selfTest() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = try! JSONSerialization.data(withJSONObject: [
            "collected_at": timestamp,
            "cpu": ["usage": 12.5, "logical_cpu": 10],
            "memory": ["total": 100, "used": 50, "used_percent": 50],
            "network_history": ["rx_history": [0, 1.2], "tx_history": [0, 0.4]],
            "network": [["name": "physical", "rx_rate_mbs": 9], ["name": "tunnel", "rx_rate_mbs": 9]]
        ])
        do {
            let s = try Snapshot.decode(data)
            precondition(s.cpu == 12.5 && s.memory == 50 && s.download == 1.2)
            let unknownData = try JSONSerialization.data(withJSONObject: [
                "collected_at": timestamp, "cpu": ["usage": 0, "logical_cpu": 0],
                "memory": ["total": 0], "network_history": ["rx_history": [0, 0]]
            ])
            let unknown = try Snapshot.decode(unknownData)
            precondition(unknown.cpu == nil && unknown.memory == nil && unknown.download == nil)
            precondition(abs(s.receivedAt.timeIntervalSince(Date())) < 2)
            precondition((try? Snapshot.decode(Data("broken".utf8))) == nil)
            print("PASS: structured metrics, missing values, VPN aggregation, malformed JSON")
        } catch { fatalError("decode validation failed") }
    }
    static func diagnose() {
        let service = MonitorService()
        var samples = 0; var last: Snapshot?
        var states: [String] = []
        service.onState = { states.append($0) }
        service.onSnapshot = { samples += 1; last = $0 }; service.start()
        var seconds: Double = 22
        if let i = CommandLine.arguments.firstIndex(of: "--seconds"), i + 1 < CommandLine.arguments.count,
           let n = Double(CommandLine.arguments[i + 1]), n >= 5, n <= 1800 { seconds = n }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds)); service.stop()
        var report: [String: Any] = ["samples": samples, "seconds": seconds, "states": states,
                                     "mode": "headless", "cleaningInvoked": false]
        if let s = last {
            report["cpuPercent"] = s.cpu; report["memoryPercent"] = s.memory
            report["downloadMiBs"] = s.download; report["uploadMiBs"] = s.upload
            report["applicationsCount"] = s.applications.count
            if let sensors = s.sensors, let data = try? JSONEncoder().encode(sensors) {
                report["sensors"] = try? JSONSerialization.jsonObject(with: data)
            }
            if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
                let output = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                let model = MonitorModel(); model.snapshot = s; model.state = "实时"
                let renderer = ImageRenderer(content: MonitorPanel(model: model)
                    .preferredColorScheme(.light).background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: output, options: .atomic); report["staticPreview"] = output.path }
                    catch { report["staticPreviewError"] = "无法写入预览" }
                } else { report["staticPreviewError"] = "渲染不可用" }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        if samples < 2 { exit(2) }
    }
}
