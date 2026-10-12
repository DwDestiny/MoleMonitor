// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: DogSpriteState (the DogStagePlan of DogDirector, a one-shot request, a heart burst, Reduce Motion, appearance, scale)
//        and Resources/DogSprites (manifest.json, 9 strips, sit_gray, 2 bed props), copied to Contents/Resources/DogSprites by build.py.
// Output: DogSpriteNSView, the moving parts of the hero stage (docs/DESIGN_V2.md 4.2 to 4.9, 11.1 to 11.6): the strip of the action,
//         the ground texture, the ground shadow, the sweat drops, the "z" and the hearts. DogSpriteLibrary decodes and caches the strips
//         (LRU, at most 8 MB, empty when the last view goes). DogStageGeometry holds the stage numbers that the view and the gates share.
// Pos: The only AppKit view of the hero (PanelHero.swift hosts it through DogSpriteRepresentable). Core Animation plays every frame:
//      a discrete CAKeyframeAnimation on contentsRect, the layer speed for the step rate (phase kept with convertTime), CATransition
//      for the fades and CAAnimationDelegate for the hand-over between actions. No Timer, no TimelineView, no CADisplayLink,
//      no DispatchSource timer, and no draw callback: the main thread does nothing per frame (11.2, W14).
//      A one-shot asyncAfter guard repeats the hand-over only if animationDidStop did not come (the probe counts it).
//      The strips face left (manifest "facing"). The dog walks to the left, so the ground texture moves to the right: physics first
//      (coordinator decision 2026-10-12; DESIGN_V2.md 4.2 still says "向左平移" until WP-F corrects it).
//      Fallback chain (11.6): level 1, a missing strip shows the mirrored still bitmap of Resources/DogArt with a procedural bob;
//      level 2, no usable manifest shows level 1 for every action; level 3 (no bitmaps or DogView.useBitmapArt false) is the
//      vector dog, which PanelHero shows instead of this view.

import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Manifest

/// Resources/DogSprites/manifest.json (schema 1). Frame sizes are pixels at 2x.
struct DogSpriteManifest: Decodable {
    struct Action: Decodable {
        var name: String
        var file: String
        var frames: Int
        var fps: Double
        var playback: String
        var restFrame: Int
        var representativeFrame: Int
        var contactFrames: [Int]
        var repeatCount: Int?
        var holdLastSeconds: Double?
        /// [x0, y0, x1, y1] in pixels of the rest frame, x1 and y1 exclusive.
        var restInkBox: [Double]?
        /// One [x, y, w, h] per frame: the box of the eyes and the nose.
        var faceBoxes: [[Double]]?

        enum CodingKeys: String, CodingKey {
            case name, file, frames, fps, playback, restFrame, representativeFrame, contactFrames
            case repeatCount = "repeat"
            case holdLastSeconds, restInkBox, faceBoxes
        }

        var loops: Bool { playback == "loop" }
    }

    struct Prop: Decodable {
        var name: String
        var file: String
        var width: Double
        var height: Double
        var baseLineY: Double
    }

    var schema: Int
    var frameWidth: Double
    var frameHeight: Double
    var pointScale: Double
    var footLineY: Double
    var facing: String
    var actions: [Action]
    var props: [Prop]?

    func action(_ a: DogAction) -> Action? { actions.first { $0.name == a.rawValue } }
    func prop(_ bed: DogBed) -> Prop? { props?.first { $0.name == bed.rawValue } }

    /// Total frames of the first-release actions.
    var frameCount: Int { actions.reduce(0) { $0 + $1.frames } }
}

// MARK: - Stage geometry

/// Stage numbers in points, origin at the top left of the 320 x 152 stage, y downwards (DESIGN_V2.md 4.2).
/// Changes against 4.2 (reported to the coordinator for F2): the dog box starts at x 172 (not 144), the bubble is at most 184 pt wide
/// (not 192) and has 8 pt vertical padding (not 10), so the bubble box with its tail keeps 4 pt from every frame of all 10 actions.
enum DogStageGeometry {
    static let size = CGSize(width: 320, height: 152)
    static let cornerRadius: CGFloat = 12
    static let dogBox = CGRect(x: 172, y: 26, width: 160, height: 120)
    /// Pixels per point of the strips.
    static let pixelScale: CGFloat = 2
    /// The foot line of the strips (230 px) on the stage.
    static let footY: CGFloat = 141
    static let groundY: CGFloat = 141
    static let textureY: CGFloat = 145
    static let texturePeriod: CGFloat = 48

    static let bubbleOrigin = CGPoint(x: 12, y: 12)
    static let bubbleMaxWidth: CGFloat = 184
    static let bubblePadX: CGFloat = 10
    static let bubblePadY: CGFloat = 8
    static let bubbleLine: CGFloat = 18
    static let bubbleFont: CGFloat = 13
    static let tailSize = CGSize(width: 8, height: 6)
    /// The tail tip stays this far left of the right edge of the bubble, so the bubble box keeps its width.
    static let tailInset: CGFloat = 8
    /// The subline starts at this x and sits 2 pt below the bubble tail (it follows the bubble height).
    static let subX: CGFloat = 16
    static let subFont: CGFloat = 11

    /// Bed prop: 192 x 112 px with its base line at 108 px, so it stands on the ground line.
    static let bedRect = CGRect(x: 16, y: 87, width: 96, height: 56)
    static let moonRect = CGRect(x: 284, y: 14, width: 14, height: 14)
    static let stars: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [(238, 12, 2.5), (262, 30, 2), (306, 36, 2)]

