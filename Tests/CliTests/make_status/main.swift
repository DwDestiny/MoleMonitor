// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Arguments: <output path> <writer pid> <written-at ISO 8601>.
// Output: A real StatusFile encoded by Core's StatusStore.write, for the CLI interoperability check.
// Pos: Test helper for scripts/test_cli.py; compiled together with Sources/Core.

import Foundation

let a = CommandLine.arguments
guard a.count == 4, let pid = Int32(a[2]), let writtenAt = UTCTime.parseISO(a[3]) else {
    FileHandle.standardError.write(Data("usage: make_status <path> <pid> <iso>\n".utf8))
    exit(2)
}
let now = writtenAt
func sample(_ hoursAgo: Double, _ usedGB: Int64, rx: Int64, tx: Int64) -> DiskSample {
    let total: Int64 = 1_000_000_000_000
    return DiskSample(t: now.addingTimeInterval(-hoursAgo * 3600), total: total,
                      availImportant: total - usedGB * 1_000_000_000, avail: total - usedGB * 1_000_000_000,
                      netRx: rx, netTx: tx, boot: now.addingTimeInterval(-10 * 86400))
}
let samples = [sample(115, 200, rx: 100, tx: 10), sample(72, 150, rx: 200, tx: 20), sample(0.1, 450, rx: 300, tx: 30)]
let verdict = DiskHealth.evaluate(samples: samples, now: now, previous: .green)
let disk = DiskItem.make(samples: samples, now: now, verdict: verdict, since: now.addingTimeInterval(-3600),
                         levelChangedAt: now.addingTimeInterval(-3600))
let alerts = DiskAlertPolicy.growthAlert(verdict: verdict, since: now, state: DiskAlertState()).map { [$0] } ?? []
let file = StatusFile(appVersion: AppInfo.version, writtenAt: now, writerPid: pid,
                      overall: .init(level: verdict.level, summary: verdict.reason),
                      items: .init(disk: disk, network: NetworkItem.make(samples: samples, now: now, todayStart: now.addingTimeInterval(-43200))),
                      activeAlerts: alerts, notifications: .init(authorization: "authorized"))
do {
    try StatusStore.write(file, to: URL(fileURLWithPath: a[1]))
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
