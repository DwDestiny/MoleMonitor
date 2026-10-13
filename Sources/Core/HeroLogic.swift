// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The item verdicts, the current readings, the app list, the status file, the data state and the clock of one data point
//        (HeroFacts.make), and the user events of the hero: open, tap, long press, copy (docs/DESIGN_V2.md 4.4, 4.8, 4.10, 4.11).
// Output: HeroFacts (what the stage and the bubble need from one data point) and HeroBrain, the state of the hero:
//         the DogStagePlan of the director, the bubble text with its 30 s number rule, the event texts, the one-shot requests,
//         the heart bursts and the bubble pops. HeroMemory holds the counters that live for the process (never on disk, 4.8 rule 4).
// Pos: Pure logic of the hero. Foundation only, so the rules run in the Core tests (HeroLogicTests). PanelHero.swift (App) wraps
//      HeroBrain in an ObservableObject, starts the 2.5 s event timer and hands the plan to DogSpriteView. WP-D owns the file.

import Foundation

/// What the hero reads from one data point. Equatable, so the view steps the director only when a new data point arrives.
struct HeroFacts: Equatable {
    var action: DogActionInput
    var bubble: BubbleInput
    /// Problem items in ProblemOrder ("item:level:reason"). A change pops the bubble and updates its text at once (4.10 rules 5, 6).
    var problemKey: [String]
    var problemItems: [HealthItem]
    var now: Date
    var hasBattery: Bool

    var hasProblem: Bool { !problemItems.isEmpty }

    static func make(verdicts: [ItemVerdict], current c: CurrentReadings, apps: [AppUsage], status: StatusFile?,
                     dataState: DataState, now: Date, includeAppNames: Bool, night: Bool) -> HeroFacts {
        func level(_ item: HealthItem) -> HealthLevel { verdicts.first { $0.item == item }?.level ?? .unknown }
        let action = DogActionInput(dataState: dataState, cpuPercent: c.cpuPercent, thermal: level(.thermal), memory: level(.memory),
                                    disk: level(.disk), power: level(.power), isNight: night, cpu: level(.cpu))
        let ordered = ProblemOrder.problems(verdicts)
        let problems = ordered.map { problem($0, current: c, apps: apps, status: status, now: now, includeAppNames: includeAppNames) }
        let bubble = BubbleInput(dataState: dataState, cpuPercent: c.cpuPercent, isNight: night, problems: problems)
        let key = ordered.map { "\($0.item.rawValue):\($0.level.rawValue):\($0.reasonCode)" }
        let battery = c.batteryPercent != nil || c.powerSource == .battery
        return HeroFacts(action: action, bubble: bubble, problemKey: key, problemItems: ordered.map(\.item), now: now, hasBattery: battery)
    }

    /// The evidence of one problem for the bubble templates (4.11 placeholder table).
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

/// Counters of the process: taps, the last day the panel opened, the week of the Friday text, the no-battery text.
struct HeroMemory: Equatable {
    var tapTextIndex = 0
    var tapDay: Date?
    var tapsToday = 0
    var lastOpenDay: Date?
    var fridayWeek: Int?
    var noBatteryShown = false
}

/// What the view must do after a step of the brain.
struct HeroEffects: Equatable {
    /// Play this one-shot (wag or notice) with the repeat count.
    var oneShot: DogAction?
    var repeats = 1
    /// Number of hearts to send up.
    var hearts = 0
    /// Pop the bubble (scale 0.85 to 1, 4.10 rule 5).
    var pop = false
    /// An event text is on: end it after `HeroBrain.eventSeconds`.
    var eventStarted = false
    /// A copy text is on: end it after `HeroBrain.eventSeconds`.
    var copyStarted = false
}

/// The hero state between data points. All times come from the caller, so the tests can drive it.
struct HeroBrain {
    static let eventSeconds = 2.5
    static let numberSeconds = 30.0
    static let tapWindow = 3.0
    static let tapsForNotice = 5

    private(set) var director = DogDirector()
    private(set) var facts: HeroFacts
    private(set) var plan: DogStagePlan
    private(set) var text: BubbleText
    private(set) var event: BubbleEvent = .none
    private(set) var copyText: String?
    private var textKey = ""
    private var textAt: Date
    private var tapTimes = [Double]()

    init(facts: HeroFacts) {
        self.facts = facts
        plan = director.step(dt: 0, input: facts.action)
        text = BubbleText(main: "")
        textAt = facts.now
        refreshText(force: true)
    }

    /// The bubble as the view shows it: a copy text replaces the main line, the second line stays.
    var display: BubbleText {
        if let copyText { return BubbleText(main: copyText, sub: text.sub) }
        return text
    }

    /// A new data point.
    mutating func update(_ f: HeroFacts, reduceMotion: Bool) -> HeroEffects {
        var out = HeroEffects()
        let dt = max(0, f.now.timeIntervalSince(facts.now))
        let added = Set(f.problemItems).subtracting(facts.problemItems)
        let changed = f.problemKey != facts.problemKey
        facts = f
        plan = director.step(dt: dt, input: f.action)
        if !added.isEmpty, case .fresh = f.action.dataState, let one = oneShot(.notice, reduceMotion: reduceMotion) {
            out.oneShot = one
        }
        refreshText(force: changed)
        out.pop = changed
        return out
    }

