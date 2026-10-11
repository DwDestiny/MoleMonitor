// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelData and the mode (quiet or problem) from the layout plan.
// Output: The hero block: the dog, the headline, the subtitle and the lamps.
// Pos: First block of the status card (docs/DESIGN.md 2.2). Quiet mode: dog 104 x 78 and three lamp rows. Problem mode: dog 72 x 54, headline, lamp row.
//      DogView is I2's view. Here it is a placeholder call with the fixed DogInput.

import SwiftUI

// MARK: - Texts

enum HeroText {
    /// "5 分钟前", "2 小时前". Whole minutes, never a negative value.
    static func ago(since: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    static func problemTitle(_ data: PanelData) -> String {
        let problems = data.problems
        if problems.count == 1, let v = problems.first { return PanelFormat.titled(v.item, v.level) }
        return "\(problems.count) 项需要处理"
    }

    /// Headline and duration of a single problem. Multi-problem mode has no subtitle.
    static func problemSubtitle(_ data: PanelData) -> String? {
        let problems = data.problems
        guard problems.count == 1, let v = problems.first else { return nil }
        var text = v.headline
        if let since = v.since { text += " · 已持续 " + PanelFormat.duration(seconds: data.now.timeIntervalSince(since)) }
        return text
    }

    static func quietTitle(_ data: PanelData) -> String {
        if data.isCollecting { return "正在统计" }
        if data.staleSince != nil { return "数据已过期" }
        return "一切正常"
    }

    static func quietSubtitle(_ data: PanelData) -> String? {
        if data.isCollecting { return "首个数据约 30 秒后出现" }
        if let since = data.staleSince {
            return "最后数据 " + PanelFormat.clock(since) + "，" + ago(since: since, now: data.now)
        }
        return nil
    }

    /// The text after the lamp name in the quiet mode.
    static func lampValue(_ v: ItemVerdict, _ data: PanelData) -> String {
        switch v.level {
        case .unknown, .notApplicable: return "统计中"
        case .stale: return "已过期"
        default: break
        }
        let c = data.current
        switch v.item {
        case .thermal:
            return PanelFormat.thermalWord(c.thermal)
        case .memory:
            var text = PanelFormat.pressureWord(c.pressure)
            if let swap = c.swapUsed { text += " · swap " + PanelFormat.swap(swap) }
            let arrow = PanelFormat.trendArrow(c.swapTrend)
            if !arrow.isEmpty { text += " " + arrow }
            return text
        case .cpu:
            return PanelFormat.percent(c.cpuPercent)
        case .disk:
            return PanelFormat.levelWord(v.level)
        case .power:
            return PanelFormat.percent(c.batteryPercent)
        }
    }
}

// MARK: - Hero

struct PanelHero: View {
    let data: PanelData
    let quiet: Bool

    var body: some View {
        if quiet {
            QuietHero(data: data)
        } else {
            ProblemHero(data: data)
        }
    }
}

private struct HeroDog: View {
    let data: PanelData
    let size: CGSize

    var body: some View {
        DogView(input: data.dogInput, size: size)
            .opacity(data.isCollecting ? 0.45 : 1)
            .saturation(data.staleSince != nil ? 0 : 1)
            .frame(width: size.width, height: size.height)
            .uiTestFrame("dog")
            .accessibilityHidden(true)
    }
}

// MARK: Quiet mode

private struct QuietHero: View {
    let data: PanelData
    @Environment(\.tok) private var tok

    private var titleColor: Color { data.staleSince != nil ? tok.textWarning : tok.textPrimary }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HeroDog(data: data, size: CGSize(width: 104, height: 78))
            VStack(alignment: .leading, spacing: 4) {
                Text(HeroText.quietTitle(data))
                    .font(PanelFont.headline)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .uiTestFrame("txt.hero.title")
                    .accessibilityIdentifier("label.summary")
                if let sub = HeroText.quietSubtitle(data) {
                    Text(sub)
                        .font(PanelFont.footnote)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiTestFrame("txt.hero.subtitle")
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(data.lamps, id: \.item) { v in
                        QuietLampRow(verdict: v, data: data)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: PanelMetrics.heroQuiet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.hero")
    }
}

private struct QuietLampRow: View {
    let verdict: ItemVerdict
    let data: PanelData
    @Environment(\.tok) private var tok

    var body: some View {
        let value = HeroText.lampValue(verdict, data)
        HStack(spacing: 6) {
            LampView(level: verdict.level, size: 8)
                .uiTestFrame("lamp." + verdict.item.rawValue)
            Text(verdict.item.label)
                .font(PanelFont.body)
                .foregroundStyle(tok.textPrimary)
                .frame(width: 34, alignment: .leading)
                .lineLimit(1)
            Text(value)
                .font(PanelFont.footnote)
                .monospacedDigit()
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .numericChange(value)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("lamp." + verdict.item.rawValue)
        .accessibilityLabel(Text(verdict.item.label + PanelFormat.levelWord(verdict.level)))
        .accessibilityValue(Text(value))
    }
}

// MARK: Problem mode

private struct ProblemHero: View {
    let data: PanelData
    @Environment(\.tok) private var tok

    private var titleColor: Color {
        guard let first = data.problems.first else { return tok.textPrimary }
        return tok.levelText(first.level)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HeroDog(data: data, size: CGSize(width: 72, height: 54))
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(HeroText.problemTitle(data))
                    .font(PanelFont.title)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .uiTestFrame("txt.hero.title")
                    .accessibilityIdentifier("label.summary")
                if let sub = HeroText.problemSubtitle(data) {
                    Text(sub)
                        .font(PanelFont.footnote)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .uiTestFrame("txt.hero.subtitle")
                }
                Spacer(minLength: 4)
                FlowLayout(spacing: 10, lineSpacing: 4) {
                    ForEach(data.lamps, id: \.item) { v in
                        ProblemLamp(verdict: v)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: PanelMetrics.heroProblem, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.hero")
    }
}

/// A lamp with its name. Problem lamps are 10 pt and bold. Normal lamps are 6 pt and quieter.
private struct ProblemLamp: View {
    let verdict: ItemVerdict
    @Environment(\.tok) private var tok

    private var isProblem: Bool { verdict.level == .yellow || verdict.level == .red }

    var body: some View {
        HStack(spacing: 4) {
            LampView(level: verdict.level, size: isProblem ? 10 : 6)
                .uiTestFrame("lamp." + verdict.item.rawValue)
            Text(verdict.item.label)
                .font(isProblem ? PanelFont.callout : PanelFont.footnote)
                .foregroundStyle(isProblem ? tok.textPrimary : tok.textSecondary)
                .lineLimit(1)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("lamp." + verdict.item.rawValue)
        .accessibilityLabel(Text(verdict.item.label + PanelFormat.levelWord(verdict.level)))
    }
}
