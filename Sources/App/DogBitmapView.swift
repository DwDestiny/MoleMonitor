// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A DogInput and a size (docs/DESIGN.md 4.9). The eight bitmaps of Resources/DogArt, copied to Contents/Resources/DogArt by scripts/build.py.
// Output: The bitmap Bichon of the status card: one still picture per pose, a 0.22 s crossfade when the pose changes,
//         and the vector attention bubble on the alert picture.
// Pos: Replaces the vector dog in the card (DogView routes here while `DogView.useBitmapArt` is true and all eight files load).
//      No TimelineView, no Canvas, no timer, no frame callback: the view draws only when its input changes, so a card that
//      stays open with the same data costs nothing. The vector dog (DogView, DogShapes) stays as the fallback.

import AppKit
import ImageIO
import SwiftUI

// MARK: - Library

/// The eight bitmaps, decoded once, plus the scaled copies and the bubble pictures that the card needs.
/// All of it is cached for the life of the process (about 3 MB); nothing in it runs or ticks.
final class DogArtLibrary {
    static let shared = DogArtLibrary(directory: DogArtLibrary.bundleDirectory)

    /// `Contents/Resources/DogArt` of the app bundle, or nil outside a bundle.
    static var bundleDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("DogArt", isDirectory: true)
    }

    private struct ScaledKey: Hashable {
        var pose: DogArtPose
        var width: Int
        var height: Int
    }

    private struct BubbleKey: Hashable {
        var item: HealthItem
        var level: HealthLevel
        var dark: Bool
        var width: Int
        var height: Int
    }

    private let lock = NSLock()
    private var originals = [DogArtPose: CGImage]()
    private var scaled = [ScaledKey: CGImage]()
    private var bubbles = [BubbleKey: CGImage]()
    private(set) var missing = [DogArtPose]()

    init(directory: URL?) {
        for pose in DogArtPose.allCases {
            guard let directory,
                  let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(pose.fileName + ".png") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else {
                missing.append(pose)
                continue
            }
            originals[pose] = image
        }
    }

    /// True when all eight bitmaps loaded.
    var isComplete: Bool { missing.isEmpty }

    /// The decoded file, 320 x 240 px.
    func original(_ pose: DogArtPose) -> CGImage? { originals[pose] }

    /// The picture of a pose at an exact pixel size (high quality resample, cached).
    func image(_ pose: DogArtPose, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let source = originals[pose] else { return nil }
        let key = ScaledKey(pose: pose, width: width, height: height)
        lock.lock()
        defer { lock.unlock() }
        if let hit = scaled[key] { return hit }
        guard let image = DogArtLibrary.resample(source, width: width, height: height) else { return nil }
        scaled[key] = image
        return image
    }

    static func resample(_ source: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// The vector attention bubble (circle, tail dot, problem glyph) alone, over the whole 4:3 box of the dog, transparent elsewhere.
    func bubble(item: HealthItem, level: HealthLevel, dark: Bool, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let key = BubbleKey(item: item, level: level, dark: dark, width: width, height: height)
        lock.lock()
        defer { lock.unlock() }
        if let hit = bubbles[key] { return hit }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / CGFloat(DogArt.designSize.w), y: -CGFloat(height) / CGFloat(DogArt.designSize.h))
        let layers = DogRig.bubbleLayers(glyph: DogArt.badge(item), scale: 1)
        DogRenderer.draw(layers, opacity: 1, palette: DogPalette(dark: dark), level: level, in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        bubbles[key] = image
        return image
    }
}

// MARK: - Driver

/// The smoothing state of one DogBitmapView. A plain reference: changing it never invalidates the view.
final class DogArtDriver {
    var selector: DogArtSelector
    var last: Date

    init(initial input: DogInput) {
        selector = DogArtSelector(initial: input)
        last = DogArtDriver.now()
    }

    /// The clock of the selector steps. The UI tests replace it to deliver data points 30 s apart quickly.
    static func now() -> Date {
#if UITEST
        return DogBitmapProbe.now()
#else
        return Date()
#endif
    }
}

// MARK: - View