    /// A pixel of the strip frame to a stage point.
    static func stagePoint(px x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: dogBox.minX + CGFloat(x) / pixelScale, y: dogBox.minY + CGFloat(y) / pixelScale)
    }

    /// The ground shadow of an action, in pixels of its frame (DESIGN_V2.md 4.2, gate BF): the center under the middle of the rest frame
    /// ink on the foot line, 0.75 of the ink width (sprint 0.55 and lighter, because the paws leave the ground).
    struct Shadow: Equatable {
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
        var opacity: Double
    }

    static func shadow(_ action: DogAction, ink: [Double]?) -> Shadow {
        let box = (ink?.count == 4 ? ink! : [70, 40, 250, 231])
        let sprint = action == .sprint
        let width = (box[2] - box[0]) * (sprint ? 0.55 : 0.75)
        return Shadow(centerX: (box[0] + box[2]) / 2, centerY: box[3] - 1, width: width, height: sprint ? 9 : 12,
                      opacity: sprint ? 0.55 : 1)
    }

    /// Head point of an action (top middle of the face box of the rest frame), in stage points. Hearts, drops and the "z" start here.
    static func head(_ action: DogAction, manifest: DogSpriteManifest?) -> CGPoint {
        if let a = manifest?.action(action), let boxes = a.faceBoxes, a.restFrame < boxes.count, boxes[a.restFrame].count == 4 {
            let f = boxes[a.restFrame]
            return stagePoint(px: f[0] + f[2] / 2, f[1] - 14)
        }
        return CGPoint(x: dogBox.minX + 60, y: dogBox.minY + 30)
    }

    /// Top of the fur above the face of an action (middle of the face box, top of the rest frame ink), in stage points.
    /// The "z" and the hearts start here, so they never sit on the white fur, where a light mark would vanish.
    static func crown(_ action: DogAction, manifest: DogSpriteManifest?) -> CGPoint {
        if let a = manifest?.action(action), let boxes = a.faceBoxes, a.restFrame < boxes.count, boxes[a.restFrame].count == 4,
           let ink = a.restInkBox, ink.count == 4 {
            let f = boxes[a.restFrame]
            return stagePoint(px: f[0] + f[2] / 2, ink[1])
        }
        return CGPoint(x: dogBox.minX + 60, y: dogBox.minY + 20)
    }
}

// MARK: - Library

/// Decodes the strips and keeps the decoded ones in a small LRU cache (DESIGN_V2.md 11.3). Thread safe.
/// The current action decodes synchronously on first use; the likely next actions decode on a background queue.
/// `attach` and `detach` count the live views. When the last view goes, the cache drops everything (W16: 0 bytes after close).
final class DogSpriteLibrary: @unchecked Sendable {
    static let shared = DogSpriteLibrary(directory: Bundle.main.resourceURL?.appendingPathComponent("DogSprites", isDirectory: true))
    static let budgetBytes = 8 * 1024 * 1024

    let directory: URL?
    let manifest: DogSpriteManifest?

    private let lock = NSLock()
    private var strips = [DogAction: CGImage]()
    private var order = [DogAction]()          // least recently used first
    private var failed = Set<DogAction>()
    private var pinned = Set<DogAction>()
    private var props = [DogBed: CGImage]()
    private var stills = [DogAction: CGImage]()
    private var loading = Set<DogAction>()
    private var clients = 0
    private let queue = DispatchQueue(label: "molemonitor.sprites", qos: .userInitiated)

    init(directory: URL?) {
        self.directory = directory
        var loaded: DogSpriteManifest?
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let m = try? JSONDecoder().decode(DogSpriteManifest.self, from: data), m.schema == 1, !m.actions.isEmpty {
            loaded = m
        }
        manifest = loaded
    }

    /// Level 2 of 11.6 when false.
    var hasManifest: Bool { manifest != nil }

    func attach() {
        lock.lock()
        clients += 1
        lock.unlock()
    }

    func detach() {
        lock.lock()
        clients = max(0, clients - 1)
        if clients == 0 {
            strips.removeAll()
            order.removeAll()
            pinned.removeAll()
            props.removeAll()
            stills.removeAll()
        }
        lock.unlock()
    }

