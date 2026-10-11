// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Fixtures and helpers (expect, section, now, GB) defined in main.swift.
// Output: Assertions for PanelLayout and the 7 PreviewCase plans (docs/DESIGN.md 9.1).
// Pos: Called from main.swift via runLayoutTests(); no top-level code in this file. Owner I1.
//      The first test block asserts every row of the table in DESIGN.md 2.11.

import Foundation

private func lv(_ item: HealthItem, _ level: HealthLevel, since minutes: Double = 30) -> ItemVerdict {
    ItemVerdict(item: item, level: level, reasonCode: "x", headline: "x",
                since: level == .green ? nil : now.addingTimeInterval(-minutes * 60), levelChangedAt: nil, alert: nil)
}

/// All five items. `problems` lists the items that are yellow; the rest are green.
private func verdicts(_ problems: [(HealthItem, HealthLevel, Double)]) -> [ItemVerdict] {
    var out = [ItemVerdict]()
    for item in HealthItem.allCases {
        if let p = problems.first(where: { $0.0 == item }) { out.append(lv(item, p.1, since: p.2)) } else { out.append(lv(item, .green)) }
    }
    return out
}

private func layout(_ v: [ItemVerdict], auth: Bool = false, expanded: HealthItem? = nil, screen: Double = 1000) -> PanelLayoutPlan {
    PanelLayout.plan(PanelLayoutInput(verdicts: v, showAuthorization: auth, expandedProblem: expanded, appsExpanded: false,
                                      moreExpanded: false, screenVisibleHeight: screen))
}

private func evidenceOf(_ plan: PanelLayoutPlan) -> Double? {
    for s in plan.sections {
        if case let .problemCard(_, _, e) = s { return e }
    }
    return nil
}

private func compactCardOf(_ plan: PanelLayoutPlan) -> Bool {
    for s in plan.sections {
        if case let .problemCard(_, c, _) = s { return c }
    }
    return false
}

