// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The sorted app list of PanelModel, the sort key, and the disclosure state of the layout plan.
// Output: The app list inside CPU, memory and thermal cards, the "占用 App" disclosure row, and the shared disclosure row view.
// Pos: Evidence of the problem card and the "占用 App" row (docs/DESIGN.md 2.3, 2.13, 2.14). The list never shows command arguments or paths.

import AppKit
import SwiftUI

// MARK: - Icons

/// App icons by bundle id, kept for the life of the process. Static renders skip the lookup, so previews stay the same everywhere.
enum AppIconCache {
    private static let lock = NSLock()
    private static var icons = [String: NSImage]()
    private static var missing = Set<String>()

    static func icon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = icons[bundleID] { return hit }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[bundleID] = image
        return image
    }
}

struct AppIconView: View {
    let app: AppUsage
    @Environment(\.tok) private var tok
    @Environment(\.panelSnapshot) private var snapshot

    private var symbol: String {
        if app.isSystem { return "gearshape" }
        return app.bundleID == nil ? "terminal" : "app"
    }

    var body: some View {
        Group {
            if !snapshot, let image = AppIconCache.icon(bundleID: app.bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tok.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - List

private struct AppRow: View {
    let app: AppUsage
    let sort: AppSortKey
    @Environment(\.tok) private var tok

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(app: app)
            Text(app.name)
                .font(PanelFont.body)
                .foregroundStyle(tok.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .uiTestFrame("txt.app.name")
            Text(PanelFormat.appCPU(app.cpuPercent))
                .font(PanelFont.callout)
                .monospacedDigit()
                .foregroundStyle(sort == .cpu ? tok.textPrimary : tok.textSecondary)
                .frame(width: PanelSize.appColumnCPU, alignment: .trailing)
                .lineLimit(1)
            Text(PanelFormat.appMemory(app.memoryBytes))
                .font(PanelFont.callout)
                .monospacedDigit()
                .foregroundStyle(sort == .memory ? tok.textPrimary : tok.textSecondary)
                .frame(width: PanelSize.appColumnMemory, alignment: .trailing)
                .lineLimit(1)
        }
        .frame(height: 17)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app.name))
        .accessibilityValue(Text("CPU \(PanelFormat.appCPU(app.cpuPercent))，内存 \(PanelFormat.appMemory(app.memoryBytes))"))
    }
}

private struct AppHeader: View {
    let title: String
    @Environment(\.tok) private var tok

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU")
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
                .frame(width: PanelSize.appColumnCPU, alignment: .trailing)
            Text("内存")
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
                .frame(width: PanelSize.appColumnMemory, alignment: .trailing)
        }
        .frame(height: 16)
    }
}

private struct AppSkeleton: View {
    let rows: Int
    @Environment(\.tok) private var tok

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<rows, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tok.chartNeutralFill)
                    .frame(height: 12)
            }
            Text("正在读取进程")
                .font(PanelFont.caption)
                .foregroundStyle(tok.textSecondary)
        }
    }
}

/// The list in a CPU, memory or thermal card. The row count follows the evidence height.
struct AppEvidence: View {
    let apps: [AppUsage]
    let sort: AppSortKey
    let height: Double
    let isReading: Bool

    static func rowCount(height: Double) -> Int {
        let n = Int((height - 16) / 17)
        return min(5, max(2, n))
    }

    var body: some View {
        let count = AppEvidence.rowCount(height: height)
        VStack(alignment: .leading, spacing: 0) {
            AppHeader(title: "占用 App（实时）")
            if isReading {
                AppSkeleton(rows: min(3, count))
                    .padding(.top, 2)
            } else {
                ForEach(Array(apps.prefix(count))) { app in
                    AppRow(app: app, sort: sort)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list.apps.evidence")
    }
}

// MARK: - Disclosure row

/// One collapsed row: title, one line of preview text, and an arrow that turns 90 degrees when open.
struct DisclosureRow: View {
    let title: String
    let preview: String
    let expanded: Bool
    let compact: Bool
    let id: String
    let action: () -> Void
    @Environment(\.tok) private var tok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(PanelFont.callout)
                    .foregroundStyle(tok.textPrimary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)
                    .uiTestFrame("txt.disclosure.title." + id)
                Text(preview)
                    .font(PanelFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(tok.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uiTestFrame("txt.disclosure.preview." + id)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tok.textSecondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(reduceMotion ? nil : PanelMotion.quick, value: expanded)
            }
            .padding(.horizontal, 8)
            .frame(width: PanelSize.contentWidth,
                   height: compact ? PanelMetrics.disclosureCompact : PanelMetrics.disclosure)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(level: .green))
        .accessibilityIdentifier("disclosure." + id)
        .accessibilityLabel(Text("展开或收起" + title))
        .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
        .uiTestFrame("disclosure." + id)
    }
}

// MARK: - 占用 App disclosure

struct AppsDisclosure: View {
    let model: PanelModel
    let expanded: Bool
    let compact: Bool

    private var preview: String {
        if model.data.apps.isEmpty { return "正在读取进程" }
        let top = model.topApps(by: .cpu, count: 2)
        return top.map { $0.name + " " + PanelFormat.appCPU($0.cpuPercent) }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            DisclosureRow(title: "占用 App", preview: preview, expanded: expanded, compact: compact, id: "apps") {
                model.setApps(expanded: !expanded)
            }
            if expanded {
                AppsExpanded(model: model)
                    .transition(.opacity)
            }
        }
        .id("apps")
    }
}

struct AppsExpanded: View {
    let model: PanelModel
    @Environment(\.tok) private var tok

    var body: some View {
        let sort = model.appsSort
        VStack(alignment: .leading, spacing: 6) {
            SortPicker(sort: sort) { model.setAppsSort($0) }
            if model.data.apps.isEmpty {
                AppSkeleton(rows: 3)
            } else {
                VStack(spacing: 3) {
                    AppHeader(title: sort == .cpu ? "按 CPU 排序" : "按内存排序")
                    ForEach(model.topApps(by: sort)) { app in
                        AppRow(app: app, sort: sort)
                    }
                }
                if let cov = model.data.coverage, cov.unreadable > 0 {
                    Text("已检查 \(cov.readable) 个进程，另有 \(cov.unreadable) 个系统进程无权读取")
                        .font(PanelFont.caption)
                        .foregroundStyle(tok.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .frame(width: PanelSize.contentWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tok.plotBackground))
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list.apps")
    }
}

private struct SortPicker: View {
    let sort: AppSortKey
    let onPick: (AppSortKey) -> Void
    @Environment(\.tok) private var tok

    private func segment(_ title: String, _ key: AppSortKey, _ id: String) -> some View {
        let selected = sort == key
        return Button(action: { onPick(key) }) {
            Text(title)
                .font(PanelFont.callout)
                .foregroundStyle(selected ? tok.textPrimary : tok.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? tok.fillHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPlainButtonStyle())
        .accessibilityIdentifier(id)
        .accessibilityLabel(Text("按" + title + "排序"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        HStack(spacing: 2) {
            segment("CPU", .cpu, "btn.sort.cpu")
            segment("内存", .memory, "btn.sort.memory")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tok.chartNeutralFill))
    }
}