struct DogBitmapView: View {
    var input: DogInput
    var size: CGSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.panelSnapshot) private var snapshot

    /// The crossfade works with two slots. Slot A is always drawn. Slot B is drawn above it and fades in or out.
    /// A new pose goes to the hidden slot, then B's opacity flips: one state change, one animation, no alpha dip.
    @State private var driver: DogArtDriver
    @State private var slotA: DogArtPose
    @State private var slotB: DogArtPose
    @State private var showB = false

    /// The crossfade (docs/DESIGN.md 5.1: easeInOut, 0.20 to 0.25 s).
    static let fadeSeconds = 0.22
    /// A soft ground shadow under the picture (the existing `shadow` token). Off unless the contrast needs it.
    static var groundShadow = false

    init(input: DogInput, size: CGSize) {
        self.input = input
        self.size = size
        let made = DogArtDriver(initial: input)
        _driver = State(initialValue: made)
        _slotA = State(initialValue: made.selector.pose)
        _slotB = State(initialValue: made.selector.pose)
    }

    private var reduceMotion: Bool {
#if UITEST
        if let forced = DogFrameProbe.forceReduceMotion { return forced }
#endif
        return systemReduceMotion
    }

    private var target: DogArtPose { showB ? slotB : slotA }

    /// Pixel scale of the pictures. A snapshot (ImageRenderer) renders at 2x whatever the environment says.
    private var pixelScale: CGFloat { max(1, snapshot ? max(2, displayScale) : displayScale) }

    var body: some View {
        let _ = probeBody()
        let dark = (colorScheme == .dark)
        let box = DogView.fit(size).size
        let fade: Animation? = (reduceMotion || snapshot) ? nil : Animation.easeInOut(duration: DogBitmapView.fadeSeconds)
        ZStack {
            if DogBitmapView.groundShadow, let shade = DogBitmapView.shadowColor(dark: dark) {
                DogBitmapView.shadowShape(box: box).fill(shade)
            }
            poseImage(slotA, box: box)
            poseImage(slotB, box: box)
                .opacity(showB ? 1 : 0)
                .animation(fade, value: showB)
            if target == .alert, let item = input.worstProblem {
                DogBubble(item: item, level: input.worstLevel, dark: dark, box: box, scale: pixelScale, reduceMotion: reduceMotion)
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: input) { _, next in advance(to: next) }
        .accessibilityElement()
        .accessibilityLabel(Text(DogBitmapView.label(target, input)))
    }

    private func poseImage(_ pose: DogArtPose, box: CGSize) -> some View {
        let w = Int((box.width * pixelScale).rounded()), h = Int((box.height * pixelScale).rounded())
        return Group {
            if let image = DogArtLibrary.shared.image(pose, width: w, height: h) {
                Image(decorative: image, scale: pixelScale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: box.width, height: box.height)
                    // While the bubble shows, the dog shrinks about a ground point at the tail side (DESIGN.md 4.4).
                    .scaleEffect(pose == .alert ? CGFloat(DogArt.bubbleShrink) : CGFloat(1),
                                 anchor: UnitPoint(x: CGFloat(DogArt.bubbleShrinkAnchor.x / DogArt.designSize.w),
                                                   y: CGFloat(DogArt.bubbleShrinkAnchor.y / DogArt.designSize.h)))
            } else {
                Color.clear.frame(width: box.width, height: box.height)
            }
        }
    }

    /// One new data point: smooth, pick the bitmap, and switch when it differs.
    private func advance(to next: DogInput) {
        let now = DogArtDriver.now()
        let dt = now.timeIntervalSince(driver.last)
        driver.last = now
        let pose = driver.selector.advance(dt: dt, input: next)
        guard pose != target else { return }
        if showB { slotA = pose } else { slotB = pose }
        showB.toggle()
#if UITEST
        DogBitmapProbe.switched(to: pose, animated: !(reduceMotion || snapshot))
#endif
    }

    private func probeBody() {
#if UITEST
        DogBitmapProbe.bodyEvaluated(pose: target)
#endif
    }

    /// VoiceOver text: what the dog does, in Chinese.
    static func label(_ pose: DogArtPose, _ input: DogInput) -> String {
        switch pose {
        case .gray: return "比熊：正在统计"
        case .lie: return "比熊趴着休息"
        case .stand: return "比熊站着"
        case .walk: return "比熊在走"
        case .trot: return "比熊在小跑"
        case .sprint: return "比熊在冲刺"
        case .pant: return "比熊热得喘气"
        case .alert: return "比熊在留意" + (input.worstProblem?.label ?? "问题")
        }
    }

    // MARK: Ground shadow

    /// The `shadow` role of the dog palette (black 10 % in light, 35 % in dark).
    static func shadowColor(dark: Bool) -> Color? {
        Color(cgColor: DogPalette(dark: dark).color(.shadow))
    }

    /// The ellipse of DESIGN.md 4.2 (center (54, 83), rx 34, ry 3.5 in a 120 x 90 box), scaled to `box`.
    static func shadowShape(box: CGSize) -> some Shape {
        let kx = box.width / CGFloat(DogArt.designSize.w), ky = box.height / CGFloat(DogArt.designSize.h)
        return Ellipse()
            .path(in: CGRect(x: (54 - 34) * kx, y: (83 - 3.5) * ky, width: 68 * kx, height: 7 * ky))
    }
}

/// The attention bubble over the alert picture. It pops once when it appears (scale 0.6 to 1, DESIGN.md 5.3).
private struct DogBubble: View {
    let item: HealthItem
    let level: HealthLevel
    let dark: Bool
    let box: CGSize
    let scale: CGFloat
    let reduceMotion: Bool
    @Environment(\.panelSnapshot) private var snapshot
    @State private var appeared = false

    var body: some View {
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        let settled = appeared || reduceMotion || snapshot
        let pop: Animation? = (reduceMotion || snapshot) ? nil : Animation.spring(response: 0.40, dampingFraction: 0.78)
        if let image = DogArtLibrary.shared.bubble(item: item, level: level, dark: dark, width: w, height: h) {
            Image(decorative: image, scale: scale)
                .resizable()
                .interpolation(.high)
                .frame(width: box.width, height: box.height)
                .scaleEffect(settled ? CGFloat(1) : CGFloat(0.6),
                             anchor: UnitPoint(x: CGFloat(DogArt.bubbleCircle.x / DogArt.designSize.w),
                                               y: CGFloat(DogArt.bubbleCircle.y / DogArt.designSize.h)))
                .animation(pop, value: settled)
                .onAppear { appeared = true }
        }
    }
}
