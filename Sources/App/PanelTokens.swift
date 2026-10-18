// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The color scheme of the environment (docs/DESIGN.md 2.5 to 2.10).
// Output: Color, type, motion and spacing tokens; text formatting helpers; shared small views (lamp, category glyph, flow layout).
// Pos: The only place that holds literal colors, sizes and durations of the status card. Views read tokens, never literals.
//      Colors are explicit per color scheme (not dynamic NSColor), so a static ImageRenderer render and the live popover agree.

import AppKit
import SwiftUI

// MARK: - Colors

struct PanelTokens {
    let dark: Bool

    init(scheme: ColorScheme) {
        dark = (scheme == .dark)
    }

    private static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    private func pick(_ light: Color, _ night: Color) -> Color {
        dark ? night : light
    }

    // Text (DESIGN.md 2.6). Contrast against the surface is at least 4.5:1.
    var textPrimary: Color { pick(Color(.sRGB, white: 0, opacity: 0.85), Color(.sRGB, white: 1, opacity: 0.85)) }
    var textSecondary: Color { pick(Color(.sRGB, white: 0, opacity: 0.62), Color(.sRGB, white: 1, opacity: 0.60)) }
    var textDanger: Color { pick(Self.rgb(0xB3261E), Self.rgb(0xFF7A72)) }
    var textWarning: Color { pick(Self.rgb(0x8F4D00), Self.rgb(0xFFB340)) }
    var textOK: Color { pick(Self.rgb(0x1B7331), Self.rgb(0x4CD964)) }
    var accent: Color { pick(Self.rgb(0x0A5FCC), Self.rgb(0x4DA3FF)) }
    var accentFill: Color { pick(Self.rgb(0x0A5FCC), Self.rgb(0x0A6CDB)) }
    var onAccent: Color { Color.white }

    // Graphics (lamps, lines). Contrast against the surface is at least 3:1.
    var lampOK: Color { pick(Self.rgb(0x1C9436), Self.rgb(0x32D74B)) }
    var lampWarning: Color { pick(Self.rgb(0xC26400), Self.rgb(0xFF9F0A)) }
    var lampDanger: Color { pick(Self.rgb(0xE5302A), Self.rgb(0xFF453A)) }
    var lampUnknown: Color { pick(Self.rgb(0x6E6E73), Self.rgb(0x8E8E93)) }
    var chartNeutral: Color { textSecondary }
    var chartNeutralFill: Color { pick(Color(.sRGB, white: 0, opacity: 0.08), Color(.sRGB, white: 1, opacity: 0.08)) }

    // Backgrounds
    // The light tint is 6 % (it was 8 %): only the first problem card has it (DESIGN.md 2.6). Dark stays at 10 %.
    var tintDanger: Color { pick(Self.rgb(0xE5302A, 0.06), Self.rgb(0xFF453A, 0.10)) }
    var tintWarning: Color { pick(Self.rgb(0xC26400, 0.06), Self.rgb(0xFF9F0A, 0.10)) }
    /// Neutral gray of a collapsed problem row (black 5 % in light, white 5 % in dark). It has no hue; the level shows in `rowBar`.
    var rowFill: Color { pick(Color(.sRGB, white: 0, opacity: 0.05), Color(.sRGB, white: 1, opacity: 0.05)) }
    var fillHover: Color { pick(Color(.sRGB, white: 0, opacity: 0.06), Color(.sRGB, white: 1, opacity: 0.08)) }
    var plotBackground: Color { pick(Color(.sRGB, white: 0, opacity: 0.04), Color(.sRGB, white: 1, opacity: 0.05)) }
    var separator: Color { pick(Color(.sRGB, white: 0, opacity: 0.10), Color(.sRGB, white: 1, opacity: 0.12)) }

