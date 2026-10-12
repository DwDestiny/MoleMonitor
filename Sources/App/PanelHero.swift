// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData of the panel model, the copy text of the footer (`copyBubble`, WP-C PanelModel.copyBubble), the prompt setting
//        "include app names" and the "no anomaly last night" flag (docs/DESIGN_V2.md 4).
// Output: The hero block: a 320 x 152 pt stage with the bitmap Bichon (DogSpriteView), its bubble, the second line, the bed, the
//         night sky, and the touch replies (wag, hearts, texts). HeroModel wraps HeroBrain (Core/HeroLogic.swift).
// Pos: First block of the panel (DESIGN_V2.md 2.2, 4.2). The stage background, the bed, the moon, the bubble and the texts are
//      SwiftUI; everything that moves is Core Animation inside DogSpriteView, so the body runs once per data point (W14).
//      The signature `PanelHero(data:quiet:)` stays; the new parameters have defaults. `quiet` no longer changes the look: the stage
//      is the same in both modes, the bubble carries the problem.
//      COMPAT (v1 layout on main before WP-C merges): the stage scales down to the slot that PanelMetrics gives. In the v2 layout
//      the slot is 320 x 152 pt and the scale is 1. TODO(WP-D): drop the scale after WP-C is on main.
//      Fallback chain (11.6): no usable bitmap at all, or `DogView.useBitmapArt == false`, shows the vector DogView (level 3).
//      Stage colors: HeroTokens below (cooler than 3.3 `stage.day` #F3F1ED, see the WP-D report; F2 decides the token text).

import SwiftUI

// MARK: - Tokens

/// Colors of the stage. Color means state here: the night sky, the bed and the drops; the stage itself stays quiet.
struct HeroTokens {
    let dark: Bool
    let night: Bool

    private static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
              opacity: alpha)
    }

    var stageTop: Color { night ? (dark ? Self.rgb(0x1B1E27) : Self.rgb(0xD9DEEA)) : (dark ? Self.rgb(0x2E2F35) : Self.rgb(0xE5EAF0)) }
    var stageBottom: Color { night ? (dark ? Self.rgb(0x1F222C) : Self.rgb(0xE1E5EE)) : (dark ? Self.rgb(0x2A2B30) : Self.rgb(0xEDEFF2)) }
    var groundBand: Color { night ? (dark ? Self.rgb(0x181A21) : Self.rgb(0xD2D7E2)) : (dark ? Self.rgb(0x252629) : Self.rgb(0xE2E5E9)) }
    var groundLine: Color { Color(.sRGB, white: dark ? 1 : 0, opacity: 0.10) }
    var bubbleFill: Color { dark ? Self.rgb(0x3A3A3F) : Color.white }
    var bubbleStroke: Color { Color(.sRGB, white: dark ? 1 : 0, opacity: dark ? 0.10 : 0.08) }
    var bubbleShadow: Color { Color(.sRGB, white: 0, opacity: dark ? 0.30 : 0.08) }
    var texture: Color { Color(.sRGB, white: dark ? 1 : 0, opacity: dark ? 0.10 : 0.09) }
    var shadow: Color { Color(.sRGB, white: 0, opacity: dark ? 0.40 : 0.13) }
    var moon: Color { dark ? Self.rgb(0xF2DE9B) : Self.rgb(0xC9A43E) }
    var star: Color { dark ? Color(.sRGB, white: 1, opacity: 0.80) : Self.rgb(0x8A94AB) }
    var drop: Color { dark ? Self.rgb(0x8CC7FF) : Self.rgb(0x4D9EE6) }
    var z: Color { Color(.sRGB, white: dark ? 1 : 0, opacity: dark ? 0.38 : 0.40) }
}

// MARK: - Model

/// HeroBrain plus the two 2.5 s timers of the event texts (one-shot asyncAfter, cancelled by the next event).
/// A data point reaches the brain inside the body of PanelHero (`sync`), so one data point costs one body evaluation (W14).
/// The properties are not @Published for that reason. Taps, the copy text, the open and the timers change the brain outside a body,
/// so they send `objectWillChange` themselves.
@MainActor
final class HeroModel: ObservableObject {
    private(set) var brain: HeroBrain
    private(set) var popToken = 0
    private(set) var oneShot: HeroOneShot?
    private(set) var hearts: HeartBurst?
    private var serial = 0
    private var eventWork: DispatchWorkItem?
    private var copyWork: DispatchWorkItem?

