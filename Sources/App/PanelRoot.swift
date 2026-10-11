// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (its layout plan, data and UI state) and the entrance kind.
// Output: The whole status card: pinned hero, scrolling middle area, pinned footer. Size 328 pt x plan height.
// Pos: Root of the SwiftUI tree (docs/DESIGN.md 8.3). It renders the plan in order and never sorts.
//      The height is set by AppKit through NSPopover.contentSize. SwiftUI never animates the height.
//      No Timer and no TimelineView here. The view tree is destroyed when the popover closes.

import AppKit
import SwiftUI

// MARK: - Entrance

/// How the card appears. `full` plays once per app start, `fade` is every later open, `none` is for static renders.
enum PanelEntrance {
    case full, fade, none
}

/// Remembers whether the full entrance has played since the app started.
enum PanelEntranceGate {
    private static var played = false

    static func next() -> PanelEntrance {
        if played { return .fade }
        played = true
        return .full
    }

#if UITEST
    /// Test only: lets the UI regression play the full entrance a second time in one process.
    static func resetForTest() { played = false }
#endif
}

/// Opacity, a rise of 8 pt and the main spring, delayed by the group index times 40 ms.
/// Reduce Motion removes the rise and the delay. A static render shows the end state at once.
private struct StageModifier: ViewModifier {
    let group: Int
    let revealed: Bool
    let entrance: PanelEntrance
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: rise)
            .animation(animation, value: revealed)
    }

    private var rise: CGFloat {
        if revealed || entrance != .full || reduceMotion { return 0 }
        return 8
    }

    private var animation: Animation? {
        switch entrance {
        case .none: return nil
        case .fade: return Animation.easeOut(duration: 0.15)
        case .full:
            if reduceMotion { return Animation.easeOut(duration: 0.15) }
            return PanelMotion.spring.delay(PanelMotion.stagger * Double(group))
        }
    }
}

private extension View {
    func stage(_ group: Int, revealed: Bool, entrance: PanelEntrance, reduceMotion: Bool) -> some View {
        modifier(StageModifier(group: group, revealed: revealed, entrance: entrance, reduceMotion: reduceMotion))
    }
}

// MARK: - Root

struct PanelRoot: View {
    @ObservedObject var model: PanelModel
    var entrance: PanelEntrance = .none

    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool

    init(model: PanelModel, entrance: PanelEntrance = .none) {
        self.model = model
        self.entrance = entrance
        _revealed = State(initialValue: entrance == .none)
    }

    private var plan: PanelLayoutPlan { model.layoutPlan }

    var body: some View {
        let tok = PanelTokens(scheme: scheme)
        content
            .frame(width: PanelMetrics.width, height: plan.height, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.tok, tok)
            .animation(PanelMotion.spring, value: plan.sections)
            .onAppear {
                if !revealed { revealed = true }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel.root")
            .uiTestFrame("panel.root")
    }

    // MARK: Layout

    private var heroSection: PanelSection? {
        guard let first = plan.sections.first, case .hero = first else { return nil }
        return first
    }

    private var footerSection: PanelSection? {
        guard let last = plan.sections.last, case .footer = last else { return nil }
        return last
    }

    private var middleSections: [PanelSection] {
        var list = plan.sections
        if heroSection != nil { list.removeFirst() }
        if footerSection != nil, !list.isEmpty { list.removeLast() }
        return list
    }

    private func gap(before section: PanelSection) -> Double {
        guard let index = plan.sections.firstIndex(of: section), index > 0 else { return 0 }
        return PanelGeometry.gap(plan.sections[index - 1], section)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let hero = heroSection {
                staged(hero)
                    .padding(.horizontal, PanelMetrics.padding)
                    .padding(.top, PanelMetrics.padding)
            }
            middle
            if let footer = footerSection {
                staged(footer)
                    .padding(.horizontal, PanelMetrics.padding)
                    .padding(.top, gap(before: footer))
                    .padding(.bottom, PanelMetrics.padding)
            }
        }
    }

    @ViewBuilder
    private var middle: some View {
        let sections = middleSections
        if snapshot {
            VStack(spacing: 0) {
                middleStack(sections)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    middleStack(sections)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(PanelMotion.spring) { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func middleStack(_ sections: [PanelSection]) -> some View {
        VStack(spacing: 0) {
            ForEach(sections, id: \.key) { section in
                staged(section)
                    .padding(.top, gap(before: section))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, PanelMetrics.padding)
    }

    private func staged(_ section: PanelSection) -> some View {
        sectionView(section)
            .uiTestFrame("sec." + section.key)
            .stage(PanelGeometry.group(section), revealed: revealed, entrance: entrance, reduceMotion: reduceMotion)
    }

    // MARK: One section

    @ViewBuilder
    private func sectionView(_ section: PanelSection) -> some View {
        switch section {
        case .hero(let quiet):
            PanelHero(data: model.data, quiet: quiet)
        case .trendStrip:
            TrendStrip(data: model.data)
        case .problemCard(let item, let compact, let evidence):
            ProblemCard(model: model, item: item, compact: compact, evidenceHeight: evidence)
        case .problemRow(let item, let compact):
            ProblemRow(model: model, item: item, compact: compact)
        case .copyCTA(let item):
            CopyCTA(model: model, item: item)
        case .normalSummary(let items):
            NormalSummary(items: items)
        case .appsDisclosure(let expanded):
            AppsDisclosure(model: model, expanded: expanded, compact: plan.compressions.contains(.disclosure26))
        case .moreDisclosure(let expanded, let apps, let auth):
            MoreDisclosure(model: model, expanded: expanded, includesApps: apps, includesAuthorization: auth,
                           compact: plan.compressions.contains(.disclosure26))
        case .authorization:
            AuthorizationRow(model: model)
        case .footer(let quiet):
            PanelFooter(model: model, quiet: quiet)
        }
    }
}

extension PanelSection {
    /// Stable identity for ForEach and transitions.
    var key: String { PanelGeometry.key(self) }
}