    // v2 tokens (DESIGN_V2.md 3.3)
    var textTertiary: Color { pick(Color(.sRGB, white: 0, opacity: 0.40), Color(.sRGB, white: 1, opacity: 0.38)) }
    var dotNeutral: Color { pick(Color(.sRGB, white: 0, opacity: 0.28), Color(.sRGB, white: 1, opacity: 0.30)) }
    var chartLine: Color { pick(Color(.sRGB, white: 0, opacity: 0.55), Color(.sRGB, white: 1, opacity: 0.55)) }
    var chartFill: Color { pick(Color(.sRGB, white: 0, opacity: 0.06), Color(.sRGB, white: 1, opacity: 0.08)) }
    var chartGrid: Color { pick(Color(.sRGB, white: 0, opacity: 0.08), Color(.sRGB, white: 1, opacity: 0.10)) }
    var chartThreshold: Color { pick(Color(.sRGB, white: 0, opacity: 0.25), Color(.sRGB, white: 1, opacity: 0.25)) }
    /// Neutral gray, so a selected row adds no hue on a tinted row (design check 2026-10-12).
    var fillSelected: Color { pick(Color(.sRGB, white: 0, opacity: 0.09), Color(.sRGB, white: 1, opacity: 0.14)) }
    /// Plate behind the axis labels inside the plot, so a curve never runs through the text.
    var labelPlate: Color { pick(Color(.sRGB, white: 1, opacity: 0.80), Color(.sRGB, white: 0.14, opacity: 0.80)) }
    /// The 3 pt bar at the left edge of the selected row. Neutral too.
    var selectedBar: Color { pick(Color(.sRGB, white: 0, opacity: 0.55), Color(.sRGB, white: 1, opacity: 0.65)) }

    /// Value color of a row: level color for a problem, primary gray otherwise (DESIGN_V2.md 5.1).
    func valueColor(_ level: HealthLevel, problem: Bool) -> Color {
        guard problem else { return textPrimary }
        return level == .red ? textDanger : textWarning
    }

    /// Dot color of a problem level. Other dots use `dotNeutral`.
    func dotColor(_ dot: PanelDot) -> Color {
        switch dot {
        case .red: return lampDanger
        case .yellow: return lampWarning
        default: return dotNeutral
        }
    }

    /// Row background of a problem: the 6 % (light) or 10 % (dark) tint of its level. Other rows have none.
    func rowTint(_ dot: PanelDot) -> Color {
        switch dot {
        case .red: return tintDanger
        case .yellow: return tintWarning
        default: return Color.clear
        }
    }

    /// Lamp color of a level. Unknown, stale and not-applicable share the gray lamp.
    func lamp(_ level: HealthLevel) -> Color {
        switch level {
        case .green: return lampOK
        case .yellow: return lampWarning
        case .red: return lampDanger
        default: return lampUnknown
        }
    }

    /// Line color of the abnormal curve segment. In the light scheme it is a little deeper than the lamp,
    /// so a 2 pt line keeps 3:1 against the tinted card, the plot area and its own 15% fill (check M5).
    func chartHot(_ level: HealthLevel) -> Color {
        switch level {
        case .yellow: return pick(Self.rgb(0xA35200), Self.rgb(0xFF9F0A))
        case .red: return pick(Self.rgb(0xC8261F), Self.rgb(0xFF453A))
        default: return lamp(level)
        }
    }

    /// Text color of a level word. Only yellow and red use a level color.
    func levelText(_ level: HealthLevel) -> Color {
        switch level {
        case .yellow: return textWarning
        case .red: return textDanger
        default: return textSecondary
        }
    }

    /// Problem card background. Healthy levels have none.
    func tint(_ level: HealthLevel) -> Color {
        switch level {
        case .yellow: return tintWarning
        case .red: return tintDanger
        default: return Color.clear
        }
    }

    /// Background of a collapsed problem row: gray for a yellow or red row, no color, in both schemes.
    func rowBackground(_ level: HealthLevel) -> Color {
        guard level == .yellow || level == .red else { return Color.clear }
        return rowFill
    }

    /// The 3 pt bar at the left edge of a collapsed problem row, in the lamp color of the level (both schemes). Nil when the row has no level.
    func rowBar(_ level: HealthLevel) -> Color? {
        guard level == .yellow || level == .red else { return nil }
        return lamp(level)
    }

    /// Surface color assumed by the contrast tests and used behind static renders (DESIGN.md 2.6).
    static func surface(dark: Bool) -> Color {
        dark ? rgb(0x2A2A2C) : rgb(0xECECEC)
    }
}

private struct PanelTokensKey: EnvironmentKey {
    static let defaultValue = PanelTokens(scheme: .light)
}

private struct PanelSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tok: PanelTokens {
        get { self[PanelTokensKey.self] }
        set { self[PanelTokensKey.self] = newValue }
    }

    /// True in a static ImageRenderer render: no ScrollView, no Menu (AppKit-backed views do not render there).
    var panelSnapshot: Bool {
        get { self[PanelSnapshotKey.self] }
        set { self[PanelSnapshotKey.self] = newValue }
    }
}

// MARK: - Type and motion

enum PanelFont {
    static let display = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12, weight: .medium)
    static let footnote = Font.system(size: 11)
    static let caption = Font.system(size: 10)
}

