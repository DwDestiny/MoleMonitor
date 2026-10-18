// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The item verdicts, the current readings, the app list, the status file, the data state and the clock of one data point
//        (HeroFacts.make) (docs/DESIGN_V3.md 4.1).
// Output: HeroFacts (what the headline needs from one data point), HeroBrain (the headline text with its 30 s number rule, the
//         0.5 s collecting delay and the subline under a one-line headline) and HeroProgress (how many of the 6 readings have arrived).
// Pos: Pure logic of the headline block. Foundation only, so the rules run in the Core tests (HeroLogicTests). PanelHero.swift (App)
//      wraps HeroBrain in an ObservableObject. The dog, its gaits, taps, eggs and one-shots were deleted (U10, 2026-10-18).

import Foundation

/// What the headline reads from one data point. Equatable, so the view updates the brain only when a new data point arrives.
struct HeroFacts: Equatable {
    var bubble: BubbleInput
    /// Problem items in ProblemOrder ("item:level:reason"). A change updates the text at once.
    var problemKey: [String]
    var problemItems: [HealthItem]
    /// Time of the last reading. The subline of fresh data shows its clock.
    var sampledAt: Date? = nil
    var now: Date

    var hasProblem: Bool { !problemItems.isEmpty }

    static func make(verdicts: [ItemVerdict], current c: CurrentReadings, apps: [AppUsage], status: StatusFile?,
                     dataState: DataState, now: Date, includeAppNames: Bool) -> HeroFacts {
        let ordered = ProblemOrder.problems(verdicts)
        let problems = ordered.map { problem($0, current: c, apps: apps, status: status, now: now, includeAppNames: includeAppNames) }
        let bubble = BubbleInput(dataState: dataState, cpuPercent: c.cpuPercent, problems: problems,
                                 collected: HeroProgress.done(c))
        let key = ordered.map { "\($0.item.rawValue):\($0.level.rawValue):\($0.reasonCode)" }
        return HeroFacts(bubble: bubble, problemKey: key, problemItems: ordered.map(\.item), sampledAt: c.sampledAt, now: now)
    }

    /// The evidence of one problem for the headline templates (4.11 placeholder table).
    static func problem(_ v: ItemVerdict, current c: CurrentReadings, apps: [AppUsage], status: StatusFile?, now: Date,
                        includeAppNames: Bool) -> BubbleProblem {
        var number: Double?
        var bytes: Int64?
        var app: String?
        switch v.item {
        case .disk:
            if v.reasonCode.hasPrefix("growth_") {
                bytes = status?.items.disk.growth[String(v.reasonCode.dropFirst("growth_".count))]?.bytes
            } else {
                bytes = c.diskAvailable
            }
        case .memory:
            number = c.memoryPressurePercent.map(Double.init)
            bytes = v.reasonCode == "swap_growth" ? c.swapGrowth30m : c.swapUsed
        case .cpu:
            if v.reasonCode == "app_saturated" {
                let marker = " 占满一个核"
                let name = v.headline.hasSuffix(marker) ? String(v.headline.dropLast(marker.count)) : nil
                let known = name.flatMap { n in apps.first { $0.name == n } }
                let top = apps.filter { !$0.isSystem }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
                number = known?.cpuPercent ?? top?.cpuPercent
                if includeAppNames, let name, name != "某个 App" { app = name }
            } else {
                number = (v.level == .red ? c.cpuMean10m : c.cpuMean5m) ?? c.cpuPercent
            }
        case .thermal:
            break
        case .power:
            if v.reasonCode == "sleep_drain" {
                number = firstNumber(v.headline)
            } else {
                number = c.awakeDrainPerHour ?? firstNumber(v.headline)
            }
        }
        let seconds = v.since.map { max(0, now.timeIntervalSince($0)) }
        return BubbleProblem(item: v.item, level: v.level, reasonCode: v.reasonCode, number: number, app: app, bytes: bytes, seconds: seconds)
    }

    /// The first decimal number of a text ("睡眠掉电 4.2%/小时" gives 4.2).
    static func firstNumber(_ text: String) -> Double? {
        var digits = ""
        for ch in text {
            if ch.isASCII, ch.isNumber || (ch == "." && !digits.isEmpty && !digits.contains(".")) {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        if digits.hasSuffix(".") { digits.removeLast() }
        return Double(digits)
    }
}

/// How many of the 6 readings of the panel rows have arrived (DESIGN_V3.md 4.1 rule 6, 5.5). A nil reading has not arrived.
enum HeroProgress {
    static func done(_ c: CurrentReadings) -> Int {
        let arrived: [Bool] = [c.cpuPercent != nil, c.memoryPressurePercent != nil, c.diskAvailable != nil, c.rx != nil,
                               c.batteryPercent != nil || c.powerSource != nil, c.thermal != nil]
        return arrived.filter { $0 }.count
    }
}

/// The headline between data points. All times come from the caller, so the tests can drive it.
struct HeroBrain {
    static let numberSeconds = 30.0
    /// The collecting title shows only after this many seconds without data (DESIGN_V3.md 4.1 rule 6).
    static let collectingDelay = 0.5

    private(set) var facts: HeroFacts
    private(set) var text: BubbleText
    private var textKey = ""
    private var textAt: Date

    /// The 13 pt line under a one-line headline, or nil (BubbleCopy.subline). It follows every data point, so the clock stays current.
    var subline: String? {
        BubbleCopy.subline(for: facts.bubble, headline: text, sampledAt: facts.sampledAt, now: facts.now)
    }

    init(facts: HeroFacts) {
        self.facts = facts
        text = BubbleText(main: "")
        textAt = facts.now
        refreshText(force: true)
    }

    /// A new data point.
    mutating func update(_ f: HeroFacts) {
        let changed = f.problemKey != facts.problemKey
        facts = f
        refreshText(force: changed)
    }

    /// The headline text. Only a change of state (data state, problem set, collected count) changes it at once.
    /// A number alone changes it at most every 30 s.
    private mutating func refreshText(force: Bool) {
        let next = BubbleCopy.text(for: facts.bubble, now: facts.now)
        var state = ""
        switch facts.bubble.dataState {
        case .fresh: state = "fresh"
        case .collecting: state = "collecting \(facts.bubble.collected)"
        case .stale(let at): state = "stale \(at.timeIntervalSince1970)"
        }
        let band = facts.bubble.cpuPercent.map { $0 >= 80 ? 3 : ($0 >= 40 ? 2 : ($0 >= 10 ? 1 : 0)) } ?? -1
        let key = [state, facts.problemKey.joined(separator: ","), "\(band)"].joined(separator: "|")
        if force || key != textKey || facts.now.timeIntervalSince(textAt) >= HeroBrain.numberSeconds {
            text = next
            textKey = key
            textAt = facts.now
        }
    }
}