    /// Process counters (4.8 rule 4: in memory only).
    static var memory = HeroMemory()

    init(facts: HeroFacts) {
        brain = HeroBrain(facts: facts)
    }

    /// Called from the body with the facts of the data on screen. It does not publish: the body that calls it already shows the result.
    func sync(_ facts: HeroFacts, reduceMotion: Bool) {
        guard facts != brain.facts else { return }
        apply(brain.update(facts, reduceMotion: reduceMotion))
    }

    func appeared(lastNightClean: Bool) {
        objectWillChange.send()
        apply(brain.appeared(clock: Date(), calendar: .current, lastNightClean: lastNightClean, eggs: PanelHero.eggsEnabled,
                             memory: &HeroModel.memory))
    }

    func tapped(reduceMotion: Bool) {
        objectWillChange.send()
        apply(brain.tap(at: ProcessInfo.processInfo.systemUptime, day: Calendar.current.startOfDay(for: Date()),
                        reduceMotion: reduceMotion, memory: &HeroModel.memory))
    }

    func longPressed(reduceMotion: Bool) {
        objectWillChange.send()
        apply(brain.longPress(day: Calendar.current.startOfDay(for: Date()), reduceMotion: reduceMotion, memory: &HeroModel.memory))
    }

    func copied(_ text: String?, reduceMotion: Bool) {
        objectWillChange.send()
        apply(brain.copied(text, reduceMotion: reduceMotion))
    }

    private func apply(_ e: HeroEffects) {
        if let action = e.oneShot {
            serial += 1
            oneShot = HeroOneShot(action: action, repeats: e.repeats, id: serial)
        }
        if e.hearts > 0 {
            serial += 1
            hearts = HeartBurst(count: e.hearts, id: serial)
        }
        if e.pop { popToken += 1 }
        if e.eventStarted {
            eventWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                    self?.brain.endEvent()
                }
            }
            eventWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HeroBrain.eventSeconds, execute: work)
        }
        if e.copyStarted {
            copyWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                    self?.brain.endCopy()
                }
            }
            copyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HeroBrain.eventSeconds, execute: work)
        }
    }
}

// MARK: - Hero

struct PanelHero: View {
    let data: PanelData
    let quiet: Bool
    let copyBubble: String?
    let includeAppNames: Bool
    let lastNightClean: Bool

    @StateObject private var model: HeroModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.panelSnapshot) private var snapshot
    @Environment(\.tok) private var tok

#if UITEST
    /// Night on or off for every hero. The UI test build starts in the day and without easter eggs, so screenshots repeat.
    static var nightOverride: Bool? = false
    static var eggsEnabled = false
#else
    static var nightOverride: Bool?
    static var eggsEnabled = true