    /// Decoded bytes held now (strips, props and the still fallbacks).
    var cachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(strips.values) + Array(props.values) + Array(stills.values)
        return all.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// The actions that a view shows or is about to show. They are never evicted.
    func pin(_ actions: Set<DogAction>) {
        lock.lock()
        pinned = actions
        lock.unlock()
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The decoded strip of an action, or nil (missing file, bad size: level 1 of 11.6). Decodes on the caller's thread when needed.
    func strip(_ action: DogAction) -> CGImage? {
        lock.lock()
        if let hit = strips[action] {
            touch(action)
            lock.unlock()
            return hit
        }
        let known = failed.contains(action)
        lock.unlock()
        if known { return nil }
        guard let entry = manifest?.action(action), let directory else { return nil }
        guard let image = Self.decode(directory.appendingPathComponent(entry.file)),
              image.height == Int(manifest?.frameHeight ?? 240),
              image.width == Int(manifest?.frameWidth ?? 320) * entry.frames else {
            lock.lock()
            failed.insert(action)
            lock.unlock()
            return nil
        }
        insert(action, image)
        return image
    }

    /// Decodes these strips on a background queue, if they are not in the cache.
    func prefetch(_ actions: [DogAction]) {
        guard let manifest, let directory else { return }
        for action in actions {
            lock.lock()
            let skip = strips[action] != nil || failed.contains(action) || loading.contains(action) || clients == 0
            if !skip { loading.insert(action) }
            lock.unlock()
            guard !skip, let entry = manifest.action(action) else { continue }
            let url = directory.appendingPathComponent(entry.file)
            let frames = entry.frames
            queue.async { [weak self] in
                let image = Self.decode(url)
                guard let self else { return }
                self.lock.lock()
                self.loading.remove(action)
                let alive = self.clients > 0
                self.lock.unlock()
                if let image, alive, image.width == Int(manifest.frameWidth) * frames { self.insert(action, image) }
            }
        }
    }

    private func touch(_ action: DogAction) {
        order.removeAll { $0 == action }
        order.append(action)
    }

    /// Adds a decoded strip and keeps the whole cache (strips, props, stills) within the budget. The least recently used strip that
    /// is not pinned goes first; the new strip is the most recent, so a prefetch that does not fit drops itself, never a pinned strip.
    private func insert(_ action: DogAction, _ image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        strips[action] = image
        touch(action)
        let extra = (Array(props.values) + Array(stills.values)).reduce(0) { $0 + $1.bytesPerRow * $1.height }
        var bytes = extra + strips.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        var index = 0
        while bytes > Self.budgetBytes, index < order.count {
            let victim = order[index]
            if pinned.contains(victim) {
                index += 1
                continue
            }
            if let gone = strips.removeValue(forKey: victim) { bytes -= gone.bytesPerRow * gone.height }
            order.remove(at: index)
        }
    }

    /// One frame of a strip as its own image (snapshot mode and the gates).
    func frame(_ action: DogAction, _ index: Int) -> CGImage? {
        guard let entry = manifest?.action(action), let image = strip(action) else { return nil }
        let w = image.width / max(1, entry.frames)
        let i = min(max(0, index), entry.frames - 1)
        return image.cropping(to: CGRect(x: i * w, y: 0, width: w, height: image.height))
    }

    func restFrame(_ action: DogAction) -> CGImage? {
        frame(action, manifest?.action(action)?.restFrame ?? 0)
    }

    func prop(_ bed: DogBed) -> CGImage? {
        lock.lock()
        if let hit = props[bed] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let entry = manifest?.prop(bed), let directory, let image = Self.decode(directory.appendingPathComponent(entry.file)) else { return nil }
        lock.lock()
        props[bed] = image
        lock.unlock()
        return image
    }

    /// The still bitmap of Resources/DogArt that stands in for an action (level 1 and 2 of 11.6), mirrored to face left.
    func still(_ action: DogAction) -> CGImage? {
        lock.lock()
        if let hit = stills[action] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let source = DogArtLibrary.shared.original(Self.pose(for: action)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                  bytesPerRow: source.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(source.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let mirrored = ctx.makeImage() else { return nil }
        lock.lock()
        stills[action] = mirrored
        lock.unlock()
        return mirrored
    }

    /// The closest of the eight still poses (11.6 level 1).
    static func pose(for action: DogAction) -> DogArtPose {
        switch action {
        case .lieIdle: return .lie
        case .walk: return .walk
        case .trot: return .trot
        case .sprint: return .sprint
        case .sniff, .standUp, .wag: return .stand
        case .sitGray: return .gray
        case .pantLie: return .pant
        case .notice: return .alert
        }
    }

    /// The strips that the next transitions most likely need (11.3: the neighbor gait or stand_up).
    static func likelyNext(_ action: DogAction) -> [DogAction] {
        switch action {
        case .lieIdle: return [.standUp, .walk]
        case .walk: return [.trot, .standUp]
        case .trot: return [.walk, .sprint]
        case .sprint: return [.trot]
        case .pantLie: return [.standUp]
        case .sniff: return [.lieIdle]
        default: return []
        }
    }
}

// MARK: - State from SwiftUI

/// A one-shot action that the hero asks for (wag or notice). A new id plays it again.
struct HeroOneShot: Equatable {
    var action: DogAction
    var repeats: Int
    var id: Int
}

/// Hearts that rise from the head after a tap (3) or a long press (5).
struct HeartBurst: Equatable {
    var count: Int
    var id: Int
}

struct DogSpriteState: Equatable {
    var plan: DogStagePlan
    var oneShot: HeroOneShot?
    var hearts: HeartBurst?
    var reduceMotion: Bool
    var dark: Bool
    /// Stage scale: 1 in the v2 layout (320 x 152 pt). COMPAT: smaller while the v1 layout gives the hero less room.
    var scale: CGFloat
}

// MARK: - Hosting

struct DogSpriteRepresentable: NSViewRepresentable {
    var state: DogSpriteState
    var onTap: () -> Void
    var onLongPress: () -> Void

    func makeNSView(context: Context) -> DogSpriteNSView {
        let view = DogSpriteNSView(frame: NSRect(x: 0, y: 0, width: DogStageGeometry.size.width * state.scale,
                                                 height: DogStageGeometry.size.height * state.scale))
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.apply(state)
        return view
    }

    func updateNSView(_ view: DogSpriteNSView, context: Context) {
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.apply(state)
    }

    static func dismantleNSView(_ view: DogSpriteNSView, coordinator: ()) {
        view.shutdown()
    }
}

/// Receives the stop of the marker animations. CAAnimation keeps its delegate strongly, so the relay holds the view weakly.
private final class DogAnimationRelay: NSObject, CAAnimationDelegate {
    weak var view: DogSpriteNSView?

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let generation = (anim.value(forKey: "moleGeneration") as? Int) ?? -1
        MainActor.assumeIsolated {
            view?.markerStopped(generation: generation, finished: flag, fromGuard: false)
        }
    }
}

// MARK: - View

final class DogSpriteNSView: NSView {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    private let library = DogSpriteLibrary.shared
    private var state: DogSpriteState?
    private var attached = false

    // Layers. The stage layer is 320 x 152 pt and y up; `y(_:_:)` turns the top-down numbers of DogStageGeometry into it.
    private let stage = CALayer()
    private let ground = CALayer()
    private let shadowLayer = CAGradientLayer()
    private let body = CALayer()
    private let frameLayer = CALayer()
    private let sweat = CALayer()
    private let zLayer = CALayer()
    private var hearts = [CALayer]()
    private let marker = CALayer()
    private let relay = DogAnimationRelay()

    // What the screen shows.
    private var screen: DogAction?
    private var screenVariant: DogVariant = .normal
    private var screenUsesStrip = false
    private var currentImage: CGImage?
    private var loopStart: CFTimeInterval = 0
    private var loopDuration: CFTimeInterval = 1
    private var loopFrames = 1
    private var busy = false
    private var generation = 0
    private var pending: (() -> Void)?
    private var pendingOneShot: HeroOneShot?
    private var lastOneShotID: Int?
    private var lastHeartsID: Int?
    private var press: (time: CFTimeInterval, point: NSPoint)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        relay.view = self
        buildLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("DogSpriteNSView has no coder")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
#if UITEST
        DogSpriteProbe.updateLayers += 1
#endif
    }

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layers

    private func y(_ top: CGFloat, _ height: CGFloat) -> CGFloat { DogStageGeometry.size.height - top - height }

    private func buildLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false
        stage.anchorPoint = .zero
        stage.bounds = CGRect(origin: .zero, size: DogStageGeometry.size)
        stage.masksToBounds = true
        stage.cornerRadius = DogStageGeometry.cornerRadius
        root.addSublayer(stage)
        for l in [ground, shadowLayer, body, sweat, zLayer, marker] { stage.addSublayer(l) }
        for (l, name) in [(stage, "stage"), (ground, "ground"), (shadowLayer, "shadow"), (body, "body"), (frameLayer, "frame"),
                          (sweat, "sweat"), (zLayer, "z"), (marker, "marker")] { l.name = name }
        body.addSublayer(frameLayer)

        let size = DogStageGeometry.size
        ground.anchorPoint = .zero
        ground.frame = CGRect(x: -DogStageGeometry.texturePeriod, y: y(DogStageGeometry.textureY, 2),
                              width: size.width + DogStageGeometry.texturePeriod * 2, height: 2)

        shadowLayer.type = .radial
        shadowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.endPoint = CGPoint(x: 1, y: 1)

        let box = DogStageGeometry.dogBox
        body.bounds = CGRect(origin: .zero, size: box.size)
        // The anchor is the foot line, so the sink and the vertical scale keep the paws in place.
        body.anchorPoint = CGPoint(x: 0.5, y: (box.maxY - DogStageGeometry.footY) / box.height)
        body.position = CGPoint(x: box.midX, y: y(DogStageGeometry.footY, 0))
        frameLayer.frame = body.bounds
        frameLayer.contentsGravity = .resize
        frameLayer.contentsScale = DogStageGeometry.pixelScale
        frameLayer.minificationFilter = .linear
        frameLayer.magnificationFilter = .linear

        marker.frame = .zero
        marker.opacity = 0
        sweat.frame = stage.bounds
        zLayer.contentsScale = 2
        for _ in 0..<5 {
            let heart = CALayer()
            heart.opacity = 0
            heart.contentsScale = 2
            stage.addSublayer(heart)
            hearts.append(heart)
        }
    }

