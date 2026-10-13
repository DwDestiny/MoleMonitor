// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (its layout plan, data and UI state) and the entrance kind.
// Output: The whole panel: the main column (352 pt: hero, six rows, anomaly area, footer) and, when open, the sidebar (320 pt).
// Pos: Root of the SwiftUI tree (docs/DESIGN_V2.md 2, 14.3). It renders the plan in order and never sorts.
//      The window (WP-B) sets the size. The content sticks to the main column side and the window clips the rest.
//      No Timer and no TimelineView here. The view tree is destroyed when the panel closes.

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

extension PanelSection {
    /// Stable identity of a section, for the UI regression registry.
    var key: String {
        switch self {
        case .hero: return "hero"
        case .rows: return "rows"
        case .anomaly: return "anomaly"
        case .footer: return "footer"
        case .problemCard(let item, _, _): return "card." + item.rawValue
        case .problemRow(let item, _): return "row." + item.rawValue
        }
    }

    /// Entrance group: hero, rows, anomaly area, footer.
    var group: Int {
        switch self {
        case .hero: return 0
        case .rows: return 1
        case .anomaly: return 2
        case .footer: return 3
        case .problemCard, .problemRow: return 1
        }
    }
}

struct PanelRoot: View {
    @ObservedObject var model: PanelModel
    var entrance: PanelEntrance = .none

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var revealed: Bool

    /// The window and the entrance read one Reduce Motion value. The UI regression can force it, as for the window (`PanelWindow.testReduceMotion`).
    private var reduceMotion: Bool {
#if UITEST
        if let forced = PanelWindow.testReduceMotion { return forced }
#endif
        return systemReduceMotion
    }

    init(model: PanelModel, entrance: PanelEntrance = .none) {
        self.model = model
        self.entrance = entrance
        _revealed = State(initialValue: entrance == .none)
    }

    private var plan: PanelLayoutPlan { model.layoutPlan }
    /// Previews and tests without a window draw the sidebar beside the main column. In the app the window hosts it (`PanelSidebar`).
    private var inlineSidebar: Bool { model.chrome == nil }
    private var edge: SidebarEdge { model.chrome?.sidebarEdge ?? .right }

    var body: some View {
        let tok = PanelTokens(scheme: scheme)
        HStack(spacing: 0) {
            if let item = model.sidebarItem, edge == .left, inlineSidebar {
                sidebar(item)
                divider(tok)
            }
            mainColumn
            if let item = model.sidebarItem, edge == .right, inlineSidebar {
                divider(tok)
                sidebar(item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .right ? .topLeading : .topTrailing)
        .environment(\.tok, tok)
        .onHover { inside in
            if !inside, model.chrome == nil { model.pointerLeft() }
        }
        .onAppear {
            if !revealed { revealed = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.root")
        .uiTestFrame("panel.root")
    }

    private func divider(_ tok: PanelTokens) -> some View {
        Rectangle().fill(tok.separator).frame(width: 0.5, height: plan.height)
    }

    private func sidebar(_ item: SidebarItem) -> some View {
        PanelSidebarView(model: model, item: item)
            .frame(width: PanelMetrics.sidebarWidth, height: plan.height, alignment: .top)
            .hoverRegion(.sidebar, model: model)
            .uiTestFrame("sidebar")
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: PanelMetrics.topPadding)
            staged(.hero) {
                PanelHero(data: model.data, quiet: plan.quiet)
                    .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.hero)
                    .hoverRegion(.neutral, model: model)
            }
            Color.clear.frame(height: PanelMetrics.heroGap)
            staged(.rows) { PanelRowsSection(model: model) }
            Color.clear.frame(height: PanelMetrics.rowsToAnomalyGap)
            staged(.anomaly) { PanelAnomalySection(model: model) }
            Color.clear.frame(height: PanelMetrics.anomalyToFooterGap)
            staged(.footer) { PanelFooter(model: model) }
            Color.clear.frame(height: PanelMetrics.bottomPadding)
        }
        .frame(width: PanelMetrics.width, height: plan.height, alignment: .top)
        .uiTestFrame("column.main")
    }

    private func staged<Content: View>(_ section: PanelSection, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .uiTestFrame("sec." + section.key)
            .stage(section.group, revealed: revealed, entrance: entrance, reduceMotion: reduceMotion)
    }
}
