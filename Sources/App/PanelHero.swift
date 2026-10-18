// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData of the panel model and the prompt setting "include app names" (docs/DESIGN_V3.md 4.1).
// Output: The headline block: one sentence in `PanelType.lead` (17 pt), left aligned, at most 2 lines, in a fixed 320 x 64 pt slot.
//         A one-line headline gets a 13 pt `text.secondary` subline 4 pt below it (HeroBrain.subline: the reading clock, the stale age,
//         or what collecting waits for). A two-line headline has none. The subline hides with the title during the 0.5 s collecting delay.
//         While the first readings arrive, the title reads "正在检查，已完成 N/6 项" and shows only after 0.5 s (HeroBrain.collectingDelay).
// Pos: First block of the panel. No dog, bubble, prop, stage or ground (U10, 2026-10-18). No status light and no background of its own:
//      the status light was deleted after review round 2 (a formless wash, X15; reason in docs/CI.md). The level is carried by the
//      problem rows (shape, tint, curve). The text comes from Core/BubbleCopy.swift through HeroBrain (Core/HeroLogic.swift).
//      The signature `PanelHero(data:quiet:)` stays for PanelRoot.

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

    /// Subline under a one-line headline (DESIGN_V3.md 4.1): 13 pt regular, 4 pt below the title. 4 + 22 + 4 + 16 pt fits in 64 pt.
    static let sublineFont = Font.system(size: 13)
    static let sublineGap: CGFloat = 4

    /// While collecting, the title waits `HeroBrain.collectingDelay` seconds. A static render (`--preview`) shows it at once.
    private var titleHidden: Bool { data.isCollecting && !collectingShown && !snapshot }

    var body: some View {
        let _ = model.sync(PanelHero.facts(data, includeAppNames: includeAppNames))
        let text = model.brain.text
        let subline = titleHidden ? nil : model.brain.subline
        VStack(alignment: .leading, spacing: PanelHero.sublineGap) {
            Text(titleHidden ? "" : text.wrapped)
                .font(PanelType.lead)
                .foregroundStyle(tok.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("label.summary")
                .accessibilityLabel(Text(titleHidden ? "" : text.main))
            if let subline {
                Text(subline)
                    .font(PanelHero.sublineFont)
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .uiTestFrame("txt.hero.subline")
                    .accessibilityIdentifier("label.summary.subline")
            }
        }
        .padding(.top, 4)
        .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.hero, alignment: .topLeading)
        .uiTestFrame("txt.hero.title")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.hero")
        .task(id: data.isCollecting) {
            guard data.isCollecting else { collectingShown = false; return }
            try? await Task.sleep(nanoseconds: UInt64(HeroBrain.collectingDelay * 1_000_000_000))
            if !Task.isCancelled { collectingShown = true }
        }
    }
}
