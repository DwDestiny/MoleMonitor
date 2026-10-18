// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData of the panel model and the prompt setting "include app names" (docs/DESIGN_V3.md 1.3, 4.1).
// Output: The headline block: one sentence in `PanelType.lead` (17 pt), left aligned, at most 2 lines, in a fixed 320 x 64 pt slot.
//         Behind it the status light: a pre-rendered radial gradient (352 x 96 pt) that is yellow for a yellow problem, red for a
//         red one, and absent when all is well. A change of level crosses over in 400 ms. While the first readings arrive, the
//         title reads "正在检查，已完成 N/6 项" and shows only after 0.5 s (HeroBrain.collectingDelay).
// Pos: First block of the panel. No dog, bubble, prop, stage or ground (U10, 2026-10-18). The text comes from Core/BubbleCopy.swift
//      through HeroBrain (Core/HeroLogic.swift). The status light is two CGImages per appearance, drawn once with Core Graphics
//      (no live blur, no TimelineView, no CADisplayLink). The signature `PanelHero(data:quiet:)` stays for PanelRoot.

import AppKit
import SwiftUI

// MARK: - Model

/// HeroBrain in an ObservableObject. A data point reaches the brain inside the body of PanelHero (`sync`), so one data point costs
/// one body evaluation. The brain is not @Published for that reason.
@MainActor
final class HeroModel: ObservableObject {
    private(set) var brain: HeroBrain

    init(facts: HeroFacts) {
        brain = HeroBrain(facts: facts)
    }

    /// Called from the body with the facts of the data on screen. It does not publish: the body that calls it already shows the result.
    func sync(_ facts: HeroFacts) {
        guard facts != brain.facts else { return }
        brain.update(facts)
    }
}

// MARK: - Status light

/// The two kinds of status light. Green, unknown, collecting and stale data have none.
enum HeroGlowKind: Equatable {
    case none, warning, danger

    init(_ data: PanelData) {
        guard data.isFresh, let level = data.problems.first?.level else { self = .none; return }
        switch level {
        case .red: self = .danger
        case .yellow: self = .warning
        default: self = .none
        }
    }
}

/// Pre-rendered status light images (DESIGN_V3.md 1.3): 352 x 96 pt at 2x, an elliptical gradient from the top center to clear.
/// Drawn once per kind and appearance. Main thread only.
@MainActor
enum HeroGlowImages {
    static let size = CGSize(width: 352, height: 96)
    private static let scale = 2
    private static var cache = [String: CGImage]()

    static func image(_ kind: HeroGlowKind, tokens: PanelTokens, dark: Bool) -> CGImage? {
        let color: Color
        switch kind {
        case .none: return nil
        case .warning: color = tokens.heroGlowWarning
        case .danger: color = tokens.heroGlowDanger
        }
        let key = "\(kind)-\(dark)"
        if let hit = cache[key] { return hit }
        guard let ns = NSColor(color).usingColorSpace(.sRGB),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let a = ns.alphaComponent
        func stop(_ f: CGFloat) -> CGColor { CGColor(colorSpace: space, components: [ns.redComponent, ns.greenComponent, ns.blueComponent, a * f])! }
        let colors = [stop(1), stop(0.62), stop(0.22), stop(0)] as CFArray
        var locations: [CGFloat] = [0, 0.35, 0.72, 1]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: &locations) else { return nil }
        // Core Graphics is y up here, so the top edge is y = h. The circle of radius w/2 becomes an ellipse that is h deep.
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: CGFloat(h) / (CGFloat(w) / 2))
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: CGFloat(w) / 2, options: [])
        guard let image = ctx.makeImage() else { return nil }
        cache[key] = image
        return image
    }
}

/// Both lights stay in the tree. A change of kind moves their opacities, so the old one fades out while the new one fades in.
private struct HeroGlow: View {
    let kind: HeroGlowKind
    @Environment(\.tok) private var tok
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .topLeading) {
            layer(.warning, dark: dark)
            layer(.danger, dark: dark)
        }
        .frame(width: HeroGlowImages.size.width, height: HeroGlowImages.size.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.4), value: kind)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layer(_ k: HeroGlowKind, dark: Bool) -> some View {
        if let image = HeroGlowImages.image(k, tokens: tok, dark: dark) {
            Image(decorative: image, scale: 2)
                .resizable()
                .frame(width: HeroGlowImages.size.width, height: HeroGlowImages.size.height)
                .opacity(kind == k ? 1 : 0)
        }
    }
}

// MARK: - Headline

struct PanelHero: View {
    let data: PanelData
    let quiet: Bool
    let includeAppNames: Bool

    @StateObject private var model: HeroModel
    @State private var collectingShown = false
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    init(data: PanelData, quiet: Bool, includeAppNames: Bool = true) {
        self.data = data
        self.quiet = quiet
        self.includeAppNames = includeAppNames
        _model = StateObject(wrappedValue: HeroModel(facts: PanelHero.facts(data, includeAppNames: includeAppNames)))
    }

    static func facts(_ data: PanelData, includeAppNames: Bool) -> HeroFacts {
        HeroFacts.make(verdicts: data.verdicts, current: data.current, apps: data.apps, status: data.status, dataState: data.dataState,
                       now: data.now, includeAppNames: includeAppNames)
    }

    /// While collecting, the title waits `HeroBrain.collectingDelay` seconds. A static render (`--preview`) shows it at once.
    private var titleHidden: Bool { data.isCollecting && !collectingShown && !snapshot }

    var body: some View {
        let _ = model.sync(PanelHero.facts(data, includeAppNames: includeAppNames))
        let text = model.brain.text
        Text(titleHidden ? "" : text.wrapped)
            .font(PanelType.lead)
            .foregroundStyle(tok.textPrimary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.hero, alignment: .topLeading)
            .uiTestFrame("txt.hero.title")
            .accessibilityIdentifier("label.summary")
            .accessibilityLabel(Text(titleHidden ? "" : text.main))
            .background(alignment: .topLeading) {
                // The light is 352 pt wide and 96 pt high from the top of the panel: 16 pt left and 12 pt above the 320 pt slot.
                HeroGlow(kind: HeroGlowKind(data))
                    .offset(x: -(PanelMetrics.width - PanelMetrics.contentWidth) / 2, y: -PanelMetrics.topPadding)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("section.hero")
            .task(id: data.isCollecting) {
                guard data.isCollecting else { collectingShown = false; return }
                try? await Task.sleep(nanoseconds: UInt64(HeroBrain.collectingDelay * 1_000_000_000))
                if !Task.isCancelled { collectingShown = true }
            }
    }
}
