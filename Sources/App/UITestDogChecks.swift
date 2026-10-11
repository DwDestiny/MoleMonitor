// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: `--dog-gallery <directory> --dog-checks` in the UITEST build (scripts/ci_acceptance.py, the I2 block).
// Output: <directory>/dog-report.json: the dog animation gates of docs/DESIGN.md 9.2 (stage 2) with measured values,
//         and the frame cost (thread CPU per frame, process CPU at 24 fps).
// Pos: Test code. It exists only in the UITEST build; the release binary has none of it (checked by the I2 block of
//      scripts/ci_acceptance.py). It shows one small window and one popover with a DogView for about 25 s. Owner I2.
//
// Gates: (a) 60 to 80 frames in 3 s with the card open; (b) 0 frames in 3 s after close; (c) no leg moves faster than
// DogGaitRules.maxLegRate across gait switches; (d) a menu switch has at most 8 frames, lasts at most 600 ms and leaves
// no timer; (e) Reduce Motion gives no frame and no timer.

#if UITEST
import AppKit
import Darwin
import Foundation
import SwiftUI

/// Records the animated frames of every DogView (one entry per timeline date). Main thread only.
enum DogFrameProbe {
    struct Entry {
        var date: Date
        var gait: DogGait
        var legs: [Double]
        var crossfade: Bool
        var stepNs: UInt64
        var drawNs: UInt64
    }

    /// Non-nil replaces the system Reduce Motion setting of DogView.
    static var forceReduceMotion: Bool?
    private(set) static var entries = [Entry]()
    private(set) static var redraws = 0

    static func clock() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    static func record(date: Date, frame: DogFrame, stepNs: UInt64, drawNs: UInt64) {
        if let last = entries.last, last.date == date {
            redraws += 1
            return
        }
        entries.append(Entry(date: date, gait: frame.gait, legs: frame.pose.legAngle, crossfade: frame.fadeFrom != nil,
                             stepNs: stepNs, drawNs: drawNs))
    }

    static func reset() {
        entries = []
        redraws = 0
    }
}

private final class DogCheckModel: ObservableObject {
    @Published var input: DogInput
    init(_ input: DogInput) { self.input = input }
}

private struct DogCheckRoot: View {
    @ObservedObject var model: DogCheckModel
    var body: some View {
        DogView(input: model.input, size: CGSize(width: 104, height: 78))
            .padding(8)
    }
}

private struct DogCheckItem: Encodable {
    var id: String
    var name: String
    var status: String
    var note: String
    var values: [String: Double]
}

@MainActor
final class UITestDogChecks {
    private let outDir: URL
    private var items = [DogCheckItem]()
    private var info = [String: String]()
    private var window: NSWindow?
    private var anchor: NSView?
    private var iconButton: NSButton?
    private var popover: NSPopover?

    private init(outDir: URL) { self.outDir = outDir }

    static func run(outDir: URL) -> Never {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let checks = UITestDogChecks(outDir: outDir)
        Task { @MainActor in
            await checks.runAll()
            checks.write()
            exit(0)
        }
        app.run()
        exit(0)
    }

    // MARK: Helpers

