// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: `--dog-gallery <directory> --dog-checks` in the UITEST build (scripts/ci_acceptance.py, the dog block), and the panel
//        gates of UITestPanelChecks.swift (M20).
// Output: BA to BE in <directory>/dog-report.json, and four contact sheets of the eight bitmap poses
//         (bitmap-sheet-light.png, bitmap-sheet-dark.png, and the same two with the ground shadow).
// Pos: Test code of the bitmap dog (docs/DESIGN.md 4.9). It exists only in the UITEST build. The release binary has none of it.
//
// BA  card open and closed: 0 frame callbacks, 0 body evaluations in 3 s each (no TimelineView, no timer).
// BB  Reduce Motion: a pose switch attaches no crossfade. The control run with motion on attaches it.
// BC  the eight files load as 320 x 240 px, a missing directory falls back without a crash.
// BD  pairwise XOR of the non-background pixels at 72 x 54 pt 1x, 21 pairs of 7 poses, gate 0.20 (the values are all reported).
// BE  the share of non-background pixels (the M19 rule): gray at least 1.5 %, every other pose at least 1 %.
// BF  the ground shadow of each of the 8 poses: center y within 2 px of the lower edge of the dog (72 x 54 px), center x within 2 px
//     of the dog center, width 0.7 to 0.8 of the dog width (sprint narrower and lighter).
// M21 problem mode hero in the real panel: dog box at least 64 pt wide, at least 6 pt below the panel top, the bubble box and the
//     dog ink box do not intersect (diskRed and multi, light and dark).
// M22 light multi: the collapsed problem rows have a gray fill (no hue) and a 3 pt bar in the level color. The first card keeps a tint.

#if UITEST
import AppKit
import SwiftUI

/// What the bitmap dog did. Main thread only.
enum DogBitmapProbe {
    struct Switch {
        var pose: DogArtPose
        var animated: Bool
    }

    /// Non-nil replaces the clock of DogBitmapView, so a test can deliver data points 30 s apart in a few milliseconds.
    static var simulated: Date?
    static func now() -> Date { simulated ?? Date() }
    static func advanceClock(_ seconds: TimeInterval) { simulated = (simulated ?? Date()).addingTimeInterval(seconds) }

    private(set) static var bodies = 0
    private(set) static var lastPose: DogArtPose?
    private(set) static var switches = [Switch]()

    static func bodyEvaluated(pose: DogArtPose) {
        bodies += 1
        lastPose = pose
    }

    static func switched(to pose: DogArtPose, animated: Bool) {
        switches.append(Switch(pose: pose, animated: animated))
    }

    static func reset() {
        bodies = 0
        switches = []
    }
}

/// The eight poses on one card surface: 104 x 78 pt in two rows of four, then 72 x 54 pt.
private struct DogBitmapSheet: View {
    let dark: Bool

