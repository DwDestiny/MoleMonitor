// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Health verdicts, current readings, top apps and environment data (docs/DESIGN.md 7, 8.1).
// Output: The Chinese prompt text for "复制给 Agent", and the redaction of private text.
// Pos: Pure text building shared by the app and `molemonitor-cli prompt`; Foundation only. Owner I1.
// SKELETON: PromptBuilder.build returns a fixed marker text. Redactor returns the text unchanged.

import Foundation

enum PromptTopic: String, CaseIterable { case disk, memory, cpu, thermal, power, network }
enum PromptScope: Equatable { case overview, topic(PromptTopic) }

struct PromptEnvironment: Codable, Equatable {
    var model: String?, chip: String?, memoryBytes: Int64?, os: String
    var appVersion: String, cliPath: String, dataDir: String
}

/// Data freshness for the prompt line. Not listed in DESIGN.md 8.1 at skeleton time: the `freshness` field needs it.
enum PromptFreshness: Equatable {
    case fresh
    case stale(minutes: Int)
    case notRunning(minutes: Int)
}

struct PromptInput: Equatable {
    var env: PromptEnvironment
    var sampledAt: Date
    var freshness: PromptFreshness            // fresh, stale(minutes), notRunning(minutes)
    var verdicts: [ItemVerdict]
    var current: CurrentReadings
    var apps: [AppUsage]
    var appsBasis: String
    var cpuSummary: CPUSummary?
    var diskGrowth: [String: DiskGrowth]
}

/// `DiskGrowth` (DiskGrowth.swift) is only Codable. `PromptInput: Equatable` needs it, so the conformance lives here.
/// Compares every field. Keep this list in step with `DiskGrowth`; I1 may move `Equatable` to the declaration later.
extension DiskGrowth: Equatable {
    static func == (a: DiskGrowth, b: DiskGrowth) -> Bool {
        a.window == b.window && a.bytes == b.bytes && a.netBytes == b.netBytes
            && a.fromMinAt == b.fromMinAt && a.coveredHours == b.coveredHours && a.status == b.status
    }
}

struct PromptOptions: Equatable {
    var includeAppNames = true
    var maxLength = 3000          // Only a longer text triggers the L1 to L5 compression
    var homeDirectory: String
    var userNames: [String]
}

enum PromptBuilder {
    static let skeletonText = "SKELETON"

    static func build(_ input: PromptInput, scope: PromptScope, options: PromptOptions) -> String {
        skeletonText // SKELETON
    }

    /// The topic chosen automatically. Nil when there is no problem item.
    static func autoTopic(_ verdicts: [ItemVerdict]) -> PromptTopic? {
        nil // SKELETON
    }
}

enum Redactor {
    static func redact(_ text: String, home: String, userNames: [String]) -> String {
        text // SKELETON
    }
}
