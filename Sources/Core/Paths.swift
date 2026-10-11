// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Process environment.
// Output: Data directory and status file locations.
// Pos: Path rules shared by the app and the CLI; no file access here.

import Foundation

enum MoleMonitorPaths {
    /// MOLEMONITOR_DATA_DIR wins; otherwise ~/Library/Application Support/MoleMonitor.
    static func dataDir(environment: [String: String]) -> URL {
        if let p = environment["MOLEMONITOR_DATA_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        var home = NSHomeDirectory()
        if let h = environment["HOME"], !h.isEmpty { home = h }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/MoleMonitor", isDirectory: true)
    }

    static func statusURL(dir: URL) -> URL { dir.appendingPathComponent("status.json") }
}