    private func layoutStage(scale: CGFloat) {
        stage.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        stage.position = CGPoint(x: 0, y: bounds.height - DogStageGeometry.size.height * scale)
    }

    override func layout() {
        super.layout()
        noActions { layoutStage(scale: state?.scale ?? 1) }
    }

    private func noActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    /// Images of the small procedural parts, drawn once per appearance at 2x.
    private func drawImage(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        draw(ctx)
        return ctx.makeImage()
    }

    private func renderParts(dark: Bool) {
        let width = DogStageGeometry.size.width + DogStageGeometry.texturePeriod * 2
        ground.contents = drawImage(CGSize(width: width, height: 2)) { ctx in
            ctx.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.10 : 0.09))
            var x: CGFloat = 0
            while x < width {
                ctx.fill(CGRect(x: x, y: 0.5, width: 10, height: 1))
                ctx.fill(CGRect(x: x + 26, y: 0.5, width: 4, height: 1))
                x += DogStageGeometry.texturePeriod
            }
        }
        ground.contentsScale = 2
        let shade = CGColor(gray: 0, alpha: dark ? 0.40 : 0.13)
        shadowLayer.colors = [shade, CGColor(gray: 0, alpha: 0)]
        shadowLayer.locations = [0, 1]

        let drop = drawImage(CGSize(width: 5, height: 7)) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 2.5, y: 7))
            path.addCurve(to: CGPoint(x: 2.5, y: 0.2), control1: CGPoint(x: 0.6, y: 4.2), control2: CGPoint(x: -0.6, y: 0.2))
            path.addCurve(to: CGPoint(x: 2.5, y: 7), control1: CGPoint(x: 5.6, y: 0.2), control2: CGPoint(x: 4.4, y: 4.2))
            ctx.addPath(path)
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.55, green: 0.78, blue: 1, alpha: 0.95) : CGColor(srgbRed: 0.30, green: 0.62, blue: 0.90, alpha: 0.9))
            ctx.fillPath()
        }
        if sweat.sublayers?.count != 2 {
            sweat.sublayers?.forEach { $0.removeFromSuperlayer() }
            for _ in 0..<2 {
                let d = CALayer()
                d.contentsScale = 2
                sweat.addSublayer(d)
            }
        }
        sweat.sublayers?.forEach { $0.contents = drop }

        let heart = drawImage(CGSize(width: 10, height: 9)) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 5, y: 0.6))
            path.addCurve(to: CGPoint(x: 0.4, y: 6), control1: CGPoint(x: 2.4, y: 2.6), control2: CGPoint(x: 0.4, y: 3.8))
            path.addArc(center: CGPoint(x: 2.75, y: 6.2), radius: 2.35, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addArc(center: CGPoint(x: 7.25, y: 6.2), radius: 2.35, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(to: CGPoint(x: 5, y: 0.6), control1: CGPoint(x: 9.6, y: 3.8), control2: CGPoint(x: 7.6, y: 2.6))
            ctx.addPath(path)
            ctx.setFillColor(dark ? CGColor(srgbRed: 1, green: 0.48, blue: 0.58, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.33, blue: 0.45, alpha: 1))
            ctx.fillPath()
        }
        for h in hearts {
            h.contents = heart
            h.bounds = CGRect(x: 0, y: 0, width: 10, height: 9)
        }

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let color = dark ? NSColor(white: 1, alpha: 0.38) : NSColor(white: 0, alpha: 0.40)
        let text = NSAttributedString(string: "z", attributes: [.font: font, .foregroundColor: color])
        let zSize = CGSize(width: 9, height: 13)
        zLayer.contents = drawImage(zSize) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: NSPoint(x: 1, y: 0))
            NSGraphicsContext.restoreGraphicsState()
        }
        zLayer.bounds = CGRect(origin: .zero, size: zSize)
    }

    // MARK: Apply

    func apply(_ next: DogSpriteState) {
        if !attached {
            library.attach()
            attached = true
        }
        let previous = state
        guard previous != next else { return }
        state = next
        noActions {
            if previous?.scale != next.scale { layoutStage(scale: next.scale) }
            if previous?.dark != next.dark { renderParts(dark: next.dark) }
        }
        if let p = previous, p.reduceMotion != next.reduceMotion { resetMotion() }
        if let one = next.oneShot, one.id != lastOneShotID {
            lastOneShotID = one.id
            if !next.reduceMotion, previous != nil { pendingOneShot = one }
        }
        if let burst = next.hearts, burst.id != lastHeartsID {
            lastHeartsID = burst.id
            if !next.reduceMotion, previous != nil { playHearts(burst.count) }
        }
#if UITEST
        DogSpriteProbe.observe(self, plan: next.plan)
#endif
        advance()
        updateOverlays()
    }

    func shutdown() {
        generation += 1
        busy = false
        pending = nil
        pendingOneShot = nil
        removeAllAnimations()
        if attached {
            library.detach()
            attached = false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shutdown()
        } else if !attached, let s = state {
            library.attach()
            attached = true
            state = nil
            screen = nil
            apply(s)
        }
    }

    private func removeAllAnimations() {
        func walk(_ l: CALayer) {
            l.removeAllAnimations()
            l.sublayers?.forEach(walk)
        }
        walk(stage)
        noActions {
            for l in [frameLayer, ground] {
                l.speed = 1
                l.timeOffset = 0
                l.beginTime = 0
            }
            hearts.forEach { $0.opacity = 0 }
        }
    }

    private func resetMotion() {
        generation += 1
        busy = false
        pending = nil
        pendingOneShot = nil
        removeAllAnimations()
        screen = nil
    }

    // MARK: State machine (DESIGN_V2.md 4.6)

    private var reduceMotion: Bool { state?.reduceMotion ?? false }
    private var base: DogStagePlan? { state?.plan }

    private func entry(_ a: DogAction) -> DogSpriteManifest.Action? { library.manifest?.action(a) }

    /// Pins the strips that the screen shows or is about to show, so the LRU cache never drops them.
    private func pinVisible(_ next: DogAction? = nil) {
        library.pin(Set([screen, next, base?.action, pendingOneShot?.action, .standUp].compactMap { $0 }))
    }

    private func advance() {
        guard !busy, base != nil else { return }
        pinVisible()
        guard let target = base else { return }
        guard let current = screen else {
            show(target, fade: nil)
            return
        }
        if reduceMotion {
            // Reduce Motion: the new picture replaces the old one without a fade (BB, W15).
            pendingOneShot = nil
            if current != target.action { show(target, fade: nil) } else { tween(target) }
            return
        }
        if let one = pendingOneShot {
            if current.isLying {
                // Rise first. The one-shot stays pending and starts when stand_up ends.
                playOnce(.standUp, repeats: 1, reverse: false, hold: 0) { [weak self] in self?.screenIs(.standUp) }
                return
            }
            pendingOneShot = nil
            let fade: Double = current == .standUp ? 0.08 : 0.12
            playOnce(one.action, repeats: one.repeats, reverse: false, hold: entry(one.action)?.holdLastSeconds ?? 0, fade: fade) { [weak self] in
                self?.screenIs(one.action)
            }
            return
        }
        if current == target.action {
            tween(target)
            return
        }
        if current == .standUp, target.action.isLying {
            playOnce(.standUp, repeats: 1, reverse: true, hold: 0) { [weak self] in self?.liedDown() }
            return
        }
        switch DogStage.transition(from: current, screenVariant, to: target.action, target.variant) {
        case .none, .tween:
            tween(target)
        case .atContact:
            waitForContact(target)
        case .standUp:
            playOnce(.standUp, repeats: 1, reverse: false, hold: 0) { [weak self] in self?.screenIs(.standUp) }
        case .lieDown:
            playOnce(.standUp, repeats: 1, reverse: true, hold: 0) { [weak self] in self?.liedDown() }
        case .crossfade(let d):
            show(target, fade: d)
        }
    }

    /// After lie_down the dog lies on stand_up frame 0. A lying target follows with a short fade; a standing one rises again.
    private func liedDown() {
        busy = false
        screen = .lieIdle
        screenVariant = .normal
        if let target = base, target.action.isLying {
            show(target, fade: 0.12)
        } else {
            advance()
        }
        updateOverlays()
    }

    private func screenIs(_ action: DogAction) {
        screen = action
        screenVariant = .normal
        busy = false
        advance()
        updateOverlays()
    }

    /// Shows a base action: its loop, or its rest frame under Reduce Motion and for the static sit_gray.
    private func show(_ plan: DogStagePlan, fade: Double?) {
        generation += 1
        let action = plan.action
        let e = entry(action)
        pinVisible(action)
        let image = library.strip(action)
        noActions {
            if let fade, fade > 0 { addFade(fade) }
            frameLayer.removeAllAnimations()
            body.removeAnimation(forKey: "bob")
            resetTiming(frameLayer, speed: 1)
            if let image, let e {
                screenUsesStrip = true
                frameLayer.contents = image
                currentImage = image
                frameLayer.contentsRect = rect(e.restFrame, of: e.frames)
                if !reduceMotion, e.loops, e.frames > 1 {
                    addLoop(e, rate: plan.rate)
                }
            } else {
                // Level 1 and 2 of 11.6: the mirrored still picture, with a bob for the moving gaits.
                screenUsesStrip = false
                currentImage = library.still(action)
                frameLayer.contents = currentImage
                frameLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                if !reduceMotion, plan.stepHz > 0 { addBob(stepHz: plan.stepHz) }
            }
            applyBody(plan, animated: false)
        }
        screen = action
        screenVariant = plan.variant
        library.prefetch(DogSpriteLibrary.likelyNext(action))
    }

    /// Same action: rate, sink and scale move over 0.4 s without a new picture.
    private func tween(_ plan: DogStagePlan) {
        guard screen == plan.action else { return }
        noActions {
            if screenUsesStrip, !reduceMotion, frameLayer.animation(forKey: "frames") != nil {
                resetTiming(frameLayer, speed: plan.rate)
            } else if !screenUsesStrip, !reduceMotion, plan.stepHz > 0 {
                addBob(stepHz: plan.stepHz)
            }
            applyBody(plan, animated: !reduceMotion && (screenVariant != plan.variant))
        }
        screenVariant = plan.variant
    }

    private func applyBody(_ plan: DogStagePlan, animated: Bool) {
        let foot = y(DogStageGeometry.footY, 0)
        let newPosition = CGPoint(x: DogStageGeometry.dogBox.midX, y: foot - CGFloat(plan.sink))
        let newTransform = CATransform3DMakeScale(1, CGFloat(plan.scaleY), 1)
        if animated {
            let p = CABasicAnimation(keyPath: "position")
            p.fromValue = NSValue(point: body.presentation()?.position ?? body.position)
            p.toValue = NSValue(point: newPosition)
            let t = CABasicAnimation(keyPath: "transform")
            t.fromValue = NSValue(caTransform3D: body.presentation()?.transform ?? body.transform)
            t.toValue = NSValue(caTransform3D: newTransform)
            for a in [p, t] {
                a.duration = 0.4
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                body.add(a, forKey: a.keyPath)
            }
        }
        body.position = newPosition
        body.transform = newTransform
        placeShadow(plan.action)
    }

    private func placeShadow(_ action: DogAction) {
        let s = DogStageGeometry.shadow(action, ink: entry(action)?.restInkBox)
        let center = DogStageGeometry.stagePoint(px: s.centerX, s.centerY)
        let size = CGSize(width: s.width / 2, height: s.height / 2)
        shadowLayer.bounds = CGRect(origin: .zero, size: size)
        shadowLayer.position = CGPoint(x: center.x, y: y(center.y, 0))
        shadowLayer.opacity = Float(s.opacity)
    }

    private func rect(_ index: Int, of frames: Int) -> CGRect {
        let n = CGFloat(max(1, frames))
        return CGRect(x: CGFloat(min(max(0, index), frames - 1)) / n, y: 0, width: 1 / n, height: 1)
    }

    /// Keeps the local time of a layer continuous while its speed changes (11.2 rule 4).
    private func resetTiming(_ l: CALayer, speed: Double) {
        let now = CACurrentMediaTime()
        let local = l.convertTime(now, from: nil)
        let parent = l.superlayer?.convertTime(now, from: nil) ?? now
        l.beginTime = parent
        l.timeOffset = local
        l.speed = Float(max(0, speed))
    }

    private func frameAnimation(_ e: DogSpriteManifest.Action, order: [Int]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "contentsRect")
        a.calculationMode = .discrete
        a.values = order.map { NSValue(rect: rect($0, of: e.frames)) }
        let n = Double(order.count)
        a.keyTimes = (0...order.count).map { NSNumber(value: Double($0) / n) }
        a.duration = n / max(1, e.fps)
        return a
    }

    private func addLoop(_ e: DogSpriteManifest.Action, rate: Double) {
        let a = frameAnimation(e, order: Array(0..<e.frames))
        a.repeatCount = .infinity
        let start = frameLayer.convertTime(CACurrentMediaTime(), from: nil)
        a.beginTime = start
        frameLayer.add(a, forKey: "frames")
        resetTiming(frameLayer, speed: rate)
        loopStart = start
        loopDuration = a.duration
        loopFrames = e.frames
    }

    private func addBob(stepHz: Double) {
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = 0
        a.toValue = 1.5
        a.duration = 0.5 / max(0.2, stepHz)
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        frameLayer.add(a, forKey: "bob")
    }

    private func addFade(_ seconds: Double) {
        guard !reduceMotion else { return }
        let t = CATransition()
        t.type = .fade
        t.duration = seconds
        t.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        body.add(t, forKey: "fade")
#if UITEST
        DogSpriteProbe.fades += 1
#endif
    }

    /// Plays a strip once (or `repeats` times), backwards for lie_down, then holds the last frame `hold` seconds and calls `done`.
    private func playOnce(_ action: DogAction, repeats: Int, reverse: Bool, hold: Double, fade: Double = 0,
                          done: @escaping () -> Void) {
        pinVisible(action)
        guard let e = entry(action), let image = library.strip(action) else {
            // No strip: skip the one-shot (level 1 has no picture sequence for it).
            if action == .standUp {
                screenUsesStrip = false
                done()
            } else {
                screenIs(screen ?? .lieIdle)
            }
            return
        }
        generation += 1
        busy = true
        let order = reverse ? Array((0..<e.frames).reversed()) : Array(0..<e.frames)
        let anim = frameAnimation(e, order: order)
        anim.repeatCount = Float(max(1, repeats))
        noActions {
            if fade > 0 { addFade(fade) }
            frameLayer.removeAllAnimations()
            body.removeAnimation(forKey: "bob")
            resetTiming(frameLayer, speed: 1)
            frameLayer.contents = image
            currentImage = image
            frameLayer.contentsRect = rect(order.last ?? 0, of: e.frames)
            anim.beginTime = frameLayer.convertTime(CACurrentMediaTime(), from: nil)
            anim.fillMode = .forwards
            frameLayer.add(anim, forKey: "once")
            if let plan = base, action == .standUp { applyBody(DogStagePlan(action: plan.action, variant: .normal, overlays: plan.overlays,
                                                                             rate: 1, stepHz: 0, sink: 0, scaleY: 1, groundSpeed: 0, showsZ: false),
                                                                 animated: false) }
            placeShadow(action)
        }
        screenUsesStrip = true
        screen = action
        let total = anim.duration * Double(anim.repeatCount) + hold
        startMarker(total, then: done)
        updateOverlays()
    }

    /// Waits for the next contact frame of the gait on screen, then starts the target gait at its frame 0 (4.6 row 1).
    private func waitForContact(_ target: DogStagePlan) {
        guard screenUsesStrip, let current = screen, let e = entry(current), frameLayer.animation(forKey: "frames") != nil,
              !e.contactFrames.isEmpty, frameLayer.speed > 0 else {
            show(target, fade: nil)
            return
        }
        let local = frameLayer.convertTime(CACurrentMediaTime(), from: nil)
        var phase = (local - loopStart).truncatingRemainder(dividingBy: loopDuration)
        if phase < 0 { phase += loopDuration }
        let perFrame = loopDuration / Double(max(1, loopFrames))
        let position = phase / perFrame
        var waitFrames = Double(loopFrames)
        for c in e.contactFrames {
            var d = Double(c) - position
            if d < 0 { d += Double(loopFrames) }
            waitFrames = min(waitFrames, d)
        }
        let wall = waitFrames * perFrame / Double(frameLayer.speed)
        if wall < 0.02 {
            show(target, fade: nil)
            return
        }
        generation += 1
        busy = true
        startMarker(wall) { [weak self] in
            guard let self else { return }
            self.busy = false
            if let now = self.base, now.action.naturalStepHz != nil {
                self.show(now, fade: nil)
                self.updateOverlays()
            } else {
                self.advance()
            }
        }
    }

    private func startMarker(_ seconds: Double, then done: @escaping () -> Void) {
        let token = generation
        pending = done
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 0
        a.duration = max(0.01, seconds)
        a.delegate = relay
        a.setValue(token, forKey: "moleGeneration")
        marker.add(a, forKey: "marker")
        // Guard: only if animationDidStop never comes (it is the hand-over of 11.2 rule 6).
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.markerStopped(generation: token, finished: true, fromGuard: true) }
        }
    }

    fileprivate func markerStopped(generation token: Int, finished: Bool, fromGuard: Bool) {
        guard token == generation, let work = pending else { return }
        guard finished else { return }
        pending = nil
#if UITEST
        if fromGuard { DogSpriteProbe.guardSteps += 1 } else { DogSpriteProbe.delegateSteps += 1 }
#endif
        work()
    }

    // MARK: Overlays

    private var movingNow: Bool { screen?.naturalStepHz != nil }

    private func updateOverlays() {
        guard let plan = base else { return }
        noActions {
            // Ground texture: moves only while a gait is on screen, to the right because the dog faces left.
            if reduceMotion || !movingNow || plan.groundSpeed <= 0 {
                ground.removeAnimation(forKey: "shift")
                ground.speed = 1
                ground.timeOffset = 0
                ground.beginTime = 0
            } else {
                if ground.animation(forKey: "shift") == nil {
                    let a = CABasicAnimation(keyPath: "transform.translation.x")
                    a.fromValue = 0
                    a.toValue = DogStageGeometry.texturePeriod
                    a.duration = 1
                    a.repeatCount = .infinity
                    a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                    ground.add(a, forKey: "shift")
                }
                resetTiming(ground, speed: plan.groundSpeed / Double(DogStageGeometry.texturePeriod))
            }

            let shownAction = screen ?? plan.action
            let head = DogStageGeometry.head(shownAction, manifest: library.manifest)
            // Sweat: two drops at the forehead (temperature yellow).
            sweat.isHidden = !plan.overlays.sweat
            if plan.overlays.sweat, let drops = sweat.sublayers, drops.count == 2 {
                let spots = [CGPoint(x: head.x - 9, y: head.y + 2), CGPoint(x: head.x - 3, y: head.y - 4)]
                for (d, p) in zip(drops, spots) {
                    d.bounds = CGRect(x: 0, y: 0, width: 5, height: 7)
                    d.position = CGPoint(x: p.x, y: y(p.y, 0))
                    if reduceMotion {
                        d.removeAllAnimations()
                    } else if d.animation(forKey: "drip") == nil {
                        let a = CABasicAnimation(keyPath: "transform.translation.y")
                        a.fromValue = 0
                        a.toValue = -1.5
                        a.duration = 0.7
                        a.autoreverses = true
                        a.repeatCount = .infinity
                        a.beginTime = CACurrentMediaTime() + (p.x.truncatingRemainder(dividingBy: 2) == 0 ? 0 : 0.35)
                        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                        d.add(a, forKey: "drip")
                    }
                }
            } else {
                sweat.sublayers?.forEach { $0.removeAllAnimations() }
            }

            // "z" of the sleep variant: rises 16 pt and fades every 3 s. Reduce Motion keeps one still "z".
            let showsZ = plan.showsZ && shownAction == .lieIdle
            zLayer.isHidden = !showsZ
            if showsZ {
                let crown = DogStageGeometry.crown(shownAction, manifest: library.manifest)
                zLayer.position = CGPoint(x: crown.x + 6, y: y(crown.y - 9, 0))
                if reduceMotion {
                    zLayer.removeAllAnimations()
                    zLayer.opacity = 1
                } else if zLayer.animation(forKey: "rise") == nil {
                    zLayer.opacity = 0
                    let rise = CABasicAnimation(keyPath: "transform.translation.y")
                    rise.fromValue = 0
                    rise.toValue = 16
                    rise.duration = 2.4
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = [0, 1, 1, 0]
                    fade.keyTimes = [0, 0.15, 0.55, 1]
                    fade.duration = 2.4
                    let group = CAAnimationGroup()
                    group.animations = [rise, fade]
                    group.duration = 3
                    group.repeatCount = .infinity
                    group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                    zLayer.add(group, forKey: "rise")
                }
            } else {
                zLayer.removeAllAnimations()
            }
        }
    }

    /// Hearts rise 24 pt from the head and fade in 0.9 s (4.8). The model opacity stays 0, so nothing is left after the animation.
    private func playHearts(_ count: Int) {
        let head = DogStageGeometry.crown(screen ?? base?.action ?? .lieIdle, manifest: library.manifest)
        let offsets: [CGFloat] = [0, -10, 10, -18, 18]
        noActions {
            for (i, h) in hearts.prefix(max(0, min(count, hearts.count))).enumerated() {
                h.removeAllAnimations()
                h.opacity = 0
                h.position = CGPoint(x: head.x + offsets[i], y: y(head.y - 6, 0))
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 0
                rise.toValue = 24
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.12, 0.6, 1]
                let group = CAAnimationGroup()
                group.animations = [rise, fade]
                group.duration = 0.9
                for a in [rise, fade] { a.duration = 0.9 }
                group.beginTime = CACurrentMediaTime() + Double(i) * 0.07
                group.fillMode = .backwards
                group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                h.add(group, forKey: "heart")
            }
        }
    }

    // MARK: Hit test and touch (4.8)

    /// Alpha of the frame on screen at a point of this view, 0 to 1.
    func alphaAt(_ point: NSPoint) -> Double {
        let scale = state?.scale ?? 1
        let stageX = point.x / scale
        let stageTop = (bounds.height - point.y) / scale
        let box = DogStageGeometry.dogBox
        guard box.contains(CGPoint(x: stageX, y: stageTop)), let cg = currentImage else { return 0 }
        let rectNow = frameLayer.presentation()?.contentsRect ?? frameLayer.contentsRect
        let px = (rectNow.minX + (stageX - box.minX) / box.width * rectNow.width) * CGFloat(cg.width)
        let py = (stageTop - box.minY) / box.height * CGFloat(cg.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        // Draw the image so that pixel (px, py), counted from the top, lands on the single pixel.
        ctx.draw(cg, in: CGRect(x: -floor(px), y: -(CGFloat(cg.height) - 1 - floor(py)), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let data = ctx.data else { return 0 }
        return Double(data.load(fromByteOffset: 3, as: UInt8.self)) / 255
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return alphaAt(local) >= 0.3 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        press = (CACurrentMediaTime(), event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = press else { return }
        press = nil
        let held = CACurrentMediaTime() - p.time
        let moved = hypot(event.locationInWindow.x - p.point.x, event.locationInWindow.y - p.point.y)
        if held < 0.3, moved < 4 {
            onTap?()
        } else if held >= 0.6, moved < 8 {
            onLongPress?()
        }
    }

#if UITEST
    /// Number of animations attached to the stage layers now (W15).
    var animationCount: Int { animationKeys.count }

    /// "layer:key" of every animation on the stage layers now (the W15 note names them).
    var animationKeys: [String] {
        func keys(_ l: CALayer) -> [String] {
            (l.animationKeys() ?? []).map { "\(l.name ?? "?"):\($0)" } + (l.sublayers ?? []).flatMap { keys($0) }
        }
        return keys(stage)
    }

    var screenAction: DogAction? { screen }
    var showsStrip: Bool { screenUsesStrip }
    var isBusy: Bool { busy }
#endif
}

// MARK: - Probe

#if UITEST
/// What the stage did, for the gates (W04, W11, W14, W15, W17, W18). Main thread only.
enum DogSpriteProbe {
    /// Non-nil replaces the system Reduce Motion setting of the hero (the gates force it off: the CI VM reports it as on).
    static var forceReduceMotion: Bool?
    private(set) static weak var view: DogSpriteNSView?
    /// The target of the director: the base action and variant (W04 reads them, not the action of a transition in flight).
    private(set) static var currentAction: DogAction?
    private(set) static var variant: DogVariant?
    private(set) static var rate: Double = 0
    private(set) static var stepHz: Double = 0
    private(set) static var plans = [DogStagePlan]()
    static var updateLayers = 0
    static var heroBodies = 0
    static var fades = 0
    static var delegateSteps = 0
    static var guardSteps = 0

    static func observe(_ v: DogSpriteNSView, plan: DogStagePlan) {
        view = v
        if currentAction != plan.action || variant != plan.variant || rate != plan.rate { plans.append(plan) }
        currentAction = plan.action
        variant = plan.variant
        rate = plan.rate
        stepHz = plan.stepHz
    }

    static func reset() {
        plans = []
        updateLayers = 0
        heroBodies = 0
        fades = 0
    }
}
#endif