enum PanelMotion {
    /// Main spring (DESIGN.md 5.1).
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Quick spring for presses and numbers.
    static let quick = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let fade = Animation.easeInOut(duration: 0.20)
    static let fadeShort = Animation.easeOut(duration: 0.15)
    static let hover = Animation.easeOut(duration: 0.12)
    /// Seconds between the start of two entrance groups.
    static let stagger = 0.04

    // v3 motion tokens by role (docs/DESIGN_V3.md 7). Only `arrive` may overshoot (<= 2%).
    /// Hover, press and number changes.
    static let feedback = Animation.interpolatingSpring(mass: 0.5, stiffness: 380, damping: 30)
    /// Sidebar, row reorder, height change, fade-and-rise of new content.
    static let move = Animation.interpolatingSpring(mass: 0.9, stiffness: 200, damping: 28)
    /// Paw stamp and bubble pop.
    static let arrive = Animation.interpolatingSpring(mass: 0.7, stiffness: 320, damping: 24)
}

/// v3 shape tokens (docs/DESIGN_V3.md 2.2): one control radius and a full radius. The window radius comes from the system.
enum PanelRadius {
    static let control: CGFloat = 8
}

/// Type sizes of the v2 panel (DESIGN_V2.md 3.2). A screen of the main column uses only 17, 13, 11 and 10 pt.
enum PanelType {
    /// v3 lead size (docs/DESIGN_V3.md 2.1): bubble text, problem-row value, sidebar title. On an all-green panel it appears only in the bubble.
    static let lead = Font.system(size: 17, weight: .semibold)
    static let leadMono = Font.system(size: 17, weight: .semibold).monospacedDigit()
    static let bubble = Font.system(size: 13, weight: .medium)
    static let rowName = Font.system(size: 13, weight: .medium)
    static let rowNote = Font.system(size: 11)
    static let rowValue = Font.system(size: 17, weight: .semibold).monospacedDigit()
    /// Value of a normal row: same size, lighter weight (design check 2026-10-12).
    static let rowValueQuiet = Font.system(size: 17, weight: .regular).monospacedDigit()
    static let rowPrefix = Font.system(size: 11)
    static let section = Font.system(size: 11, weight: .semibold)
    static let anomalyTitle = Font.system(size: 13, weight: .medium)
    static let duration = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let sideTitle = Font.system(size: 17, weight: .semibold)
    static let sideStat = Font.system(size: 17, weight: .semibold).monospacedDigit()
    static let sideStatLabel = Font.system(size: 10)
    static let readout = Font.system(size: 11, weight: .semibold).monospacedDigit()
    static let axis = Font.system(size: 10).monospacedDigit()
    static let button = Font.system(size: 13, weight: .semibold)
    static let buttonSub = Font.system(size: 11)
    /// The sizes in pt that the rows, the anomaly area and the footer may use (gate W02).
    static let allowedSizes: Set<Double> = [17, 13, 11, 10]
}

extension PanelMetrics {
    /// The note line of a row spans the name column and the value column (line 2 of the row).
    static let noteColumn = textColumn + valueColumn
}

// MARK: - Slots (the text boxes whose longest string must fit at 1.25 times the font size, check M6)

struct PanelSlot {
    var name: String
    var size: CGFloat
    var weight: NSFont.Weight
    var rounded: Bool
    /// Slot width in points and the number of lines the slot may use.
    var width: CGFloat
    var lines: Int
    /// The longest string that can appear in this slot.
    var sample: String
    /// Text in 11 pt before the sample (value prefix, with a gap of 3 pt). Empty when the slot has none.
    var prefix: String = ""
    /// Smallest scale the view may apply to the sample text (`minimumScaleFactor`). 1 means no scaling.
    var minScale: CGFloat = 1
}

