// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (copy state, authorization, actions) and the mode of the layout plan.
// Output: Button styles, the copy buttons, the copy call-to-action, the authorization row and the footer bar.
// Pos: All buttons of the status card (docs/DESIGN.md 2.10). Each button uses a custom style on top of `.plain` plus `.focusEffectDisabled()`,
//      so the system focus ring never appears. A 1.5 pt accent ring shows only when the keyboard has the focus.

import SwiftUI

// MARK: - Button styles

/// 24 pt round icon button. Hover shows `fill.hover`. A press scales to 0.94. The ring shows with keyboard focus only.
struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .frame(width: PanelSize.iconButton, height: PanelSize.iconButton)
            .background(Circle().fill(hovering || configuration.isPressed ? tok.fillHover : Color.clear))
            .overlay(Circle().strokeBorder(tok.accent, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : PanelMotion.quick, value: configuration.isPressed)
    }
}

/// The 36 pt call-to-action. Accent fill, white text. A press scales to 0.97 in 0.1 seconds.
struct PanelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelSize.ctaRadius, style: .continuous)
        configuration.label
            .foregroundStyle(tok.onAccent)
            .frame(width: PanelSize.contentWidth, height: PanelMetrics.cta)
            .background(shape.fill(tok.accentFill))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.0 : (hovering ? 0.10 : 0))))
            .overlay(shape.inset(by: -2).strokeBorder(tok.accent, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A full-width row. Problem levels get their tint. Hover adds `fill.hover`.
struct PanelRowButtonStyle: ButtonStyle {
    var level: HealthLevel

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, level: level)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let level: HealthLevel
    @Environment(\.tok) private var tok
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .background(shape.fill(tok.tint(level)))
            .overlay(shape.fill(hovering || configuration.isPressed ? tok.fillHover : Color.clear))
            .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : PanelMotion.quick, value: configuration.isPressed)
    }
}

/// Text or segment button without a background of its own. A press dims it. Keyboard focus shows the ring.
struct PanelPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainButtonBody(configuration: configuration)
    }
}

private struct PlainButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
    }
}

// MARK: - Copy buttons

/// The small copy button of a problem. The icon turns into a check mark for 1.5 seconds after a copy.
struct CopyIconButton: View {
    let model: PanelModel
    let target: CopyTarget
    let item: HealthItem
    @Environment(\.tok) private var tok

    var body: some View {
        let copied = model.copied.contains(target)
        Button(action: { model.copy(target) }) {
            ZStack {
                Image(systemName: "doc.on.doc")
                    .opacity(copied ? 0 : 1)
                Image(systemName: "checkmark")
                    .opacity(copied ? 1 : 0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(copied ? tok.textPrimary : tok.textSecondary)
            .animation(PanelMotion.fadeShort, value: copied)
        }
        .buttonStyle(PanelIconButtonStyle())
        .focusEffectDisabled()
        .help(copied ? "已复制" : "复制\(item.label)问题给 Agent")
        .accessibilityIdentifier("btn.copy." + item.rawValue)
        .accessibilityLabel(Text(copied ? "已复制" : "复制\(item.label)问题给 Agent"))
        .uiTestFrame("btn.copy." + item.rawValue)
    }
}

/// The main button under the problem rows: "复制给 Agent · 磁盘".
struct CopyCTA: View {
    let model: PanelModel
    let item: HealthItem

    var body: some View {
        let copied = model.copied.contains(.primary)
        Button(action: { model.copy(.primary) }) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .semibold))
                    Text("复制给 Agent · " + item.label)
                        .font(PanelFont.headline)
                        .lineLimit(1)
                        .uiTestFrame("txt.cta.label")
                }
                .opacity(copied ? 0 : 1)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text("已复制").font(PanelFont.headline)
                }
                .opacity(copied ? 1 : 0)
            }
            .animation(PanelMotion.fadeShort, value: copied)
        }
        .buttonStyle(PanelPrimaryButtonStyle())
        .focusEffectDisabled()
        .keyboardShortcut("c")
        .accessibilityIdentifier("btn.copy.primary")
        .accessibilityLabel(Text(copied ? "已复制" : "复制给 Agent，\(item.label)"))
        .uiTestFrame("btn.copy.primary")
    }
}

// MARK: - Authorization row