    static let inputs: [(String, DogInput)] = [
        ("lie", DogInput(cpuPercent: 3, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("stand", DogInput(cpuPercent: nil, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("walk", DogInput(cpuPercent: 25, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("trot", DogInput(cpuPercent: 60, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("sprint", DogInput(cpuPercent: 95, thermal: .nominal, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("pant", DogInput(cpuPercent: 20, thermal: .serious, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: false)),
        ("alert", DogInput(cpuPercent: 20, thermal: .nominal, memoryLevel: .green, worstProblem: .disk, worstLevel: .red, isStatic: false)),
        ("gray", DogInput(cpuPercent: nil, thermal: nil, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: true)),
    ]

    private func row(_ range: Range<Int>, _ size: CGSize) -> some View {
        HStack(spacing: 10) {
            ForEach(range, id: \.self) { i in
                VStack(spacing: 2) {
                    DogView(input: DogBitmapSheet.inputs[i].1, size: size)
                    Text(DogBitmapSheet.inputs[i].0)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            row(0..<4, CGSize(width: 104, height: 78))
            row(4..<8, CGSize(width: 104, height: 78))
            row(0..<4, CGSize(width: 72, height: 54))
            row(4..<8, CGSize(width: 72, height: 54))
        }
        .padding(12)
        .background(PanelTokens.surface(dark: dark))
    }
}

extension UITestDogChecks {
    // MARK: Entry

    func checkBitmapAll() async {
        DogView.useBitmapArt = true
        DogFrameProbe.forceReduceMotion = false
        checkBitmapLoad()
        checkBitmapXor()
        checkBitmapShare()
        checkBitmapShadow()
        await checkBitmapOpenClose()
        await checkBitmapReduceMotion()
        renderBitmapSheets()
    }

    // MARK: BC, the files

    private func checkBitmapLoad() {
        let library = DogArtLibrary.shared
        var bad = [String]()
        var transparentCorners = 0
        for pose in DogArtPose.allCases {
            guard let image = library.original(pose) else {
                bad.append(pose.fileName + " missing")
                continue
            }
            if image.width != 320 || image.height != 240 { bad.append("\(pose.fileName) is \(image.width) x \(image.height)") }
            if let small = DogArtLibrary.resample(image, width: 4, height: 3), let data = small.dataProvider?.data,
               let bytes = CFDataGetBytePtr(data), bytes[3] == 0 {
                transparentCorners += 1
            }
        }
        let bundle = DogArtLibrary.bundleDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // A directory without the files: no crash, no image, and the card falls back to the vector dog.
        let empty = DogArtLibrary(directory: URL(fileURLWithPath: "/nonexistent-dog-art-directory", isDirectory: true))
        let fallback = !empty.isComplete && empty.missing.count == DogArtPose.allCases.count
            && empty.image(.stand, width: 10, height: 10) == nil && empty.original(.gray) == nil
        let routed = DogView.showsBitmap
        DogView.useBitmapArt = false
        let off = !DogView.showsBitmap
        DogView.useBitmapArt = true
        let ok = bad.isEmpty && library.isComplete && bundle && fallback && routed && off
        record("BC", "bitmap files: 8 files of 320 x 240 px, fallback without a crash", ok,
               "loaded \(DogArtPose.allCases.count - library.missing.count) of 8, problems \(bad), bundle folder \(bundle), "
                   + "missing folder gives no image and no crash \(fallback), DogView shows the bitmap \(routed), "
                   + "switch false shows the vector dog \(off), transparent top left corner in \(transparentCorners) of 8 (information)",
               ["loaded": Double(DogArtPose.allCases.count - library.missing.count), "problems": Double(bad.count),
                "fallbackOk": fallback ? 1 : 0, "transparentCorners": Double(transparentCorners)])
    }

    // MARK: BD, how different the poses look at 72 x 54 pt 1x

    private func alphaGrid(_ pose: DogArtPose) -> [[Double]]? {
        guard let original = DogArtLibrary.shared.original(pose),
              let small = DogArtLibrary.resample(original, width: 72, height: 54),
              let data = small.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let row = small.bytesPerRow
        var grid = [[Double]]()
        for y in 0..<54 {
            var line = [Double]()
            for x in 0..<72 { line.append(Double(bytes[y * row + x * 4 + 3]) / 255) }
            grid.append(line)
        }
        return grid
    }

    private func checkBitmapXor() {
        let poses: [DogArtPose] = [.lie, .stand, .walk, .trot, .sprint, .pant, .alert]
        var grids = [(String, [[Double]])]()
        for pose in poses {
            if let grid = alphaGrid(pose) { grids.append((pose.rawValue, grid)) }
        }
        guard grids.count == poses.count else {
            record("BD", "bitmap poses differ at 72 x 54 pt", false, "a pose could not be read", [:])
            return
        }
        let result = IconMetrics.matrix(grids)
        let low = result.pairs.filter { $0.value < 0.20 }.sorted { $0.value < $1.value }
        var values = [String: Double]()
        for (key, value) in result.pairs { values[key] = (value * 1000).rounded() / 1000 }
        let all = result.pairs.sorted { $0.value < $1.value }.map { "\($0.key) \(String(format: "%.3f", $0.value))" }
        // gray and stand have the same outline (gray is stand without color), so they are not compared.
        var note = "21 pairs of the 7 poses, XOR of the pixels with alpha >= 0.5 divided by the larger count, at 72 x 54 px (1x), gate 0.20. "
        note += "Smallest first: " + all.joined(separator: ", ")
        if !low.isEmpty {
            note += ". BELOW 0.20: " + low.map { "\($0.key) \(String(format: "%.3f", $0.value))" }.joined(separator: ", ")
        }
        record("BD", "bitmap poses differ at 72 x 54 pt (pairwise XOR >= 0.20)", low.isEmpty, note, values)
    }

    // MARK: BE, the share of non-background pixels (the M19 rule)

    private func checkBitmapShare() {
        let w = 72, h = 54
        var rows = [String]()
        var values = [String: Double]()
        var problems = [String]()
        for dark in [false, true] {
            let surface = dark ? UITestContrast.darkSurface : UITestContrast.lightSurface
            for pose in DogArtPose.allCases {
                guard let image = DogArtLibrary.shared.image(pose, width: w, height: h),
                      let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    problems.append("\(pose.rawValue): no image")
                    continue
                }
                ctx.setFillColor(CGColor(srgbRed: surface.r / 255, green: surface.g / 255, blue: surface.b / 255, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let flat = ctx.makeImage(), let shot = UITestPixels.shot(from: flat, pointWidth: CGFloat(w)),
                      let stats = UITestDogStats.measure(shot, region: CGRect(x: 0, y: 0, width: w, height: h), surface: surface) else {
                    problems.append("\(pose.rawValue) \(dark ? "dark" : "light"): no ink")
                    continue
                }
                let share = Double(stats.ink) / Double(max(1, stats.area))
                let limit = pose == .gray ? 0.015 : 0.01
                let key = pose.rawValue + (dark ? ".dark" : ".light")
                values[key] = (share * 10000).rounded() / 10000
                rows.append("\(key) \(String(format: "%.1f", share * 100)) %")
                if share < limit { problems.append("\(key): \(String(format: "%.3f", share)) < \(limit)") }
                if stats.colors < 12 { problems.append("\(key): only \(stats.colors) colors") }
            }
        }
        record("BE", "bitmap poses: non-background share at 72 x 54 pt (gray >= 1.5 %, others >= 1 %)", problems.isEmpty && rows.count == 16,
               rows.joined(separator: ", ") + (problems.isEmpty ? "" : ". Problems: " + problems.joined(separator: "; ")), values)
    }

    // MARK: BF, the ground shadow follows each pose

    /// The shadow of every pose, measured on the 72 x 54 px alpha grid (the 1x look of the problem-mode dog), against the ellipse that the
    /// view draws (`DogBitmapView.shadowSpec`). The grid is read at alpha 0.5. The view reads the 320 x 240 file, so the two differ by
    /// at most one pixel of the small grid.
    private func checkBitmapShadow() {
        let box = CGSize(width: 72, height: 54)
        var rows = [String]()
        var problems = [String]()
        var values = [String: Double]()
        var sprintOpacity = 1.0
        var otherOpacity = 1.0
        for pose in DogArtPose.allCases {
            guard let grid = alphaGrid(pose) else {
                problems.append("\(pose.rawValue): no picture")
                continue
            }
            var left = 72, right = -1, bottom = -1
            for y in 0..<54 {
                for x in 0..<72 where grid[y][x] >= 0.5 {
                    if x < left { left = x }
                    if x > right { right = x }
                    if y > bottom { bottom = y }
                }
            }
            guard right >= left, bottom >= 0 else {
                problems.append("\(pose.rawValue): no ink on the grid")
                continue
            }
            let spec = DogBitmapView.shadowSpec(pose: pose, box: box, ink: DogArtLibrary.shared.inkBox(pose))
            let bodyWidth = Double(right + 1 - left)
            let bodyCenter = Double(left + right + 1) / 2 + DogBitmapView.shift(pose, box: box)
            let dy = abs(spec.centerY - Double(bottom + 1))
            let dx = abs(spec.centerX - bodyCenter)
            let ratio = spec.width / bodyWidth
            let dyText = String(format: "%.2f", dy), dxText = String(format: "%.2f", dx)
            let ratioText = String(format: "%.2f", ratio), opacityText = String(format: "%.2f", spec.opacity)
            rows.append(pose.rawValue + " dy " + dyText + " px, dx " + dxText + " px, width " + ratioText + ", opacity " + opacityText)
            values[pose.rawValue + ".dy"] = (dy * 100).rounded() / 100
            values[pose.rawValue + ".widthRatio"] = (ratio * 100).rounded() / 100
            if dy > 2 { problems.append(pose.rawValue + ": center y is " + dyText + " px from the lower edge") }
            if dx > 2 { problems.append(pose.rawValue + ": center x is " + dxText + " px from the dog center") }
            if pose == .sprint {
                sprintOpacity = spec.opacity
                if ratio >= 0.65 { problems.append("sprint: width ratio " + ratioText + " is not narrower") }
            } else {
                otherOpacity = Swift.min(otherOpacity, spec.opacity)
                if ratio < 0.68 || ratio > 0.82 { problems.append(pose.rawValue + ": width ratio " + ratioText + " is not near 0.75") }
            }
        }
        if sprintOpacity >= otherOpacity { problems.append("sprint shadow is not lighter than the others") }
        record("BF", "bitmap ground shadow follows the pose (center y within 2 px of the lower edge)", problems.isEmpty && rows.count == 8,
               rows.joined(separator: "; ") + (problems.isEmpty ? "" : ". Problems: " + problems.joined(separator: "; ")), values)
    }

    // MARK: BA, no frame callbacks

    private func checkBitmapOpenClose() async {
        DogView.useBitmapArt = true
        DogFrameProbe.forceReduceMotion = false
        DogBitmapProbe.simulated = nil
        let model = DogCheckModel(Self.input(cpu: 60, problem: .cpu, level: .yellow))
        open(model)
        await sleep(1.8)   // the bubble pop is over after 1.2 s
        DogBitmapProbe.reset()
        DogFrameProbe.reset()
        let cpu0 = processCPU(), t0 = CACurrentMediaTime()
        await sleep(3)
        let openCPU = processCPU() - cpu0, openWall = CACurrentMediaTime() - t0
        let openBodies = DogBitmapProbe.bodies
        let openVectorFrames = DogFrameProbe.entries.count + DogFrameProbe.redraws
        close()
        await sleep(0.3)
        DogBitmapProbe.reset()
        DogFrameProbe.reset()
        let cpu1 = processCPU(), t1 = CACurrentMediaTime()
        await sleep(3)
        let closedCPU = processCPU() - cpu1, closedWall = CACurrentMediaTime() - t1
        let closedBodies = DogBitmapProbe.bodies + DogFrameProbe.entries.count + DogFrameProbe.redraws
        let ok = openBodies == 0 && openVectorFrames == 0 && closedBodies == 0
        record("BA", "bitmap card: 0 frame callbacks in 3 s open and 3 s closed", ok,
               "open: \(openBodies) body evaluations and \(openVectorFrames) vector frames in 3 s; closed: \(closedBodies); "
                   + "process CPU open \(String(format: "%.2f", openCPU / openWall * 100)) %, closed \(String(format: "%.2f", closedCPU / closedWall * 100)) %. "
                   + "The view has no TimelineView, Canvas or timer (source audit in scripts/ci_acceptance.py).",
               ["openBodies": Double(openBodies), "openVectorFrames": Double(openVectorFrames), "closedCallbacks": Double(closedBodies),
                "processCpuPercentOpen": openCPU / openWall * 100, "processCpuPercentClosed": closedCPU / closedWall * 100])
    }

    // MARK: BB, Reduce Motion

    private func runPoseSequence(reduceMotion: Bool) async -> (switches: [DogBitmapProbe.Switch], seen: [DogArtPose?]) {
        DogFrameProbe.forceReduceMotion = reduceMotion
        DogBitmapProbe.simulated = Date()
        let model = DogCheckModel(Self.input(cpu: 5))
        open(model)
        await sleep(0.5)
        DogBitmapProbe.reset()
        let steps: [DogInput] = [
            Self.input(cpu: 95),
            Self.input(cpu: 95, thermal: .serious),
            Self.input(cpu: 95, problem: .disk, level: .red),
            DogInput(cpuPercent: nil, thermal: nil, memoryLevel: .green, worstProblem: nil, worstLevel: .green, isStatic: true),
        ]
        var seen = [DogArtPose?]()
        for step in steps {
            DogBitmapProbe.advanceClock(30)
            model.input = step
            await sleep(0.45)
            seen.append(DogBitmapProbe.lastPose)
        }
        let switches = DogBitmapProbe.switches
        close()
        await sleep(0.2)
        DogBitmapProbe.simulated = nil
        return (switches, seen)
    }

    private func checkBitmapReduceMotion() async {
        let expected: [DogArtPose?] = [.sprint, .pant, .alert, .gray]
        let still = await runPoseSequence(reduceMotion: true)
        let moving = await runPoseSequence(reduceMotion: false)
        DogFrameProbe.forceReduceMotion = false
        let stillOk = still.seen == expected && still.switches.count == 4 && still.switches.allSatisfy { !$0.animated }
        let movingOk = moving.seen == expected && moving.switches.count == 4 && moving.switches.allSatisfy { $0.animated }
        record("BB", "bitmap Reduce Motion: a pose switch has no crossfade", stillOk && movingOk,
               "Reduce Motion on: poses \(still.seen.map { $0?.rawValue ?? "nil" }), \(still.switches.count) switches, "
                   + "\(still.switches.filter { $0.animated }.count) with a crossfade. Control, motion on: poses "
                   + "\(moving.seen.map { $0?.rawValue ?? "nil" }), \(moving.switches.count) switches, "
                   + "\(moving.switches.filter { $0.animated }.count) with a crossfade (0.22 s easeInOut). "
                   + "The probe records whether the crossfade animation was attached; cacheDisplay cannot show a frame in flight.",
               ["stillSwitches": Double(still.switches.count), "stillAnimated": Double(still.switches.filter { $0.animated }.count),
                "motionSwitches": Double(moving.switches.count), "motionAnimated": Double(moving.switches.filter { $0.animated }.count)])
    }

    // MARK: Contact sheets

    private func renderBitmapSheets() {
        DogView.useBitmapArt = true
        let saved = DogBitmapView.groundShadow
        defer { DogBitmapView.groundShadow = saved }
        for shadow in [false, true] {
            DogBitmapView.groundShadow = shadow
            for dark in [false, true] {
                let view = DogBitmapSheet(dark: dark)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.panelSnapshot, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    info["sheet-\(dark ? "dark" : "light")\(shadow ? "-shadow" : "")"] = "ImageRenderer returned no image"
                    continue
                }
                let name = "bitmap-sheet-\(dark ? "dark" : "light")\(shadow ? "-shadow" : "").png"
                try? png.write(to: outDir.appendingPathComponent(name))
                info["sheet-\(dark ? "dark" : "light")\(shadow ? "-shadow" : "")"] = "\(image.width) x \(image.height) px"
            }
        }
    }
}

// MARK: - Panel gates (the --ui-test run)

extension UITestRunner {
    /// M19V: the M19 rule on the vector dog, with the bitmap switch off. Same limits as M19: a live dog at least 1 % of its region,
    /// the gray dog at least 1.5 %, at least 12 colors. M19 itself now runs on the default path, the bitmap dog.
    func stepVectorDog() async {
        let t0 = now()
        DogView.useBitmapArt = false
        defer { DogView.useBitmapArt = true }
        var problems = [String]()
        var notes = [String]()
        let copyBox = UITestTextBox()
        for c in PreviewCase.allCases {
            guard await openFixture(c, copyBox: copyBox) != nil, let hv = hostView else {
                problems.append("\(c.rawValue): the panel did not open")
                continue
            }
            for dark in [false, true] {
                await setAppearance(dark: dark)
                let key = c.rawValue + (dark ? " dark" : " light")
                let surface = dark ? UITestContrast.darkSurface : UITestContrast.lightSurface
                guard let shot = capture(hv), let rect = panelRect("dog"),
                      let stats = UITestDogStats.measure(shot, region: rect, surface: surface) else {
                    problems.append("\(key): no dog region or no ink")
                    continue
                }
                let share = Double(stats.ink) / Double(Swift.max(1, stats.area))
                notes.append("\(key) \(String(format: "%.1f", share * 100)) %, \(stats.colors) colors")
                let minShare = (c == .collecting || c == .stale) ? 0.015 : 0.01
                if share < minShare { problems.append("\(key): ink share \(String(format: "%.3f", share)) < \(minShare)") }
                if stats.colors < 12 { problems.append("\(key): only \(stats.colors) colors, not a drawn dog") }
            }
            resetAppearance()
            await sleepMs(200)
            await closeFixture()
        }
        var note = "vector dog (switch false): " + notes.joined(separator: "; ")
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("M19V", "面板里矢量比熊真实渲染（开关关闭，沿用 M19 门槛）", problems.isEmpty && notes.count >= 14, since: t0, note,
               ["problems": Double(problems.count), "measured": Double(notes.count)])
    }

    /// Mean color of a region of a screenshot over the surface color (the hosting view has no background of its own).
    private func meanColor(_ shot: UITestShot, region: CGRect, surface: UITestContrast.RGB) -> UITestContrast.RGB? {
        let box = UITestPixels.pixelRegion(region, of: shot)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0
        var count = 0.0
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * shot.w + x) * 4
                let behind = 1 - Double(shot.rgba[i + 3]) / 255
                sr += Swift.min(255.0, Double(shot.rgba[i]) + surface.r * behind)
                sg += Swift.min(255.0, Double(shot.rgba[i + 1]) + surface.g * behind)
                sb += Swift.min(255.0, Double(shot.rgba[i + 2]) + surface.b * behind)
                count += 1
            }
        }
        return (sr / count, sg / count, sb / count)
    }

    private func srgb(_ color: Color) -> UITestContrast.RGB {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    /// M21: the hero of the problem mode in the real panel. The dog box is at least 64 pt wide and at least 6 pt below the panel top.
    /// The bubble box and the dog ink box (both from the alpha of the pictures that the view draws) do not intersect, and the
    /// highest ink (bubble or dog) is at least 6 pt below the panel top, so nothing is cut at the top.
    func stepHeroDog() async {
        let t0 = now()
        DogView.useBitmapArt = true
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let copyBox = UITestTextBox()
        let library = DogArtLibrary.shared
        for c in [PreviewCase.diskRed, PreviewCase.multi] {
            guard let model = await openFixture(c, copyBox: copyBox) else {
                problems.append("\(c.rawValue): the panel did not open")
                continue
            }
            await sleepMs(300)
            let pose = DogBitmapProbe.lastPose
            let input = model.data.dogInput
            guard let rect = panelRect("dog"), let item = input.worstProblem,
                  let dogInk = library.inkBox(.alert, minAlpha: 8) else {
                problems.append("\(c.rawValue): no dog frame or no problem item")
                await closeFixture()
                continue
            }
            if pose != .alert { problems.append("\(c.rawValue): the dog pose is \(pose?.rawValue ?? "nil"), expected alert") }
            if rect.width < 64 { problems.append("\(c.rawValue): dog box \(Int(rect.width)) pt wide, needs 64") }
            if rect.minY < 6 { problems.append(c.rawValue + ": dog box top is " + String(format: "%.1f", Double(rect.minY)) + " pt below the panel top, needs 6") }
            for dark in [false, true] {
                let key = c.rawValue + (dark ? " dark" : " light")
                let w = Int(rect.width * 4), h = Int(rect.height * 4)
                guard let bubbleImage = library.bubble(item: item, level: input.worstLevel, dark: dark, width: w, height: h),
                      let bubbleInk = DogInkBox.measure(bubbleImage, minAlpha: 8) else {
                    problems.append("\(key): no bubble picture")
                    continue
                }
                let dogRect = CGRect(x: dogInk.minX * Double(rect.width) + DogBitmapView.shift(.alert, box: rect.size), y: dogInk.minY * Double(rect.height),
                                     width: dogInk.width * Double(rect.width), height: (dogInk.maxY - dogInk.minY) * Double(rect.height))
                let bubbleRect = CGRect(x: bubbleInk.minX * Double(rect.width), y: bubbleInk.minY * Double(rect.height),
                                        width: bubbleInk.width * Double(rect.width), height: (bubbleInk.maxY - bubbleInk.minY) * Double(rect.height))
                let gap = bubbleRect.minX - dogRect.maxX
                let topInk = rect.minY + Swift.min(dogRect.minY, bubbleRect.minY)
                let gapText = String(format: "%.1f", Double(gap)), topText = String(format: "%.1f", Double(topInk))
                var line = key + " box " + String(Int(rect.width)) + " x " + String(Int(rect.height))
                line += " pt, dog ink " + String(Int(dogRect.width)) + " x " + String(Int(dogRect.height))
                line += " pt, gap bubble to dog " + gapText + " pt, top ink " + topText + " pt below the panel top"
                notes.append(line)
                if dogRect.intersects(bubbleRect) { problems.append(key + ": the bubble box meets the dog ink box") }
                if gap < 2 { problems.append(key + ": the bubble is " + gapText + " pt from the dog, needs 2") }
                if topInk < 6 { problems.append(key + ": the highest ink is " + topText + " pt below the panel top, needs 6") }
                values[key + ".gap"] = Double((gap * 10).rounded() / 10)
                values[key + ".topInk"] = Double((topInk * 10).rounded() / 10)
            }
            values[c.rawValue + ".boxWidth"] = Double(rect.width)
            values[c.rawValue + ".boxTop"] = Double(rect.minY)
            values[c.rawValue + ".dogInkHeight"] = ((dogInk.maxY - dogInk.minY) * Double(rect.height) * 10).rounded() / 10
            await closeFixture()
        }
        var note = notes.joined(separator: "; ")
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("M21", "问题模式比熊：框不小于 64 pt，气泡不压身体，顶部不裁切", problems.isEmpty && notes.count == 4, since: t0, note, values)
    }

    /// M22: the light scheme multi card. The three collapsed rows have a gray fill (no hue, near the panel color) and a 3 pt bar in
    /// the level color at the left edge. The first card keeps a light tint with a hue. The dark scheme is not asserted (it keeps the tint).
    func stepCollapsedRows() async {
        let t0 = now()
        var problems = [String]()
        var notes = [String]()
        var values = [String: Double]()
        let copyBox = UITestTextBox()
        guard let model = await openFixture(.multi, copyBox: copyBox), let hv = hostView else {
            record("M22", "浅色折叠问题卡无彩色底，左侧色条表示等级", false, since: t0, "the panel did not open")
            return
        }
        await setAppearance(dark: false)
        let surface = UITestContrast.lightSurface
        let light = PanelTokens(scheme: .light)
        let barColors: [HealthLevel: UITestContrast.RGB] = [.red: srgb(light.lampDanger), .yellow: srgb(light.lampWarning)]
        guard let shot = capture(hv) else {
            record("M22", "浅色折叠问题卡无彩色底，左侧色条表示等级", false, since: t0, "no screenshot")
            await closeFixture()
            return
        }
        var rows = [HealthItem]()
        var cardItem: HealthItem?
        for section in model.layoutPlan.sections {
            if case .problemRow(let item, _) = section { rows.append(item) }
            if case .problemCard(let item, _, _) = section { cardItem = item }
        }
        if rows.count != 3 { problems.append("expected 3 collapsed rows, found \(rows.count)") }
        for item in rows {
            guard let rect = panelRect("row." + item.rawValue), let verdict = model.data.verdict(item),
                  let expectedBar = barColors[verdict.level] else {
                problems.append("\(item.rawValue): no row frame or level")
                continue
            }
            let fillRegion = CGRect(x: rect.minX + 5, y: rect.minY + 6, width: 4, height: rect.height - 12)
            let barRegion = CGRect(x: rect.minX + 0.5, y: rect.minY + 8, width: 2, height: rect.height - 16)
            guard let fill = meanColor(shot, region: fillRegion, surface: surface), let bar = meanColor(shot, region: barRegion, surface: surface) else {
                problems.append("\(item.rawValue): no pixels")
                continue
            }
            let fillShift = Swift.max(abs(fill.r - surface.r), abs(fill.g - surface.g), abs(fill.b - surface.b))
            let fillChroma = Swift.max(fill.r, fill.g, fill.b) - Swift.min(fill.r, fill.g, fill.b)
            let barShift = Swift.max(abs(bar.r - expectedBar.r), abs(bar.g - expectedBar.g), abs(bar.b - expectedBar.b))
            let otherLevel: HealthLevel = verdict.level == .red ? .yellow : .red
            var otherShift = 255.0
            if let other = barColors[otherLevel] {
                otherShift = Swift.max(abs(bar.r - other.r), abs(bar.g - other.g), abs(bar.b - other.b))
            }
            let key = item.rawValue + " " + verdict.level.rawValue
            let shiftText = String(format: "%.1f", fillShift), chromaText = String(format: "%.1f", fillChroma)
            let barText = String(format: "%.1f", barShift), otherText = String(format: "%.1f", otherShift)
            notes.append(key + ": fill shift " + shiftText + ", chroma " + chromaText + "; bar shift to its level color " + barText + ", to the other level " + otherText)
            values[key + ".fillShift"] = (fillShift * 10).rounded() / 10
            values[key + ".fillChroma"] = (fillChroma * 10).rounded() / 10
            values[key + ".barShift"] = (barShift * 10).rounded() / 10
            if fillShift > 20 { problems.append(key + ": the fill differs from the panel color by " + shiftText + ", limit 20") }
            if fillChroma > 4 { problems.append(key + ": the fill has a hue (chroma " + chromaText + ", limit 4)") }
            if barShift > 30 { problems.append(key + ": the left bar is " + barText + " away from the level color, limit 30") }
            if barShift >= otherShift { problems.append(key + ": the left bar is not closer to its own level color") }
        }
        if let item = cardItem, let rect = panelRect("card." + item.rawValue) {
            let region = CGRect(x: rect.minX + 3, y: rect.minY + 30, width: 6, height: Swift.max(4, rect.height - 60))
            if let fill = meanColor(shot, region: region, surface: surface) {
                let chroma = Swift.max(fill.r, fill.g, fill.b) - Swift.min(fill.r, fill.g, fill.b)
                notes.append("first card " + item.rawValue + ": chroma " + String(format: "%.1f", chroma) + " (needs at least 6)")
                values["card.chroma"] = (chroma * 10).rounded() / 10
                if chroma < 6 { problems.append("the first card has no tint (chroma " + String(format: "%.1f", chroma) + ", needs 6)") }
            } else {
                problems.append("no pixels in the first card")
            }
        } else {
            problems.append("no first card frame")
        }
        resetAppearance()
        await sleepMs(200)
        await closeFixture()
        var note = notes.joined(separator: "; ")
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("M22", "浅色折叠问题卡无彩色底，左侧色条表示等级", problems.isEmpty && notes.count == 4, since: t0, note, values)
    }

    /// M20: the bitmap dog inside the real panel. No callback of the dog view while the data does not change, and the pose follows
    /// the data points that a test injects into the panel model (30 s apart on the test clock).
    func stepBitmapPanel() async {
        let t0 = now()
        DogView.useBitmapArt = true
        DogBitmapProbe.simulated = Date()
        defer { DogBitmapProbe.simulated = nil }
        let copyBox = UITestTextBox()
        guard let model = await openFixture(.allGreen, copyBox: copyBox), let hv = hostView else {
            record("M20", "面板里位图比熊随数据点变化", false, since: t0, "the panel did not open")
            return
        }
        await sleepMs(1800)
        DogBitmapProbe.reset()
        await sleepMs(3000)
        let idleBodies = DogBitmapProbe.bodies
        let first = DogBitmapProbe.lastPose

        struct Step {
            var name: String
            var expected: DogArtPose
            var edit: (inout DogInput) -> Void
        }
        let steps: [Step] = [
            Step(name: "cpu 95", expected: .sprint) { $0.cpuPercent = 95 },
            Step(name: "thermal serious", expected: .pant) { $0.thermal = .serious },
            Step(name: "thermal nominal, disk red", expected: .alert) { $0.thermal = .nominal; $0.worstProblem = .disk; $0.worstLevel = .red },
            Step(name: "no problem, cpu 20", expected: .walk) { $0.worstProblem = nil; $0.worstLevel = .green; $0.cpuPercent = 20 },
            Step(name: "collecting", expected: .gray) { $0.isStatic = true; $0.cpuPercent = nil; $0.thermal = nil },
        ]
        var problems = [String]()
        var notes = ["start pose \(first?.rawValue ?? "nil") (fixture cpu 8), idle body evaluations in 3 s: \(idleBodies)"]
        if first != .lie { problems.append("the start pose is \(first?.rawValue ?? "nil"), expected lie") }
        if idleBodies != 0 { problems.append("\(idleBodies) body evaluations in 3 s with unchanged data") }
        var previousShot = capture(hv)
        var changed = 0
        for step in steps {
            DogBitmapProbe.advanceClock(30)
            var data = model.data
            step.edit(&data.dogInput)
            model.replace(data)
            await sleepMs(500)
            let seen = DogBitmapProbe.lastPose
            var differs = "no picture"
            if let current = capture(hv), let before = previousShot, let rect = panelRect("dog") {
                let diff = UITestPixels.compare(before, current, region: rect)
                differs = String(format: "%.3f", diff.fraction)
                if diff.fraction > 0 { changed += 1 } else { problems.append("\(step.name): the dog region did not change") }
                previousShot = current
            }
            notes.append("\(step.name) -> \(seen?.rawValue ?? "nil") (changed pixels \(differs))")
            if seen != step.expected { problems.append("\(step.name): shows \(seen?.rawValue ?? "nil"), expected \(step.expected.rawValue)") }
        }
        await closeFixture()
        var note = notes.joined(separator: "; ")
        if !problems.isEmpty { note += "; failures: " + problems.joined(separator: "; ") }
        record("M20", "面板里位图比熊随数据点变化", problems.isEmpty, since: t0, note,
               ["idleBodies": Double(idleBodies), "steps": Double(steps.count), "pictureChanges": Double(changed)])
    }
}
#endif