enum PanelSlots {
    static let all: [PanelSlot] = [
        PanelSlot(name: "row.name", size: 13, weight: .medium, rounded: false, width: PanelMetrics.textColumn, lines: 1, sample: "磁盘"),
        PanelSlot(name: "row.note", size: 11, weight: .regular, rounded: false, width: PanelMetrics.noteColumn, lines: 1, sample: "已用 875 / 995 GB，可用 120 GB"),
        PanelSlot(name: "row.note.cpu", size: 11, weight: .regular, rounded: false, width: PanelMetrics.noteColumn, lines: 1, sample: "10 分钟均值 94%"),
        PanelSlot(name: "row.note.battery", size: 11, weight: .regular, rounded: false, width: PanelMetrics.noteColumn, lines: 1, sample: "睡眠时每小时掉电 10.5%"),
        PanelSlot(name: "row.note.network", size: 11, weight: .regular, rounded: false, width: PanelMetrics.noteColumn, lines: 1, sample: "\u{2193}1.1 MB/s \u{2191}96 KB/s", minScale: 0.8),
        PanelSlot(name: "row.value", size: 17, weight: .semibold, rounded: false, width: PanelMetrics.valueColumn, lines: 1, sample: "+314 GB"),
        PanelSlot(name: "row.value.swap", size: 17, weight: .semibold, rounded: false, width: PanelMetrics.valueColumn, lines: 1, sample: "+3.1 GB",
                  prefix: "swap", minScale: 0.75),
        PanelSlot(name: "row.value.available", size: 17, weight: .semibold, rounded: false, width: PanelMetrics.valueColumn, lines: 1, sample: "402 GB",
                  prefix: "可用", minScale: 0.75),
        PanelSlot(name: "row.value.pressure", size: 17, weight: .semibold, rounded: false, width: PanelMetrics.valueColumn, lines: 1, sample: "100%",
                  prefix: "压力", minScale: 0.75),
        PanelSlot(name: "row.value.stale", size: 17, weight: .semibold, rounded: false, width: PanelMetrics.valueColumn, lines: 1, sample: "402 GB",
                  prefix: "11:00", minScale: 0.75),
        PanelSlot(name: "anomaly.title", size: 13, weight: .medium, rounded: false, width: 188, lines: 1, sample: "内存留意"),
        PanelSlot(name: "anomaly.reason", size: 11, weight: .regular, rounded: false, width: 188, lines: 1, sample: "swap 30 分钟增长"),
        PanelSlot(name: "anomaly.duration", size: 13, weight: .medium, rounded: false, width: 120, lines: 1, sample: "1 天 3 小时"),
        PanelSlot(name: "anomaly.start", size: 11, weight: .regular, rounded: false, width: 120, lines: 1, sample: "开始 昨天 22:10"),
        PanelSlot(name: "button.title", size: 13, weight: .semibold, rounded: false, width: PanelMetrics.primaryButtonWidth - 24, lines: 1, sample: "让 Agent 做一次日常巡检"),
        PanelSlot(name: "button.sub", size: 11, weight: .regular, rounded: false, width: PanelMetrics.primaryButtonWidth - 24, lines: 1, sample: "粘贴给你的 Agent"),
    ]
}

// MARK: - Text formatting

/// Missing values give a dash or a status word, never zero.
enum PanelFormat {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
    static func dateTime(_ d: Date) -> String { dateTimeFormatter.string(from: d) }

    /// "18 分", "3 小时 12 分", "1 天 3 小时". Under one minute: "不到 1 分".
    static func duration(seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "不到 1 分" }
        if minutes < 60 { return "\(minutes) 分" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分" }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days) 天" : "\(days) 天 \(restHours) 小时"
    }

    static func duration(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        return duration(seconds: now.timeIntervalSince(since))
    }

    /// "8%", "<1%", "—".
    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v > 0 && v < 1 { return "<1%" }
        return String(format: "%.0f%%", max(0, v))
    }

    /// Number and unit of a byte count for the large figure. "9.8" "GB".
    static func gbParts(_ bytes: Int64?) -> (value: String, unit: String) {
        guard let bytes else { return ("—", "") }
        let pieces = ByteText.gb(bytes).split(separator: " ", maxSplits: 1).map(String.init)
        return pieces.count == 2 ? (pieces[0], pieces[1]) : (pieces.first ?? "—", "")
    }

    /// Decimal swap size like the other sizes: "1.2 GB", "820 MB".
    static func swap(_ bytes: Int64?) -> String { appMemory(bytes) }

    static func appMemory(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let gb = Double(bytes) / 1e9
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    static func bytes(_ m: Measured<Int64>?) -> String {
        guard let m, m.status == .ok, let v = m.value else { return "—" }
        return ByteText.gb(v)
    }

    static func appCPU(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v < 1 { return "<1%" }
        return String(format: "%.0f%%", v)
    }

    static func trafficBytes(_ v: Int64) -> String {
        if v >= 1_000_000_000 { return ByteText.gb(v) }
        if v >= 1_000_000 { return String(format: "%.0f MB", Double(v) / 1e6) }
        return String(format: "%.0f KB", Double(v) / 1e3)
    }

    static func traffic(_ t: TrafficTotals?) -> String {
        guard let t, let rx = t.rx, let tx = t.tx else { return "统计中" }
        let prefix = (t.status == .ok) ? "" : "至少 "
        return "\(prefix)↓ \(trafficBytes(rx)) · ↑ \(trafficBytes(tx))"
    }

    /// Short level word: 正常, 需留意, 异常, 统计中, 已过期.
    static func levelWord(_ level: HealthLevel) -> String {
        switch level {
        case .green: return "正常"
        case .yellow: return "需留意"
        case .red: return "异常"
        case .stale: return "已过期"
        case .unknown, .notApplicable: return "统计中"
        }
    }

    /// "CPU 需留意", "磁盘异常": a space only after a Latin name.
    static func titled(_ item: HealthItem, _ level: HealthLevel) -> String {
        let word = levelWord(level)
        return item == .cpu ? "\(item.label) \(word)" : "\(item.label)\(word)"
    }

    static func thermalWord(_ t: ThermalLevel?) -> String {
        guard let t else { return "统计中" }
        switch t {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "过热"
        case .critical: return "严重过热"
        }
    }

    static func pressureWord(_ p: MemoryPressure?) -> String {
        guard let p else { return "统计中" }
        switch p {
        case .normal: return "正常"
        case .warning: return "压力偏高"
        case .critical: return "压力严重"
        }
    }

    static func trendArrow(_ t: SwapTrend?) -> String {
        guard let t else { return "" }
        switch t {
        case .steepUp: return "↑↑"
        case .up: return "↑"
        case .flat: return "→"
        case .down: return "↓"
        }
    }

    static func rate(_ bytesPerSecond: Double?) -> String { RateText.text(bytesPerSecond) }
}