    private func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    private func record(_ id: String, _ name: String, _ ok: Bool, _ note: String, _ values: [String: Double] = [:]) {
        items.append(DogCheckItem(id: id, name: name, status: ok ? "pass" : "fail", note: note, values: values))
        log("[\(ok ? "PASS" : "FAIL")] \(id) \(name) \(note)")
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// User plus system CPU time of the process, s.
    private func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    private static func input(cpu: Double?, thermal: ThermalLevel = .nominal, problem: HealthItem? = nil,
                              level: HealthLevel = .green) -> DogInput {
        DogInput(cpuPercent: cpu, thermal: thermal, memoryLevel: .green, worstProblem: problem, worstLevel: level, isStatic: false)
    }

    private func setUpWindow() {
        let w = NSWindow(contentRect: NSRect(x: 240, y: 360, width: 240, height: 80), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.title = "MoleMonitor dog checks"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let anchorView = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
        let button = NSButton(frame: NSRect(x: 120, y: 28, width: 40, height: 24))
        button.isBordered = false
        content.addSubview(anchorView)
        content.addSubview(button)
        w.contentView = content
        w.orderFrontRegardless()
        window = w
        anchor = anchorView
        iconButton = button
    }

    private func open(_ model: DogCheckModel) {
        guard let anchor else { return }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = false
        p.contentViewController = NSHostingController(rootView: DogCheckRoot(model: model))
        p.contentSize = NSSize(width: 120, height: 94)
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover = p
    }

    /// Same release as AppDelegate.popoverDidClose: the hosting controller and the SwiftUI tree go away.
    private func close() {
        popover?.close()
        popover?.contentViewController = nil
        popover = nil
    }

    // MARK: Checks

    private func runAll() async {
        setUpWindow()
        await sleep(0.5)
        info["screenMaxFPS"] = String(NSScreen.main?.maximumFramesPerSecond ?? 0)
        let sys = StatusIconController.systemConditions()
        info["systemReduceMotion"] = String(sys.reduceMotion)
        info["systemScreenLocked"] = String(sys.screenLocked)
        info["systemDisplayAsleep"] = String(sys.displayAsleep)
        await checkOpenAndClose()
        await checkGaitSwitch()
        await checkMenuSwitch()
        await checkReduceMotion()
        benchOffscreen()
        window?.orderOut(nil)
    }

    /// (a) and (b), with the frame cost of the open card and the process CPU open and closed.
    private func checkOpenAndClose() async {
        let model = DogCheckModel(Self.input(cpu: 60, problem: .cpu, level: .yellow))
        open(model)
        await sleep(0.6)
        DogFrameProbe.reset()
        let cpu0 = processCPU(), t0 = CACurrentMediaTime()
        await sleep(3)
        let openCPU = processCPU() - cpu0, openWall = CACurrentMediaTime() - t0
        let entries = DogFrameProbe.entries
        let n = entries.count
        let steps = entries.map { Double($0.stepNs) / 1000 }.sorted()
        let draws = entries.map { Double($0.drawNs) / 1000 }.sorted()
        let totals = zip(entries.map { $0.stepNs }, entries.map { $0.drawNs }).map { Double($0 + $1) / 1000 }.sorted()
        func p(_ a: [Double], _ q: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * q))] }
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let fps = Double(n) / openWall
        record("DA", "card open: frames in 3 s", (60...80).contains(n),
               "\(n) frames (\(String(format: "%.1f", fps)) fps), \(DogFrameProbe.redraws) extra redraws",
               ["frames": Double(n), "fps": fps, "redraws": Double(DogFrameProbe.redraws),
                "frameUsMean": mean(totals), "frameUsP50": p(totals, 0.5), "frameUsP95": p(totals, 0.95),
                "stepUsMean": mean(steps), "drawUsMean": mean(draws), "drawUsP95": p(draws, 0.95),
                "processCpuPercentOpen": openCPU / openWall * 100])
        close()
        await sleep(0.3)
        DogFrameProbe.reset()
        let cpu1 = processCPU(), t1 = CACurrentMediaTime()
        await sleep(3)
        let closedCPU = processCPU() - cpu1, closedWall = CACurrentMediaTime() - t1
        let after = DogFrameProbe.entries.count + DogFrameProbe.redraws
        record("DB", "card closed: frame callbacks in 3 s", after == 0, "\(after) callbacks",
               ["callbacks": Double(after), "processCpuPercentClosed": closedCPU / closedWall * 100,
                "processCpuPercentDelta": (openCPU / openWall - closedCPU / closedWall) * 100])
    }

    /// (c): CPU jumps from 5 % to 95 %; the motor goes lie -> walk -> trot within 6 s. No leg may move faster than
    /// the natural limit in any frame, crossfade frames included.
    private func checkGaitSwitch() async {
        let model = DogCheckModel(Self.input(cpu: 5))
        open(model)
        await sleep(0.5)
        DogFrameProbe.reset()
        model.input = Self.input(cpu: 95)
        await sleep(6)
        let entries = DogFrameProbe.entries
        close()
        var worstRate = 0.0, worstJump = 0.0
        var gaits = [DogGait]()
        for (a, b) in zip(entries, entries.dropFirst()) {
            let dt = min(max(b.date.timeIntervalSince(a.date), 0), DogGaitRules.maxFrameStep)
            if gaits.last != b.gait { gaits.append(b.gait) }
            guard dt > 0 else { continue }
            for i in 0..<4 {
                let jump = abs(b.legs[i] - a.legs[i])
                worstJump = max(worstJump, jump)
                worstRate = max(worstRate, jump / dt)
            }
        }
        if let first = entries.first, gaits.first != first.gait { gaits.insert(first.gait, at: 0) }
        let fades = entries.filter { $0.crossfade }.count
        let switched = gaits.count >= 2
        record("DC", "gait switch: leg speed under the natural limit", switched && worstRate <= DogGaitRules.maxLegRate,
               "gaits \(gaits.map { $0.rawValue }.joined(separator: " -> ")), worst \(Int(worstRate)) deg/s "
                   + "(limit \(Int(DogGaitRules.maxLegRate))), worst frame jump \(String(format: "%.1f", worstJump)) deg, "
                   + "\(fades) crossfade frames",
               ["worstDegPerSecond": worstRate, "limitDegPerSecond": DogGaitRules.maxLegRate, "worstFrameJumpDeg": worstJump,
                "gaitCount": Double(gaits.count), "crossfadeFrames": Double(fades), "frames": Double(entries.count)])
    }

    /// (d): one play per change, at most 8 frames in at most 600 ms, no timer after it; the 5 minute throttle.
    private func checkMenuSwitch() async {
        guard let iconButton else { return }
        let controller = StatusIconController(statusItem: nil)
        controller.fallbackButton = iconButton
        info["iconVisibleSeenByController"] = String(controller.currentConditions().iconVisible)
        controller.conditionsOverride = { MenuMotionConditions() }
        var events = [(frame: Int, t: Double)]()
        controller.onImage = { events.append((frame: $0, t: CACurrentMediaTime())) }
        let relaxed = MenuIconState(posture: .relaxed, badge: nil)
        let raisedCpu = MenuIconState(posture: .raised, badge: MenuBadge(item: .cpu))
        let pantCpu = MenuIconState(posture: .pant, badge: MenuBadge(item: .cpu))
        let pantThermal = MenuIconState(posture: .pant, badge: MenuBadge(item: .thermal))
        controller.apply(relaxed, text: "a")
        let timersBefore = controller.timerCount

        func play(_ state: MenuIconState, _ text: String) async -> (frames: Int, ms: Double, timersAfter: Int) {
            events = []
            let t0 = CACurrentMediaTime()
            let start = CPUClock.now()
            controller.apply(state, text: text)
            let applyUs = Double(CPUClock.now() - start) / 1000
            info["menuApplyUs-\(state.posture.rawValue)-\(state.badge?.item.rawValue ?? "none")"] = String(format: "%.0f", applyUs)
            await sleep(1.0)
            let ms = ((events.last?.t ?? t0) - (events.first?.t ?? t0)) * 1000
            return (events.filter { $0.frame > 0 }.count, ms, controller.timerCount)
        }
        let up = await play(raisedCpu, "b")
        let okUp = up.frames >= 2 && up.frames <= MenuMotion.frameCount && up.ms <= 600 && up.timersAfter == timersBefore
        let red = await play(pantThermal, "c")
        let okRed = red.frames >= 2 && red.frames <= MenuMotion.frameCount && red.ms <= 600 && red.timersAfter == timersBefore
        let throttled = await play(pantCpu, "d")   // cpu played less than 5 minutes ago: direct switch
        let okThrottle = throttled.frames == 0 && throttled.timersAfter == timersBefore
        record("DD", "menu switch: <= 8 frames, <= 600 ms, no timer after", okUp && okRed && okThrottle,
               "normal->attention \(up.frames) frames \(Int(up.ms)) ms, attention->alarm \(red.frames) frames \(Int(red.ms)) ms, "
                   + "same item again within 5 min \(throttled.frames) frames; timers before \(timersBefore), after "
                   + "\(up.timersAfter)/\(red.timersAfter)/\(throttled.timersAfter)",
               ["framesUp": Double(up.frames), "msUp": up.ms, "framesRed": Double(red.frames), "msRed": red.ms,
                "framesThrottled": Double(throttled.frames), "timersBefore": Double(timersBefore),
                "timersAfter": Double(max(up.timersAfter, red.timersAfter, throttled.timersAfter))])
    }

    /// (e): Reduce Motion: the card draws the static frame and no animated frame; the menu switches directly.
    private func checkReduceMotion() async {
        DogFrameProbe.forceReduceMotion = true
        let model = DogCheckModel(Self.input(cpu: 60, thermal: .serious, problem: .thermal, level: .red))
        open(model)
        await sleep(0.3)
        DogFrameProbe.reset()
        await sleep(3)
        let frames = DogFrameProbe.entries.count + DogFrameProbe.redraws
        close()
        DogFrameProbe.forceReduceMotion = nil

        let controller = StatusIconController(statusItem: nil)
        controller.fallbackButton = iconButton
        controller.conditionsOverride = { MenuMotionConditions(reduceMotion: true) }
        var events = [Int]()
        controller.onImage = { events.append($0) }
        controller.apply(MenuIconState(posture: .relaxed, badge: nil), text: "a")
        controller.apply(MenuIconState(posture: .raised, badge: MenuBadge(item: .disk)), text: "b")
        let timerNow = controller.timerCount
        await sleep(0.8)
        let ok = frames == 0 && events == [0, 0] && timerNow == 0 && controller.timerCount == 0
        record("DE", "Reduce Motion: no frames, no timer", ok,
               "card animated frames \(frames), menu images \(events), timers \(timerNow)/\(controller.timerCount)",
               ["cardFrames": Double(frames), "menuAnimatedFrames": Double(events.filter { $0 > 0 }.count),
                "timers": Double(max(timerNow, controller.timerCount))])
    }

    /// Frame cost without SwiftUI: motor step, layers and Core Graphics drawing into a 2x bitmap of the card.
    private func benchOffscreen() {
        func bench(_ name: String, cpu: Double, thermal: ThermalLevel = .nominal, problem: HealthItem? = nil,
                   size: CGSize, frames: Int = 240) {
            let input = Self.input(cpu: cpu, thermal: thermal, problem: problem, level: problem == nil ? .green : .yellow)
            var motor = DogMotor(initialCPU: cpu)
            let w = Int(size.width) * 2, h = Int(size.height) * 2
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 2, y: -2)
            var times = [Double]()
            for _ in 0..<frames {
                let start = CPUClock.now()
                let frame = motor.frame(dt: 1.0 / 24, input: input)
                ctx.clear(CGRect(origin: .zero, size: size))
                DogRenderer.drawFrame(frame, input: input, dark: false, in: CGRect(origin: .zero, size: size), ctx: ctx)
                times.append(Double(CPUClock.now() - start) / 1000)
            }
            times.sort()
            let mean = times.reduce(0, +) / Double(times.count)
            info["bench-\(name)-us-mean"] = String(format: "%.0f", mean)
            info["bench-\(name)-us-p95"] = String(format: "%.0f", times[Int(Double(times.count) * 0.95)])
        }
        bench("trot-bubble-104", cpu: 60, problem: .cpu, size: CGSize(width: 104, height: 78))
        bench("sprint-104", cpu: 95, size: CGSize(width: 104, height: 78))
        bench("walk-pant-72", cpu: 25, thermal: .serious, size: CGSize(width: 72, height: 54))
        bench("lie-104", cpu: 3, size: CGSize(width: 104, height: 78))
        // Crossfade frames draw two dogs: a stepped switch lie -> walk.
        var motor = DogMotor(initialCPU: 5)
        var crossfadeTimes = [Double]()
        let w = 208, h = 156
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 2, y: -2)
            let input = Self.input(cpu: 95)
            for _ in 0..<(24 * 6) {
                let start = CPUClock.now()
                let frame = motor.frame(dt: 1.0 / 24, input: input)
                ctx.clear(CGRect(x: 0, y: 0, width: 104, height: 78))
                DogRenderer.drawFrame(frame, input: input, dark: false, in: CGRect(x: 0, y: 0, width: 104, height: 78), ctx: ctx)
                if frame.fadeFrom != nil { crossfadeTimes.append(Double(CPUClock.now() - start) / 1000) }
            }
        }
        if !crossfadeTimes.isEmpty {
            info["bench-crossfade-104-us-mean"] = String(format: "%.0f", crossfadeTimes.reduce(0, +) / Double(crossfadeTimes.count))
            info["bench-crossfade-frames"] = String(crossfadeTimes.count)
        }
        // Menu switch frames: 7 bitmaps (1x and 2x) for one switch.
        let start = CPUClock.now()
        let frames = MenuMotion.frames(from: MenuIconState(posture: .relaxed, badge: nil),
                                       to: MenuIconState(posture: .pant, badge: MenuBadge(item: .memory)))
        for f in frames.dropLast() { _ = MenuIconRenderer.image(f, cached: false) }
        info["bench-menu-switch-frames-us"] = String(format: "%.0f", Double(CPUClock.now() - start) / 1000)
        info["pathCacheEntries"] = String(DogPathCache.count)
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Encodable {
            var items: [DogCheckItem]
            var info: [String: String]
        }
        if let data = try? encoder.encode(Report(items: items, info: info)) {
            try? data.write(to: outDir.appendingPathComponent("dog-report.json"))
        }
    }
}

/// Thread CPU clock, ns.
private enum CPUClock {
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}
#endif
