// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A DogInput and a size (docs/DESIGN.md 4, 8.3, 8.4).
// Output: The Bichon view of the status card.
// Pos: The only view that may use TimelineView (docs/DESIGN.md 10.4). I3 calls `DogView(input:size:)`. Owner I2.
//
// Stage 2: a TimelineView(.animation(minimumInterval: 1/24, paused: reduceMotion || isStatic)) drives DogMotor.
// The motor lives in a @State reference object, so it keeps its gait, phase and smoothing across input changes.
// Each frame advances it by the real time since the last frame, at most 0.1 s. The view exists only while the
// status card is open (NSPopover releases its content on close), so a closed card has no frame callbacks.
// Reduce Motion, collecting and stale: the timeline is paused and the dog is the static frame (DESIGN.md 4.7).
// Frame cost (DESIGN.md 4.6): vector drawing of one frame took about 2.3 ms on the CI runner, over the 0.4 ms budget.
// So steady frames (no gait blend, no bubble pop) come from a strip cache: 24 bitmaps per gait loop, drawn on first
// use with the same renderer and reused while the card stays open. Blends, crossfades and pops stay vector.

import SwiftUI

/// Holds the motor of one DogView. A plain reference: changing it never invalidates the view.
final class DogDriver {
    private(set) var motor: DogMotor?
    private var last: Date?
    private var cached: DogFrame?

    /// The frame at `date`. The first call starts the motor from the input (the newest 30 s CPU point, so the dog
    /// shows the right gait at once). A second call with the same date returns the same frame.
    func frame(at date: Date, input: DogInput) -> DogFrame {
        if motor == nil {
            motor = DogMotor(initialCPU: input.cpuPercent)
            last = date
        }
        if let cached, let last, date <= last { return cached }
#if UITEST
        let start = DogFrameProbe.clock()
#endif
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), DogGaitRules.maxFrameStep)
        last = date
        let made = motor!.frame(dt: dt, input: input)
        cached = made
#if UITEST
        lastStepNs = DogFrameProbe.clock() - start
#endif
        return made
    }

#if UITEST
    /// Thread CPU time of the last motor step, ns (the dog checks).
    private(set) var lastStepNs: UInt64 = 0
#endif

    // MARK: Strip cache

    /// Bitmaps per gait loop. 24 keeps the sprint step under the leg speed limit (15 degrees of stride per bitmap).
    static let stripFrames = 24
    /// Strips kept at once (the current look and the one before it). A 104 x 78 pt strip at 2x is about 3.1 MB.
    static let maxStrips = 2

    private struct StripKey: Hashable {
        var gait: DogGait
        var pant: Bool
        var problem: HealthItem?
        var level: HealthLevel
        var memoryRed: Bool
        var dark: Bool
        var width: Int
        var height: Int
    }

    private var strips = [StripKey: [Int: CGImage]]()
    private var stripOrder = [StripKey]()

    /// The cached bitmap of a steady frame and the pose it shows, or nil (draw vector). `size` is the dog box in points.
    func stripImage(_ frame: DogFrame, input: DogInput, dark: Bool, size: CGSize, scale: CGFloat) -> (image: CGImage, pose: DogPose)? {
        guard let loop = frame.loop, frame.fadeFrom == nil else { return nil }
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        let attention = input.worstProblem != nil && (input.worstLevel == .yellow || input.worstLevel == .red)
        let key = StripKey(gait: frame.gait, pant: input.thermal == .serious || input.thermal == .critical,
                           problem: attention ? input.worstProblem : nil, level: attention ? input.worstLevel : .green,
                           memoryRed: input.memoryLevel == .red, dark: dark, width: w, height: h)
        let n = DogDriver.stripFrames
        let index = Int((loop * Double(n)).rounded()) % n
        let pose = DogMotor.loopPose(gait: frame.gait, loop: Double(index) / Double(n), input: input)
        if let hit = strips[key]?[index] { return (hit, pose) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        DogRenderer.drawFrame(DogFrame(gait: frame.gait, pose: pose), input: input, dark: dark,
                              in: CGRect(origin: .zero, size: size), ctx: ctx)
        guard let image = ctx.makeImage() else { return nil }
        if strips[key] == nil {
            stripOrder.append(key)
            if stripOrder.count > DogDriver.maxStrips { strips[stripOrder.removeFirst()] = nil }
        }
        strips[key, default: [:]][index] = image
        return (image, pose)
    }

    /// Bitmaps held now (the dog checks).
    var stripBitmapCount: Int { strips.values.reduce(0) { $0 + $1.count } }

    /// The gait to show in a paused (static) view: the motor's gait if it ran, else the gait of the input.
    func staticGait(_ input: DogInput) -> DogGait {
        if input.isStatic { return .stand }
        return motor?.gait ?? DogMotor.staticGait(for: input)
    }
}