struct AuthorizationRow: View {
    let model: PanelModel
    @Environment(\.tok) private var tok

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 12))
                .foregroundStyle(tok.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(PanelFont.footnote)
                .foregroundStyle(tok.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .uiTestFrame("label.authorization")
                .accessibilityIdentifier("label.authorization")
            if model.authorization == "not_determined" {
                Button(action: { model.onEnableNotifications() }) {
                    Text("开启通知")
                        .font(PanelFont.callout)
                        .foregroundStyle(tok.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(PanelPlainButtonStyle())
                .focusEffectDisabled()
                .accessibilityIdentifier("btn.enableNotifications")
                .accessibilityLabel(Text("开启通知"))
                .uiTestFrame("btn.enableNotifications")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: PanelSize.contentWidth, height: PanelMetrics.authorization)
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch model.authorization {
        case "not_determined": return "MoleMonitor 在磁盘异常增长等情况下发送系统通知"
        case "denied": return "通知已关闭，可在系统设置 > 通知中打开"
        default: return "此环境无法发送通知，提醒只显示在这里"
        }
    }
}

// MARK: - Footer

struct PanelFooter: View {
    let model: PanelModel
    let quiet: Bool
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                cliButton
                settingsButton
                quitButton
            }
        }
        .frame(width: PanelSize.contentWidth, height: PanelMetrics.footer)
        .overlay(alignment: .top) {
            Rectangle().fill(tok.separator).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.footer")
    }

    // MARK: Leading

    @ViewBuilder
    private var leading: some View {
        if quiet {
            statusCopyButton
        } else {
            Text(dataTimeText)
                .font(PanelFont.footnote)
                .monospacedDigit()
                .foregroundStyle(tok.textSecondary)
                .lineLimit(1)
                .padding(.leading, 4)
                .uiTestFrame("txt.footer.time")
                .accessibilityIdentifier("label.dataTime")
        }
    }

    private var dataTimeText: String {
        let data = model.data
        if data.isCollecting { return "统计中" }
        let stamp = data.current.sampledAt ?? data.status?.writtenAt
        guard let stamp else { return "数据 —" }
        let base = "数据 " + PanelFormat.clock(stamp)
        return data.staleSince != nil ? base + "（已过期）" : base
    }

    private var statusCopyButton: some View {
        let copied = model.copied.contains(.primary)
        return Button(action: { model.copy(.primary) }) {
            ZStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium))
                    Text("复制状态给 Agent").font(PanelFont.callout)
                }
                .opacity(copied ? 0 : 1)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("已复制").font(PanelFont.callout)
                }
                .opacity(copied ? 1 : 0)
            }
            .foregroundStyle(tok.textPrimary)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
            .animation(PanelMotion.fadeShort, value: copied)
        }
        .buttonStyle(PanelPlainButtonStyle())
        .focusEffectDisabled()
        .keyboardShortcut("c")
        .accessibilityIdentifier("btn.copy.status")
        .accessibilityLabel(Text(copied ? "已复制" : "复制状态给 Agent"))
        .uiTestFrame("btn.copy.status")
    }

    // MARK: Icon buttons

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(tok.textSecondary)
    }

    @ViewBuilder
    private var cliButton: some View {
        if snapshot {
            HoverIcon(symbol: "terminal").uiTestFrame("btn.cli")
        } else {
            Menu {
                Button("复制命令：一行状态") { model.copyCommand(PanelFooter.command("--status --brief")) }
                Button("复制命令：完整状态 JSON") { model.copyCommand(PanelFooter.command("--status")) }
                Button("复制命令：排查提示词") { model.copyCommand(PanelFooter.command("prompt")) }
            } label: {
                HoverIcon(symbol: "terminal")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
            .help("命令行")
            .accessibilityIdentifier("btn.cli")
            .accessibilityLabel(Text("命令行"))
            .uiTestFrame("btn.cli")
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if snapshot {
            HoverIcon(symbol: "gearshape").uiTestFrame("btn.settings")
        } else {
            Menu {
                Toggle("提示词包含 App 名称", isOn: Binding(get: { model.includeAppNames },
                                                         set: { model.setIncludeAppNames($0) }))
                Button("打开通知设置…") { model.onOpenNotificationSettings() }
                Button("打开数据文件夹") { model.onOpenDataFolder() }
                Divider()
                Button("关于 MoleMonitor") { model.onAbout() }
            } label: {
                HoverIcon(symbol: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
            .help("设置")
            .accessibilityIdentifier("btn.settings")
            .accessibilityLabel(Text("设置"))
            .uiTestFrame("btn.settings")
        }
    }

    private var quitButton: some View {
        Button(action: { model.onQuit() }) {
            icon("power")
        }
        .buttonStyle(PanelIconButtonStyle())
        .focusEffectDisabled()
        .keyboardShortcut("q")
        .help("退出 MoleMonitor")
        .accessibilityIdentifier("btn.quit")
        .accessibilityLabel(Text("退出 MoleMonitor"))
        .uiTestFrame("btn.quit")
    }

    /// A shell command with the path of the helper. The home folder is written as `~` when the path has no space.
    static func command(_ arguments: String) -> String {
        let absolute = Bundle.main.bundlePath + "/Contents/Helpers/molemonitor-cli"
        let shown = PanelPaths.display(absolute)
        let path = absolute.contains(" ") ? "'" + absolute + "'" : shown
        return path + " " + arguments
    }
}

/// The label of a menu icon: the same 24 pt circle and hover as the plain icon buttons.
private struct HoverIcon: View {
    let symbol: String
    @Environment(\.tok) private var tok
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(tok.textSecondary)
            .frame(width: PanelSize.iconButton, height: PanelSize.iconButton)
            .background(Circle().fill(hovering ? tok.fillHover : Color.clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
    }
}