func runLayoutTests() {
    section("PanelLayout: DESIGN 2.11 table")
    let quiet = layout(verdicts([]))
    expect(quiet.quiet && quiet.tier == 332 && quiet.height == 332 && quiet.compressions.isEmpty, "quiet: 332, no compression")
    expect(quiet.sections.first == .hero(quiet: true) && quiet.sections.contains(.trendStrip), "quiet starts with the hero and the trend strip")
    expect(quiet.sections.last == .footer(quiet: true), "the footer is last")

    let quietAuth = layout(verdicts([]), auth: true)
    expect(quietAuth.tier == 332 && quietAuth.compressions == [.mergeApps], "quiet with authorization: merge apps only, got \(quietAuth.compressions)")
    expect(quietAuth.sections.contains(.authorization), "the authorization row stays in quiet mode")
    expect(!quietAuth.sections.contains(.appsDisclosure(expanded: false)), "the merged apps row is gone")
    expect(quietAuth.sections.contains(.moreDisclosure(expanded: false, includesApps: true, includesAuthorization: false)), "more includes the apps")

    let cpu = layout(verdicts([(.cpu, .yellow, 20)]))
    expect(cpu.tier == 560 && evidenceOf(cpu) == 102 && cpu.compressions.isEmpty, "single CPU: 560, evidence 102, got \(String(describing: evidenceOf(cpu)))")
    expect(!cpu.sections.contains(.appsDisclosure(expanded: false)), "the CPU card holds the apps, so there is no apps row")
    let disk = layout(verdicts([(.disk, .red, 20)]))
    expect(disk.tier == 560 && evidenceOf(disk) == 68 && disk.compressions.isEmpty, "single disk: evidence 68, got \(String(describing: evidenceOf(disk)))")
    let power = layout(verdicts([(.power, .yellow, 20)]))
    expect(evidenceOf(power) == 68 && power.compressions.isEmpty, "single power: evidence 68")
    let cpuAuth = layout(verdicts([(.cpu, .yellow, 20)]), auth: true)
    expect(evidenceOf(cpuAuth) == 70 && cpuAuth.compressions.isEmpty, "single CPU with authorization: 70, got \(String(describing: evidenceOf(cpuAuth)))")
    let diskAuth = layout(verdicts([(.disk, .red, 20)]), auth: true)
    expect(evidenceOf(diskAuth) == 70 && diskAuth.compressions == [.mergeApps], "single disk with authorization: 70 and merge apps, got \(String(describing: evidenceOf(diskAuth))) \(diskAuth.compressions)")

    let memCPU = layout(verdicts([(.memory, .red, 60), (.cpu, .yellow, 30)]))
    expect(memCPU.tier == 620 && evidenceOf(memCPU) == 114 && memCPU.compressions.isEmpty, "memory and CPU: 620, evidence 114, got \(String(describing: evidenceOf(memCPU)))")
    let diskCPU = layout(verdicts([(.disk, .red, 180), (.cpu, .yellow, 30)]))
    expect(evidenceOf(diskCPU) == 80 && diskCPU.compressions.isEmpty, "disk and CPU: 80, got \(String(describing: evidenceOf(diskCPU)))")
    let three = layout(verdicts([(.disk, .red, 180), (.memory, .red, 25), (.cpu, .yellow, 20)]))
    expect(evidenceOf(three) == 70 && three.compressions == [.mergeApps], "three items: 70 and merge apps, got \(String(describing: evidenceOf(three))) \(three.compressions)")
    let four = layout(verdicts([(.disk, .red, 180), (.memory, .red, 25), (.power, .yellow, 40), (.cpu, .yellow, 40)]))
    expect(four.tier == 620 && evidenceOf(four) == 94, "wireframe D: evidence 94, got \(String(describing: evidenceOf(four)))")
    expect(four.compressions == [.mergeApps, .disclosure26, .compactCard, .compactRows, .hideSummary], "wireframe D steps: \(four.compressions)")
    expect(compactCardOf(four), "wireframe D uses the compact card")
    let allFive = verdicts([(.thermal, .yellow, 30), (.memory, .yellow, 30), (.disk, .yellow, 30), (.power, .yellow, 30), (.cpu, .yellow, 30)])
    let five = layout(allFive)
    expect(evidenceOf(five) == 70 && five.compressions == [.disclosure26], "five items: 70 and disclosure 26, got \(String(describing: evidenceOf(five))) \(five.compressions)")
    let fiveAuth = layout(allFive, auth: true)
    expect(evidenceOf(fiveAuth) == 94 && fiveAuth.compressions == [.disclosure26, .compactCard, .compactRows, .foldAuthorization],
           "five items with authorization: 94, got \(String(describing: evidenceOf(fiveAuth))) \(fiveAuth.compressions)")
    expect(fiveAuth.sections.contains(.moreDisclosure(expanded: false, includesApps: false, includesAuthorization: true)), "authorization moves into More")
    expect(five.scrollsMore, "four other problems scroll inside the rows area")
    let rowCount = five.sections.filter { if case .problemRow = $0 { return true } else { return false } }.count
    expect(rowCount == 3, "at most 3 problem rows are shown, got \(rowCount)")

    section("PanelLayout: tiers, order, screens")
    expect(layout(verdicts([(.cpu, .yellow, 5)])).tier == layout(verdicts([(.disk, .red, 500)])).tier, "the tier does not depend on the item or the numbers")
    expect(layout([lv(.cpu, .unknown), lv(.disk, .stale)]).quiet, "unknown and stale items are not problems: quiet")
    expect(layout(verdicts([(.cpu, .red, 5), (.disk, .yellow, 50)])).tier == 620, "two problems: 620")
    let expandedCPU = layout(verdicts([(.disk, .red, 180), (.memory, .red, 25), (.power, .yellow, 40), (.cpu, .yellow, 40)]), expanded: .cpu)
    if case let .problemCard(item, _, _)? = expandedCPU.sections.dropFirst().first { expect(item == .cpu, "the chosen problem is expanded") }
    expect(expandedCPU.sections.contains(.copyCTA(.cpu)), "the CTA follows the expanded problem")
    let wrong = layout(verdicts([(.disk, .red, 180)]), expanded: .cpu)
    if case let .problemCard(item, _, _)? = wrong.sections.dropFirst().first { expect(item == .disk, "an expanded item that is not a problem falls back to the first") }
    let small = layout(verdicts([(.cpu, .yellow, 20)]), screen: 500)
    expect(small.height == 460 && small.tier == 560, "a small screen limits the height to screen - 40, got \(small.height)")
    expect(!small.compressions.isEmpty, "a small screen compresses")
    expect(layout(verdicts([]), screen: 2000).height == 332, "a large screen keeps the tier height")
    let order = ProblemOrder.problems(verdicts([(.cpu, .yellow, 5), (.disk, .red, 50)])).map { $0.item }
    expect(order == [.disk, .cpu], "the plan reads the shared order")

    section("PanelLayout: PreviewScenario cases")
    let expectedHeights: [PreviewCase: (Double, Double?)] = [.allGreen: (332, nil), .cpuYellow: (560, 102), .diskRed: (560, 68), .powerYellow: (560, 68),
                                                              .multi: (620, 94), .collecting: (332, nil), .stale: (332, nil)]
    for c in PreviewCase.allCases {
        let f = PreviewScenario.fixture(c, full: false, now: now)
        let p = layout(f.verdicts)
        let want = expectedHeights[c]!
        expect(p.tier == want.0 && evidenceOf(p) == want.1, "\(c.rawValue): tier \(p.tier) evidence \(String(describing: evidenceOf(p)))")
    }
    var last = 0.0
    var monotonic = true
    for n in 0...5 {
        let items: [(HealthItem, HealthLevel, Double)] = Array([(.thermal, HealthLevel.yellow, 30.0), (.memory, .yellow, 30), (.disk, .yellow, 30), (.power, .yellow, 30), (.cpu, .yellow, 30)].prefix(n))
        let t = layout(verdicts(items)).tier
        if t < last { monotonic = false }
        last = t
    }
    expect(monotonic, "the height never decreases when problems are added")
}