struct DogView: View {
    var input: DogInput
    var size: CGSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var driver = DogDriver()

    init(input: DogInput, size: CGSize) {
        self.input = input
        self.size = size
    }

    private var reduceMotion: Bool {
#if UITEST
        if let forced = DogFrameProbe.forceReduceMotion { return forced }
#endif
        return systemReduceMotion
    }

    var body: some View {
        let input = self.input
        let dark = (colorScheme == .dark)
        let still = reduceMotion || input.isStatic
        let driver = self.driver
        let scale = max(1, displayScale)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still)) { timeline in
            if still {
                let gait = driver.staticGait(input)
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        DogRenderer.drawStatic(input, gait: gait, dark: dark, in: DogView.fit(canvasSize), ctx: cg)
                    }
                }
            } else {
                let frame = driver.frame(at: timeline.date, input: input)
                let date = timeline.date
                Canvas { context, canvasSize in
#if UITEST
                    let drawStart = DogFrameProbe.clock()
#endif
                    let box = DogView.fit(canvasSize)
                    let strip = driver.stripImage(frame, input: input, dark: dark, size: box.size, scale: scale)
                    if let strip {
                        context.draw(Image(decorative: strip.image, scale: scale), in: box)
                    } else {
                        context.withCGContext { cg in
                            DogRenderer.drawFrame(frame, input: input, dark: dark, in: box, ctx: cg)
                        }
                    }
#if UITEST
                    DogFrameProbe.record(date: date, frame: frame, drawnLegs: strip?.pose.legAngle ?? frame.pose.legAngle,
                                         cached: strip != nil, stepNs: driver.lastStepNs,
                                         drawNs: DogFrameProbe.clock() - drawStart, bitmaps: driver.stripBitmapCount)
#endif
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel(Text(DogView.label(input)))
    }

    /// The 4:3 design box, fitted and centered in the view.
    static func fit(_ s: CGSize) -> CGRect {
        let k = min(s.width / CGFloat(DogArt.designSize.w), s.height / CGFloat(DogArt.designSize.h))
        let w = CGFloat(DogArt.designSize.w) * k, h = CGFloat(DogArt.designSize.h) * k
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }

    /// VoiceOver text: what the dog does, in Chinese.
    static func label(_ input: DogInput) -> String {
        if input.isStatic { return "比熊：正在统计" }
        var parts = [String]()
        switch DogMotor.staticGait(for: input) {
        case .lie: parts.append("比熊趴着休息")
        case .stand: parts.append("比熊站着")
        case .walk: parts.append("比熊在走")
        case .trot: parts.append("比熊在小跑")
        case .sprint: parts.append("比熊在冲刺")
        }
        if input.thermal == .serious || input.thermal == .critical { parts.append("热得喘气") }
        if let item = input.worstProblem, input.worstLevel == .yellow || input.worstLevel == .red {
            parts.append("在留意" + item.label)
        }
        return parts.joined(separator: "，")
    }
}
