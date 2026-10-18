// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: PanelModel (footer state, copy state, authorization, action callbacks).
// Output: The footer, one 32 pt line: with problems a solid accent button "复制排查提示词", without problems the text button
//         "复制日常巡检提示词", hidden while collecting. Then the icon button "…" (32 x 32) with its NSMenu.
// Pos: Section 4 of the main column (docs/DESIGN_V3.md 5.4; DESIGN_V2.md 8). The copy button is the only primary action: id `btn.copy`.
//      After a copy the paw stamp lands on the button (5.6, CopyStamp): the paw and "已复制" spring from 1.25x to 1.0x
//      (`PanelMotion.arrive`), stay for 1.5 s (PanelModel.copiedSeconds) and fade out in 160 ms while the title fades back.
//      Reduce Motion: fades only. It is the only signature moment of the panel. The "…" menu lists the CLI commands, the prompt option and the app items.
//      Menu items carry identifiers `menu.*`. The menu is an NSMenu, so the system draws it and VoiceOver reads it.

import AppKit
import SwiftUI

// MARK: - Button styles

/// The solid primary button (DESIGN_V3.md 5.4): 32 pt high, 8 pt radius, accent fill, white text. It takes the width it is given.
/// A press scales to 0.97 (not under Reduce Motion). This is the only place that uses the accent as a fill.
struct PanelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        configuration.label
            .foregroundStyle(tok.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.footer)
            .background(shape.fill(tok.accentFill))
            .overlay(shape.fill(configuration.isPressed ? Color.clear : (hovering ? tok.veilHover : Color.clear)))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The text button of the all-green panel (DESIGN_V3.md 5.4): primary text, no fill, `fillHover` on hover. It is as wide as its text.
struct PanelTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.tok) private var tok
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        configuration.label
            .foregroundStyle(tok.textPrimary)
            .padding(.horizontal, PanelMetrics.rowInset)
            .frame(height: PanelMetrics.footer)
            .background(shape.fill(hovering || configuration.isPressed ? tok.fillHover : Color.clear))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
    }
}

/// The 32 x 32 "..." button: an icon with no fill, `fillHover` on hover.
struct PanelMoreButtonStyle: ButtonStyle {
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        MoreButtonBody(configuration: configuration, focused: focused)
    }
}

private struct MoreButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let focused: Bool
    @Environment(\.tok) private var tok
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
        configuration.label
            .foregroundStyle(tok.textSecondary)
            .frame(width: PanelMetrics.moreButtonWidth, height: PanelMetrics.footer)
            .background(shape.fill(hovering || configuration.isPressed ? tok.fillHover : Color.clear))
            .overlay(shape.strokeBorder(tok.accent, lineWidth: 1.5).opacity(focused ? 1 : 0))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PanelMotion.hover, value: hovering)
    }
}

// MARK: - Menu

/// Target of the menu items. The anchor box keeps it alive while the menu is open.
@MainActor
final class PanelMenuHandler: NSObject {
    weak var model: PanelModel?

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    @objc func copyCommand(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { model?.copyCommand(text) }
    }

    @objc func toggleAppNames(_ sender: NSMenuItem) {
        guard let model else { return }
        model.setIncludeAppNames(!model.includeAppNames)
    }

    @objc func enableNotifications(_ sender: NSMenuItem) { model?.onEnableNotifications() }
    @objc func openDataFolder(_ sender: NSMenuItem) { model?.onOpenDataFolder() }
    @objc func about(_ sender: NSMenuItem) { model?.onAbout() }
    @objc func quit(_ sender: NSMenuItem) { model?.onQuit() }
}

enum PanelMoreMenu {
    /// A shell command with the path of the helper. The home folder is written as `~` when the path has no space.
    static func command(_ arguments: String) -> String {
        let absolute = Bundle.main.bundlePath + "/Contents/Helpers/molemonitor-cli"
        let shown = PanelPaths.display(absolute)
        let path = absolute.contains(" ") ? "'" + absolute + "'" : shown
        return path + " " + arguments
    }

