// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, UI state and the visible screen height (docs/DESIGN.md 2.3, 2.5, 2.11, 8.1).
// Output: A PanelLayoutPlan: section order, one of three tier heights (332, 560, 620), compression steps.
// Pos: Pure layout planning; the SwiftUI card only renders the plan. Foundation only. Owner I1, main user I3.
// SKELETON: PanelLayout.plan returns three fixed plans by problem count. No evidence height range, no compression.

import Foundation

enum PanelMetrics {
    static let width = 328.0, padding = 16.0, sectionGap = 12.0, rowGap = 4.0, cardRowGap = 8.0
    static let heroQuiet = 112.0, heroProblem = 84.0, trendStrip = 56.0
    static let heightQuiet = 332.0, heightSingle = 560.0, heightMulti = 620.0   // The only 3 tiers
    static let cardChrome = 160.0, cardChromeCompact = 148.0                   // Problem card shell, without the evidence area
    static let evidenceMin = 68.0, evidenceMax = 114.0                         // Elastic range of the evidence area
    static let problemRow = 40.0, problemRowCompact = 36.0
    static let cta = 36.0, normalSummary = 28.0
    static let disclosure = 30.0, disclosureCompact = 26.0
    static let authorization = 28.0, footer = 32.0
    static let appsExpanded = 156.0, moreExpanded = 188.0                      // Inner scroll content, does not change the height
}

enum PanelSection: Equatable {
    case hero(quiet: Bool)
    case trendStrip
    case problemCard(HealthItem, compact: Bool, evidenceHeight: Double)
    case problemRow(HealthItem, compact: Bool)
    case copyCTA(HealthItem)
    case normalSummary([HealthItem])          // Names only, no values. Hidden at compression step 4.
    case appsDisclosure(expanded: Bool)
    case moreDisclosure(expanded: Bool, includesApps: Bool, includesAuthorization: Bool)
    case authorization
    case footer(quiet: Bool)
}

/// Compression steps, applied in this order (DESIGN.md 2.11).
enum PanelCompression: Int, CaseIterable {
    case mergeApps = 1, disclosure26, compactCard, compactRows, hideSummary, foldAuthorization
}

struct PanelLayoutPlan: Equatable {
    var quiet: Bool
    var tier: Double                       // 332, 560 or 620
    var sections: [PanelSection]
    var height: Double                     // Equals tier, or the smaller of tier and the visible height on a small screen
    var compressions: [PanelCompression]
    var scrollsMore: Bool
}

struct PanelLayoutInput: Equatable {
    var verdicts: [ItemVerdict]
    var showAuthorization: Bool
    var expandedProblem: HealthItem?   // Nil means the first item in order
    var appsExpanded: Bool
    var moreExpanded: Bool
    var screenVisibleHeight: Double    // Maximum height = min(tier, screen visible height - 40)
}

enum PanelLayout {
    /// SKELETON: 0 problem items give the quiet plan (332), 1 gives the single plan (560), 2 or more give the
    /// multi plan (620). Problem items are the yellow and red verdicts in input order. The evidence height is
    /// fixed at 102. Compression, height clamping and the "disclosure includes" flags are not computed.
    static func plan(_ input: PanelLayoutInput) -> PanelLayoutPlan {
        let problems = ProblemOrder.problems(input.verdicts).map { $0.item }
        var sections = [PanelSection]()

        if problems.isEmpty {
            sections.append(.hero(quiet: true))
            sections.append(.trendStrip)
            sections.append(.appsDisclosure(expanded: input.appsExpanded))
            sections.append(.moreDisclosure(expanded: input.moreExpanded, includesApps: false, includesAuthorization: false))
            if input.showAuthorization { sections.append(.authorization) }
            sections.append(.footer(quiet: true))
            return PanelLayoutPlan(quiet: true, tier: PanelMetrics.heightQuiet, sections: sections,
                                   height: PanelMetrics.heightQuiet, compressions: [], scrollsMore: false)
        }

        let expanded = input.expandedProblem.flatMap { problems.contains($0) ? $0 : nil } ?? problems[0]
        let others = problems.filter { $0 != expanded }
        sections.append(.hero(quiet: false))
        sections.append(.problemCard(expanded, compact: false, evidenceHeight: 102))
        for item in others.prefix(3) { sections.append(.problemRow(item, compact: false)) }
        sections.append(.copyCTA(expanded))
        let normal = input.verdicts.map { $0.item }.filter { !problems.contains($0) }
        if !normal.isEmpty { sections.append(.normalSummary(normal)) }
        sections.append(.appsDisclosure(expanded: input.appsExpanded))
        sections.append(.moreDisclosure(expanded: input.moreExpanded, includesApps: false, includesAuthorization: false))
        if input.showAuthorization { sections.append(.authorization) }
        sections.append(.footer(quiet: false))
        let tier = problems.count == 1 ? PanelMetrics.heightSingle : PanelMetrics.heightMulti
        return PanelLayoutPlan(quiet: false, tier: tier, sections: sections, height: tier,
                               compressions: [], scrollsMore: others.count > 3)
    }
}