// MARK: - Shared small views

/// Level lamp. Level is told by color, shape and the text next to it (DESIGN.md P5):
/// green solid, yellow half, red solid with ring, unknown hollow, stale dashed hollow.
struct LampView: View {
    let level: HealthLevel
    var size: CGFloat = 8
    @Environment(\.tok) private var tok

    var body: some View {
        let color = tok.lamp(level)
        ZStack {
            switch level {
            case .green:
                Circle().fill(color)
            case .yellow:
                Circle().strokeBorder(color, lineWidth: 1.25)
                HalfDisc().fill(color).padding(1.5)
            case .red:
                Circle().strokeBorder(color, lineWidth: 1.25)
                Circle().fill(color).padding(size * 0.2)
            case .stale:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.25, dash: [2, 2]))
            default:
                Circle().strokeBorder(color, lineWidth: 1.25)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: CGPoint(x: center.x, y: center.y - radius))
        p.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The category glyph shared with the menu bar badge (DESIGN.md 2.9). The shape comes from I2's `GlyphPaths`.
struct CategoryGlyph: View {
    let item: HealthItem
    var size: CGFloat = 10
    @Environment(\.tok) private var tok

    var body: some View {
        GlyphShape(item: item)
            .fill(tok.textSecondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct GlyphShape: Shape {
    let item: HealthItem

    func path(in rect: CGRect) -> Path {
        let source = Path(GlyphPaths.badge(item, style: .glyph))
        let s = min(rect.width, rect.height) / 10.0
        // The glyph box is 10 x 10 with y up. SwiftUI y is down.
        let flip = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: rect.minX, ty: rect.maxY)
        return source.applying(flip)
    }
}

/// Wraps its children into lines, left to right.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? CGFloat.infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > limit {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - UI regression hooks

#if UITEST
extension View {
    /// Test only: reports the frame (hosting view space, y down) to UITestFrameStore. The id is dropped when the view goes away.
    func uiTestFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { UITestFrameStore.shared.set(id, proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in UITestFrameStore.shared.set(id, frame) }
                .onDisappear { UITestFrameStore.shared.remove(id) }
        })
    }
}
#else
extension View {
    /// Release build: no effect.
    @inline(__always)
    func uiTestFrame(_ id: String) -> some View { self }
}
#endif

// MARK: - v3 row tokens (docs/DESIGN_V3.md 2.3, 5; added by the rows package)

extension PanelTokens {
    /// Background of the row whose sidebar is open: `fillHover` one step deeper (black 10 %, white 14 %). Neutral, no hue.
    var fillRowActive: Color { pick(Color(.sRGB, white: 0, opacity: 0.10), Color(.sRGB, white: 1, opacity: 0.14)) }
    /// Fill of a primary button that is pressed or hovered: the accent fill with a white veil.
    var veilHover: Color { Color.white.opacity(0.10) }
}

/// Sizes of the v3 row glyphs in pt (docs/DESIGN_V3.md 5.2).
enum PanelRowGlyph {
    /// The check mark of a quiet row.
    static let checkSize: CGFloat = 9
    /// The glyph column of a row is 8 pt wide for every shape.
    static let column: CGFloat = 8
}
