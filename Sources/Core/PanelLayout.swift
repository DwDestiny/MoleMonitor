// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, UI state and the visible screen height (docs/DESIGN.md 2.3, 2.5, 2.11, 8.1).
// Output: A PanelLayoutPlan: section order, one of three tier heights (332, 560, 620), compression steps.
// Pos: Pure layout planning; the SwiftUI card only renders the plan. Foundation only. Owner I1, main user I3.
//      The evidence height and the compression steps follow DESIGN.md 2.11 and reproduce every row of its table.

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
    /// Problem cards that show the app list inside the card (DESIGN.md 2.3). Others get an "占用 App" row.
    static func cardIncludesApps(_ item: HealthItem) -> Bool {
        item == .cpu || item == .thermal || item == .memory
    }

    /// Layout switches that the compression steps change.
    private struct Variant {
        var mergeApps = false
        var disclosure26 = false
        var compactCard = false
        var compactRows = false
        var hideSummary = false
        var foldAuthorization = false
    }

    private struct Facts {
        var quiet: Bool
        var appsRow: Bool           // The "占用 App" row exists before any merge
        var rowCount: Int           // Problem rows shown (at most 3)
        var hasSummary: Bool
        var showAuthorization: Bool
    }

    /// Height of everything except the evidence area (problem mode) or the whole content (quiet mode).
    private static func contentHeight(_ f: Facts, _ v: Variant) -> Double {
        let disclosureHeight = v.disclosure26 ? PanelMetrics.disclosureCompact : PanelMetrics.disclosure
        var disclosure = [Double]()
        if f.appsRow && !v.mergeApps { disclosure.append(disclosureHeight) }
        disclosure.append(disclosureHeight)
        if f.showAuthorization && !v.foldAuthorization { disclosure.append(PanelMetrics.authorization) }
        var block = disclosure.reduce(0, +)
        block += PanelMetrics.rowGap * Double(disclosure.count - 1)

        let pad = 2 * PanelMetrics.padding
        if f.quiet {
            let parts: [Double] = [pad, PanelMetrics.heroQuiet, PanelMetrics.sectionGap, PanelMetrics.trendStrip,
                                   PanelMetrics.sectionGap, block, PanelMetrics.sectionGap, PanelMetrics.footer]
            return parts.reduce(0, +)
        }
        let chrome = v.compactCard ? PanelMetrics.cardChromeCompact : PanelMetrics.cardChrome
        let rowHeight = v.compactRows ? PanelMetrics.problemRowCompact : PanelMetrics.problemRow
        var rows = 0.0
        if f.rowCount > 0 {
            rows = Double(f.rowCount) * rowHeight + Double(f.rowCount - 1) * PanelMetrics.rowGap + PanelMetrics.cardRowGap
        }
        var summary = 0.0
        if f.hasSummary && !v.hideSummary { summary = PanelMetrics.normalSummary + PanelMetrics.sectionGap }
        let top: [Double] = [pad, PanelMetrics.heroProblem, PanelMetrics.sectionGap, chrome]
        let middle: [Double] = [PanelMetrics.cardRowGap, rows, PanelMetrics.cta, PanelMetrics.sectionGap, summary]
        let bottom: [Double] = [block, PanelMetrics.sectionGap, PanelMetrics.footer]
        return top.reduce(0, +) + middle.reduce(0, +) + bottom.reduce(0, +)
    }

    /// Plan of the status card. The tier depends only on the number of problem items. Numbers never change it.
    static func plan(_ input: PanelLayoutInput) -> PanelLayoutPlan {
        let problems = ProblemOrder.problems(input.verdicts).map { $0.item }
        let tier: Double
        if problems.isEmpty {
            tier = PanelMetrics.heightQuiet
        } else if problems.count == 1 {
            tier = PanelMetrics.heightSingle
        } else {
            tier = PanelMetrics.heightMulti
        }
        // Maximum height = min(tier, visible screen height - 40).
        let height = min(tier, max(0, input.screenVisibleHeight - 40))

        var expanded: HealthItem?
        var others = [HealthItem]()
        if let first = problems.first {
            var pick = first
            if let wanted = input.expandedProblem, problems.contains(wanted) { pick = wanted }
            expanded = pick
            others = problems.filter { $0 != pick }
        }
        let normal = input.verdicts.map { $0.item }.filter { !problems.contains($0) }
        let appsRow: Bool
        if let expanded { appsRow = !cardIncludesApps(expanded) } else { appsRow = true }
        let facts = Facts(quiet: problems.isEmpty, appsRow: appsRow, rowCount: min(others.count, 3),
                          hasSummary: !normal.isEmpty, showAuthorization: input.showAuthorization)

        // Compression: apply the steps in order until the evidence area reaches its minimum (quiet: until the
        // content fits). A step that changes nothing is skipped and not recorded.
        var variant = Variant()
        var applied = [PanelCompression]()
        func evidence() -> Double { height - contentHeight(facts, variant) }
        func needsMore() -> Bool {
            facts.quiet ? contentHeight(facts, variant) > height : evidence() < PanelMetrics.evidenceMin
        }
        for step in PanelCompression.allCases {
            if !needsMore() { break }
            switch step {
            case .mergeApps:
                if facts.appsRow { variant.mergeApps = true; applied.append(step) }
            case .disclosure26:
                variant.disclosure26 = true; applied.append(step)
            case .compactCard:
                if !facts.quiet { variant.compactCard = true; applied.append(step) }
            case .compactRows:
                if facts.rowCount > 0 { variant.compactRows = true; applied.append(step) }
            case .hideSummary:
                if facts.hasSummary { variant.hideSummary = true; applied.append(step) }
            case .foldAuthorization:
                if facts.showAuthorization { variant.foldAuthorization = true; applied.append(step) }
            }
        }

        var sections = [PanelSection]()
        let includesApps = variant.mergeApps
        let includesAuth = variant.foldAuthorization
        if let expanded {
            let e = min(PanelMetrics.evidenceMax, max(PanelMetrics.evidenceMin, evidence()))
            sections.append(.hero(quiet: false))
            sections.append(.problemCard(expanded, compact: variant.compactCard, evidenceHeight: e))
            for item in others.prefix(3) { sections.append(.problemRow(item, compact: variant.compactRows)) }
            sections.append(.copyCTA(expanded))
            if facts.hasSummary && !variant.hideSummary { sections.append(.normalSummary(normal)) }
        } else {
            sections.append(.hero(quiet: true))
            sections.append(.trendStrip)
        }
        if facts.appsRow && !variant.mergeApps { sections.append(.appsDisclosure(expanded: input.appsExpanded)) }
        sections.append(.moreDisclosure(expanded: input.moreExpanded, includesApps: includesApps, includesAuthorization: includesAuth))
        if facts.showAuthorization && !variant.foldAuthorization { sections.append(.authorization) }
        sections.append(.footer(quiet: facts.quiet))
        return PanelLayoutPlan(quiet: facts.quiet, tier: tier, sections: sections, height: height,
                               compressions: applied, scrollsMore: others.count > 3)
    }
}