#endif

    init(data: PanelData, quiet: Bool, copyBubble: String? = nil, includeAppNames: Bool = true, lastNightClean: Bool = false) {
        self.data = data
        self.quiet = quiet
        self.copyBubble = copyBubble
        self.includeAppNames = includeAppNames
        self.lastNightClean = lastNightClean
        let facts = PanelHero.facts(data, includeAppNames: includeAppNames)
        _model = StateObject(wrappedValue: HeroModel(facts: facts))
    }

    static func isNight(_ data: PanelData) -> Bool { nightOverride ?? DogStage.isNight(data.now) }

    static func facts(_ data: PanelData, includeAppNames: Bool) -> HeroFacts {
        HeroFacts.make(verdicts: data.verdicts, current: data.current, apps: data.apps, status: data.status, dataState: data.dataState,
                       now: data.now, includeAppNames: includeAppNames, night: isNight(data))
    }

    /// Level 3 of 11.6: the vector dog.
    static var vectorFallback: Bool {
        !DogView.useBitmapArt || (!DogSpriteLibrary.shared.hasManifest && !DogArtLibrary.shared.isComplete)
    }

    /// The slot of the layout. v2: 320 x 152 pt. COMPAT v1: the content width and the hero height of the mode.
    private var slot: CGSize {
        CGSize(width: PanelMetrics.width - 2 * PanelMetrics.padding, height: quiet ? PanelMetrics.heroQuiet : PanelMetrics.heroProblem)
    }

    private var scale: CGFloat {
        let size = DogStageGeometry.size
        return min(1, slot.width / size.width, slot.height / size.height)
    }

    private var reduceMotion: Bool {
#if UITEST
        if let forced = DogSpriteProbe.forceReduceMotion { return forced }
        if let forced = DogFrameProbe.forceReduceMotion { return forced }
#endif
        return systemReduceMotion
    }

    var body: some View {
#if UITEST
        let _ = (DogSpriteProbe.heroBodies += 1)
#endif
        let s = scale
        let facts = PanelHero.facts(data, includeAppNames: includeAppNames)
        let dark = scheme == .dark
        let tokens = HeroTokens(dark: dark, night: facts.action.isNight)
        let rm = reduceMotion
        let _ = model.sync(facts, reduceMotion: rm)
        let plan = model.brain.plan
        let text = model.brain.display
        ZStack(alignment: .topLeading) {
            HeroStageBackground(tokens: tokens, scale: s)
            if let bed = plan.overlays.bed, let image = DogSpriteLibrary.shared.prop(bed) {
                Image(decorative: image, scale: DogStageGeometry.pixelScale)
                    .resizable()
                    .frame(width: DogStageGeometry.bedRect.width * s, height: DogStageGeometry.bedRect.height * s)
                    .padding(.leading, DogStageGeometry.bedRect.minX * s)
                    .padding(.top, DogStageGeometry.bedRect.minY * s)
                    .accessibilityHidden(true)
            }
            dog(plan: plan, scale: s, dark: dark, tokens: tokens, reduceMotion: rm)
            HStack(spacing: 0) {
                HeroBubble(text: text, scale: s, tokens: tokens)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: rm ? 0 : model.popToken) { content, value in
                        content.scaleEffect(value, anchor: .bottomTrailing)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(CGFloat(0.85))
                            SpringKeyframe(CGFloat(1), duration: 0.45, spring: Spring(response: 0.32, dampingRatio: 0.72))
                        }
                    }
                    .uiTestFrame("bubble")
                Spacer(minLength: 0)
            }
            .frame(width: DogStageGeometry.bubbleMaxWidth * s, alignment: .leading)
            .padding(.leading, DogStageGeometry.bubbleOrigin.x * s)
            .padding(.top, DogStageGeometry.bubbleOrigin.y * s)
            if let sub = text.sub {
                Text(sub)
                    .font(.system(size: DogStageGeometry.subFont * s))
                    .monospacedDigit()
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.hero.subtitle")
                    .padding(.leading, DogStageGeometry.subOrigin.x * s)
                    .padding(.top, DogStageGeometry.subOrigin.y * s)
            }
            Color.clear
                .frame(width: DogStageGeometry.dogBox.width * s, height: DogStageGeometry.dogBox.height * s)
                .uiTestFrame("dog")
                .accessibilityElement()
                .accessibilityIdentifier("dog")
                .accessibilityLabel(Text(PanelHero.dogLabel(plan)))
                .allowsHitTesting(false)
                .padding(.leading, DogStageGeometry.dogBox.minX * s)
                .padding(.top, DogStageGeometry.dogBox.minY * s)
        }
        .frame(width: DogStageGeometry.size.width * s, height: DogStageGeometry.size.height * s, alignment: .topLeading)
        .uiTestFrame("hero.stage")
        .frame(width: slot.width, height: slot.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.hero")
        .onAppear { model.appeared(lastNightClean: lastNightClean) }
        .onChange(of: copyBubble) { _, next in model.copied(next, reduceMotion: rm) }
    }

    @ViewBuilder
    private func dog(plan: DogStagePlan, scale s: CGFloat, dark: Bool, tokens: HeroTokens, reduceMotion rm: Bool) -> some View {
        if PanelHero.vectorFallback {
            // The vector dog faces right; the stage dog faces left.
            DogView(input: data.dogInput, size: CGSize(width: DogStageGeometry.dogBox.width * s, height: DogStageGeometry.dogBox.height * s))
                .scaleEffect(x: -1, y: 1)
                .padding(.leading, DogStageGeometry.dogBox.minX * s)
                .padding(.top, DogStageGeometry.dogBox.minY * s)
                .accessibilityHidden(true)
        } else if snapshot {
            HeroStillDog(plan: plan, scale: s, tokens: tokens)
                .accessibilityHidden(true)
        } else {
            DogSpriteRepresentable(
                state: DogSpriteState(plan: plan, oneShot: model.oneShot, hearts: model.hearts, reduceMotion: rm, dark: dark, scale: s),
                onTap: { [model] in model.tapped(reduceMotion: rm) },
                onLongPress: { [model] in model.longPressed(reduceMotion: rm) })
                .frame(width: DogStageGeometry.size.width * s, height: DogStageGeometry.size.height * s)
                .accessibilityHidden(true)
        }
    }

    /// The accessibility label of the dog. It starts with "比熊" (gate M19).
    static func dogLabel(_ plan: DogStagePlan) -> String {
        switch plan.action {
        case .lieIdle:
            switch plan.variant {
            case .sleep: return "比熊在睡觉"
            case .tired: return "比熊累得趴着"
            default: return "比熊趴着休息"
            }
        case .walk: return plan.variant == .heavy ? "比熊走得很吃力" : "比熊在散步"
        case .trot: return "比熊在小跑"
        case .sprint: return "比熊在全力奔跑"
        case .sniff: return "比熊在闻来闻去"
        case .sitGray: return "比熊站着发呆"
        case .standUp: return "比熊站了起来"
        case .wag: return "比熊在摇尾巴"
        case .pantLie: return "比熊热得趴着喘气"
        case .notice: return "比熊注意到了问题"
        }
    }
}