    /// The panel opened: the bubble pops, and one easter egg may show (4.8). `eggs` is false in the UI test build.
    mutating func appeared(clock: Date, calendar: Calendar, lastNightClean: Bool, eggs: Bool, memory: inout HeroMemory) -> HeroEffects {
        var out = HeroEffects(pop: true)
        let day = calendar.startOfDay(for: clock)
        let firstToday = memory.lastOpenDay != day
        memory.lastOpenDay = day
        guard eggs, !facts.hasProblem, case .fresh = facts.action.dataState else { return out }
        let hour = calendar.component(.hour, from: clock)
        let week = calendar.component(.weekOfYear, from: clock) + 100 * calendar.component(.yearForWeekOfYear, from: clock)
        var egg: BubbleEvent?
        if firstToday, (6..<10).contains(hour), lastNightClean {
            egg = .morning
        } else if calendar.component(.weekday, from: clock) == 6, (18..<22).contains(hour), (facts.action.cpuPercent ?? 100) < 20,
                  memory.fridayWeek != week {
            memory.fridayWeek = week
            egg = .friday
        } else if !facts.hasBattery, !memory.noBatteryShown {
            memory.noBatteryShown = true
            egg = .noBattery
        }
        if let egg {
            start(egg)
            out.eventStarted = true
        }
        return out
    }

    /// A tap on the dog at time `t` (seconds, any clock). 5 taps in 3 s: notice and "别摸啦". Every 10th tap of the day: the count text.
    mutating func tap(at t: Double, day: Date, reduceMotion: Bool, memory: inout HeroMemory) -> HeroEffects {
        var out = HeroEffects(pop: true, eventStarted: true)
        tapTimes = tapTimes.filter { t - $0 < HeroBrain.tapWindow } + [t]
        countTap(day: day, memory: &memory)
        if tapTimes.count >= HeroBrain.tapsForNotice {
            tapTimes = []
            out.oneShot = oneShot(.notice, reduceMotion: reduceMotion)
            start(.tooManyTaps)
            return out
        }
        out.oneShot = oneShot(.wag, reduceMotion: reduceMotion)
        out.repeats = 2
        out.hearts = reduceMotion ? 0 : 3
        if memory.tapsToday % 10 == 0 {
            start(.petCount(memory.tapsToday))
        } else {
            start(.petTap(memory.tapTextIndex))
            memory.tapTextIndex += 1
        }
        return out
    }

    /// A press of 600 ms or more: wag 3 times, 5 hearts, "嘿嘿，好舒服".
    mutating func longPress(day: Date, reduceMotion: Bool, memory: inout HeroMemory) -> HeroEffects {
        var out = HeroEffects(pop: true, eventStarted: true)
        countTap(day: day, memory: &memory)
        out.oneShot = oneShot(.wag, reduceMotion: reduceMotion)
        out.repeats = 3
        out.hearts = reduceMotion ? 0 : 5
        start(memory.tapsToday % 10 == 0 ? .petCount(memory.tapsToday) : .longPress)
        return out
    }

    /// The copy text of the footer (WP-C `PanelModel.copyBubble`). A success wags twice; a failure only shows its text.
    mutating func copied(_ value: String?, reduceMotion: Bool) -> HeroEffects {
        guard let value, !value.isEmpty else { return HeroEffects() }
        var out = HeroEffects(pop: true, copyStarted: true)
        copyText = value
        if value.contains("已复制") {
            out.oneShot = oneShot(.wag, reduceMotion: reduceMotion)
            out.repeats = 2
        }
        return out
    }

    mutating func endEvent() {
        event = .none
        refreshText(force: true)
    }

    mutating func endCopy() {
        copyText = nil
    }

    // MARK: Private

    private mutating func countTap(day: Date, memory: inout HeroMemory) {
        if memory.tapDay != day {
            memory.tapDay = day
            memory.tapsToday = 0
        }
        memory.tapsToday += 1
    }

    private mutating func start(_ e: BubbleEvent) {
        event = e
        refreshText(force: true)
    }

    /// A one-shot only plays where 4.4 lets it (priority 5: after stale, collecting, thermal red, memory red and the tired lie).
    private func oneShot(_ action: DogAction, reduceMotion: Bool) -> DogAction? {
        guard !reduceMotion else { return nil }
        var input = facts.action
        input.oneShot = action
        return DogStage.base(input, gait: director.gait).0 == action ? action : nil
    }

    /// The bubble text. Only a change of state (data state, problem set, gait, night, event) changes it at once.
    /// A number alone changes it at most every 30 s (4.10 rule 6).
    private mutating func refreshText(force: Bool) {
        var input = facts.bubble
        input.event = event
        input.gait = director.gait
        let next = BubbleCopy.text(for: input)
        var state = ""
        switch input.dataState {
        case .fresh: state = "fresh"
        case .collecting: state = "collecting"
        case .stale(let at): state = "stale \(at.timeIntervalSince1970)"
        }
        let key = [state, facts.problemKey.joined(separator: ","), director.gait.rawValue, input.isNight ? "night" : "day",
                   "\(event)", next.sub ?? ""].joined(separator: "|")
        if force || key != textKey || facts.now.timeIntervalSince(textAt) >= HeroBrain.numberSeconds {
            text = next
            textKey = key
            textAt = facts.now
        }
    }
}