    /// The CLI entries: title and arguments (DESIGN_V2.md 8.2).
    static let commands: [(title: String, arguments: String, id: String)] = [
        ("状态 --status", "--status", "menu.cli.status"),
        ("磁盘历史 --disk-history --days 30", "--disk-history --days 30", "menu.cli.disk"),
        ("异常记录 --events --days 7", "--events --days 7", "menu.cli.events"),
    ]

    @MainActor
    static func makeMenu(model: PanelModel, handler: PanelMenuHandler) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        let cli = NSMenuItem(title: "复制 CLI 命令", action: nil, keyEquivalent: "")
        cli.identifier = NSUserInterfaceItemIdentifier("menu.cli")
        let sub = NSMenu(title: "")
        for entry in commands {
            let item = NSMenuItem(title: entry.title, action: #selector(PanelMenuHandler.copyCommand(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = command(entry.arguments)
            item.identifier = NSUserInterfaceItemIdentifier(entry.id)
            sub.addItem(item)
        }
        cli.submenu = sub
        menu.addItem(cli)

        let names = NSMenuItem(title: "提示词包含 App 名称", action: #selector(PanelMenuHandler.toggleAppNames(_:)), keyEquivalent: "")
        names.target = handler
        names.state = model.includeAppNames ? .on : .off
        names.identifier = NSUserInterfaceItemIdentifier("menu.appNames")
        menu.addItem(names)
        menu.addItem(NSMenuItem.separator())

        if model.authorization != "authorized" {
            let notify = NSMenuItem(title: "开启通知…", action: #selector(PanelMenuHandler.enableNotifications(_:)), keyEquivalent: "")
            notify.target = handler
            notify.identifier = NSUserInterfaceItemIdentifier("menu.notify")
            menu.addItem(notify)
        }
        let folder = NSMenuItem(title: "打开数据文件夹", action: #selector(PanelMenuHandler.openDataFolder(_:)), keyEquivalent: "")
        folder.target = handler
        folder.identifier = NSUserInterfaceItemIdentifier("menu.dataFolder")
        menu.addItem(folder)
        let about = NSMenuItem(title: "关于 MoleMonitor", action: #selector(PanelMenuHandler.about(_:)), keyEquivalent: "")
        about.target = handler
        about.identifier = NSUserInterfaceItemIdentifier("menu.about")
        menu.addItem(about)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出 MoleMonitor", action: #selector(PanelMenuHandler.quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = handler
        quit.identifier = NSUserInterfaceItemIdentifier("menu.quit")
        menu.addItem(quit)
        return menu
    }
}

/// The view that anchors the menu. Flipped, so y grows downward like SwiftUI.
final class PanelMenuAnchorView: NSView {
    override var isFlipped: Bool { true }
}

final class PanelMenuAnchor {
    weak var view: NSView?
    var handler: PanelMenuHandler?

    @MainActor
    func pop(model: PanelModel) {
        guard let view else { return }
        let handler = PanelMenuHandler(model: model)
        self.handler = handler
        let menu = PanelMoreMenu.makeMenu(model: model, handler: handler)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

private struct PanelMenuAnchorRepresentable: NSViewRepresentable {
    let anchor: PanelMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PanelMenuAnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Footer

struct PanelFooter: View {
    @ObservedObject var model: PanelModel
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot
    @State private var anchor = PanelMenuAnchor()

    var body: some View {
        let state = model.footerState
        let copied = !model.copied.isEmpty
        HStack(spacing: PanelMetrics.footerGap) {
            if state.hidden {
                Spacer(minLength: 0)
            } else if state.mode == .copyProblems {
                primary(state, copied: copied)
            } else {
                primary(state, copied: copied)
                Spacer(minLength: 0)
            }
            moreButton
        }
        .frame(width: PanelMetrics.rowBackgroundWidth, height: PanelMetrics.footer)
        .overlay(hiddenQuit)
        .hoverRegion(.neutral, model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.footer")
        .onAppear {
            let target = model
            let menuAnchor = anchor
            model.onShowMoreMenu = { [weak target] in
                if let target { menuAnchor.pop(model: target) }
            }
        }
    }

    /// The label of the primary button. The texts stack in one place, so the button keeps its size when the text changes.
    private func label(_ state: PanelFooterState, copied: Bool, failed: Bool) -> some View {
        ZStack(alignment: state.mode == .copyProblems ? .center : .leading) {
            Text(state.title)
                .font(PanelType.button)
                .lineLimit(1)
                .opacity(copied || failed ? 0 : 1)
                .uiTestFrame("txt.btn.title")
            CopyStamp(text: state.copiedTitle, shown: copied)
                .uiTestFrame("txt.btn.copied")
            Text("没复制上，再点一次试试")
                .font(PanelType.button)
                .lineLimit(1)
                .opacity(failed ? 1 : 0)
        }
        .animation(copied ? CopyStamp.fadeIn : CopyStamp.fadeOut, value: copied)
    }

    @ViewBuilder
    private func primary(_ state: PanelFooterState, copied: Bool) -> some View {
        let failed = model.copyFailed
        let button = Button(action: { model.copy(.primary) }) {
            label(state, copied: copied, failed: failed)
        }
        .focusEffectDisabled()
        .disabled(!state.enabled)
        .overlay(RoundedRectangle(cornerRadius: PanelRadius.control, style: .continuous)
            .strokeBorder(tok.accent, lineWidth: 1.5).padding(-2)
            .opacity(model.keyFocus == .primary ? 1 : 0))
        .keyboardShortcut("c")
        .accessibilityIdentifier("btn.copy")
        .accessibilityLabel(Text(copied ? "已复制" : state.title))
        .uiTestFrame("btn.copy")
        if state.mode == .copyProblems {
            button.buttonStyle(PanelPrimaryButtonStyle())
        } else {
            button.buttonStyle(PanelTextButtonStyle())
        }
    }

    @ViewBuilder
    private var moreButton: some View {
        let button = Button(action: { model.onShowMoreMenu?() }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(PanelMoreButtonStyle(focused: model.keyFocus == .more))
        .focusEffectDisabled()
        .accessibilityIdentifier("btn.more")
        .accessibilityLabel(Text("更多"))
        .uiTestFrame("btn.more")
        if snapshot {
            button
        } else {
            button.background(PanelMenuAnchorRepresentable(anchor: anchor))
        }
    }

    /// ⌘Q quits the app while the panel has the key. The button has no size and no look.
    private var hiddenQuit: some View {
        Button("") { model.onQuit() }
            .keyboardShortcut("q")
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

// MARK: - Paw stamp

/// The paw stamp of a successful copy (docs/DESIGN_V3.md 5.6), the one signature moment of the panel.
/// On arrival the paw and "已复制" start at 1.25x and spring to 1.0x with `PanelMotion.arrive` (overshoot about 1.5%, under 2%),
/// while the opacity rises in 120 ms. The parent fades it out in 160 ms when the copied state ends. Reduce Motion: no scale, fades only.
/// A static render (`--preview`) shows the landed frame (scale 1). The keyframe runs only on an arrival, so nothing animates at rest.
private struct CopyStamp: View {
    let text: String
    let shown: Bool

    /// `motion.fade` of DESIGN_V3.md 7.
    static let fadeOut = Animation.easeInOut(duration: 0.16)
    static let fadeIn = Animation.easeOut(duration: 0.12)
    static let pawSize: CGFloat = 14
    static let pawTilt = -12.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0

    var body: some View {
        HStack(spacing: 4) {
            PawShape()
                .frame(width: CopyStamp.pawSize, height: CopyStamp.pawSize)
                .rotationEffect(.degrees(CopyStamp.pawTilt))
                .accessibilityHidden(true)
            Text(text)
                .font(PanelType.button)
                .lineLimit(1)
        }
        .keyframeAnimator(initialValue: CGFloat(1), trigger: arrivals) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(CGFloat(1.25))
                SpringKeyframe(CGFloat(1), spring: Spring(mass: 0.7, stiffness: 320, damping: 24))
            }
        }
        .opacity(shown ? 1 : 0)
        .onChange(of: shown) { _, now in
            if now && !reduceMotion { arrivals += 1 }
        }
    }
}

/// The paw of `GlyphPaths.pawYDown`, filled with the foreground style (white on the solid button, `text.primary` on the text button).
private struct PawShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let t = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
        return Path(GlyphPaths.pawYDown(box: side)).applying(t)
    }
}