// MARK: - Stage background

/// Gradient, ground band, ground line, and the moon with 3 stars at night. All static.
private struct HeroStageBackground: View {
    let tokens: HeroTokens
    let scale: CGFloat

    var body: some View {
        let s = scale
        let g = DogStageGeometry.self
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [tokens.stageTop, tokens.stageBottom], startPoint: .top, endPoint: .bottom)
            tokens.groundBand
                .frame(height: (g.size.height - g.groundY) * s)
                .padding(.top, g.groundY * s)
            tokens.groundLine
                .frame(height: 1)
                .padding(.top, g.groundY * s)
            if tokens.night {
                Circle()
                    .fill(tokens.moon)
                    .frame(width: g.moonRect.width * s, height: g.moonRect.height * s)
                    .mask {
                        Rectangle()
                            .overlay {
                                Circle()
                                    .frame(width: 12 * s, height: 12 * s)
                                    .offset(x: 4.5 * s, y: -3.5 * s)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .padding(.leading, g.moonRect.minX * s)
                    .padding(.top, g.moonRect.minY * s)
                ForEach(0..<g.stars.count, id: \.self) { i in
                    let star = g.stars[i]
                    Circle()
                        .fill(tokens.star)
                        .frame(width: star.d * s, height: star.d * s)
                        .padding(.leading, (star.x - star.d / 2) * s)
                        .padding(.top, (star.y - star.d / 2) * s)
                }
            }
        }
        .frame(width: g.size.width * s, height: g.size.height * s, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: g.cornerRadius * s, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Bubble

/// Rounded box with a short tail at the bottom right that points down to the dog. The tail tip stays inside the box width.
private struct BubbleShape: Shape {
    var radius: CGFloat
    var tail: CGSize
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY - tail.height
        let r = min(radius, (y1 - y0) / 2, (x1 - x0) / 2)
        let tipX = x1 - inset
        let baseRight = min(x1 - r, tipX - 1)
        let baseLeft = max(x0 + r, baseRight - tail.width)
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
        p.addLine(to: CGPoint(x: baseRight, y: y1))
        p.addLine(to: CGPoint(x: tipX, y: y1 + tail.height))
        p.addLine(to: CGPoint(x: baseLeft, y: y1))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
        p.closeSubpath()
        return p
    }
}

struct HeroBubble: View {
    let text: BubbleText
    let scale: CGFloat
    let tokens: HeroTokens
    /// 2 on the stage. W12 passes nil to measure a template without the clamp, so a third line shows as height.
    let maxLines: Int?
    @Environment(\.tok) private var tok

    init(text: BubbleText, scale: CGFloat, tokens: HeroTokens, maxLines: Int? = 2) {
        self.text = text
        self.scale = scale
        self.tokens = tokens
        self.maxLines = maxLines
    }

    private var attributed: AttributedString {
        var a = AttributedString(text.main)
        if let e = text.emphasis, let level = text.level, let range = a.range(of: e) {
            a[range].font = .system(size: DogStageGeometry.bubbleFont * scale, weight: .semibold)
            a[range].foregroundColor = tok.levelText(level)
        }
        return a
    }

    var body: some View {
        let s = scale
        let g = DogStageGeometry.self
        let shape = BubbleShape(radius: 10 * s, tail: CGSize(width: g.tailSize.width * s, height: g.tailSize.height * s),
                                inset: g.tailInset * s)
        Text(attributed)
            .font(.system(size: g.bubbleFont * s, weight: .medium))
            .monospacedDigit()
            .lineSpacing(2.5 * s)
            .foregroundStyle(tok.textPrimary)
            .lineLimit(maxLines)
            .fixedSize(horizontal: false, vertical: true)
            .uiTestFrame("txt.hero.title")
            .accessibilityIdentifier("label.summary")
            .padding(.horizontal, g.bubblePadX * s)
            .padding(.vertical, g.bubblePadY * s)
            .padding(.bottom, g.tailSize.height * s)
            .background {
                shape
                    .fill(tokens.bubbleFill)
                    .shadow(color: tokens.bubbleShadow, radius: 1.5 * s, x: 0, y: 1 * s)
            }
            .overlay { shape.stroke(tokens.bubbleStroke, lineWidth: 0.5) }
    }
}

// MARK: - Still dog (snapshot mode)

/// The stage parts of DogSpriteView as SwiftUI, for ImageRenderer (`--preview`), which cannot draw an NSView.
private struct HeroStillDog: View {
    let plan: DogStagePlan
    let scale: CGFloat
    let tokens: HeroTokens

    var body: some View {
        let s = scale
        let g = DogStageGeometry.self
        let library = DogSpriteLibrary.shared
        let action = plan.action
        let image = library.restFrame(action) ?? library.still(action)
        let shade = g.shadow(action, ink: library.manifest?.action(action)?.restInkBox)
        let center = g.stagePoint(px: shade.centerX, shade.centerY)
        let head = g.head(action, manifest: library.manifest)
        ZStack(alignment: .topLeading) {
            Path { p in
                var x: CGFloat = 0
                while x < g.size.width {
                    p.addRect(CGRect(x: x * s, y: (g.textureY + 0.5) * s, width: 10 * s, height: 1 * s))
                    p.addRect(CGRect(x: (x + 26) * s, y: (g.textureY + 0.5) * s, width: 4 * s, height: 1 * s))
                    x += g.texturePeriod
                }
            }
            .fill(tokens.texture)
            Ellipse()
                .fill(EllipticalGradient(colors: [tokens.shadow, tokens.shadow.opacity(0)], center: .center,
                                         startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: shade.width / 2 * s, height: shade.height / 2 * s)
                .opacity(shade.opacity)
                .position(x: center.x * s, y: center.y * s)
            if let image {
                Image(decorative: image, scale: g.pixelScale)
                    .resizable()
                    .frame(width: g.dogBox.width * s, height: g.dogBox.height * s * CGFloat(plan.scaleY))
                    .padding(.leading, g.dogBox.minX * s)
                    .padding(.top, (g.dogBox.minY + g.dogBox.height * (1 - CGFloat(plan.scaleY)) + CGFloat(plan.sink)) * s)
            }
            if plan.overlays.sweat {
                ForEach(0..<2, id: \.self) { i in
                    Capsule()
                        .fill(tokens.drop)
                        .frame(width: 3.5 * s, height: 6 * s)
                        .position(x: (head.x - 9 + CGFloat(i) * 6) * s, y: (head.y + 2 - CGFloat(i) * 6) * s)
                }
            }
            if plan.showsZ {
                Text("z")
                    .font(.system(size: 11 * s, weight: .semibold))
                    .foregroundStyle(tokens.z)
                    .position(x: (head.x - 2) * s, y: (head.y - 12) * s)
            }
        }
        .frame(width: g.size.width * s, height: g.size.height * s, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: g.cornerRadius * s, style: .continuous))
    }
}
