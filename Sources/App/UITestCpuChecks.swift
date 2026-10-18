// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The allGreen fixture of PanelModel and the process CPU time of the UI test runner (`cpuSeconds`).
// Output: Gate W17 (docs/DESIGN_V3.md 8, U9, U10): with the panel open and a data point every 2 s, the mean process CPU over 60 s
//         is at most 3 % of one core.
// Pos: UI test build only (-D UITEST). W17 was removed with the sprite checks (U10, 2026-10-18). It is restored here without the sprite
//      code: the old method is kept (open the fixture panel, feed one data point every 2 s as the live sampler does, divide the CPU
//      seconds by the wall seconds). The window is 60 s, as DESIGN_V3.md 8 says. Normal runs do not compile this file.
// UITEST-REGISTER: UITestCpuChecks

#if UITEST
import AppKit
import Foundation

@MainActor
enum UITestCpuChecks {
    /// Process CPU limit in percent of one core (DESIGN_V3.md 8: unchanged from v2).
    static let limit = 3.0
    static let windowSeconds = 60.0

    static func register(into registry: UITestRegistry) {
        registry.add("W17", "CPU while open") { runner in await runner.stepW17() }
    }
}

extension UITestRunner {
    func stepW17() async {
        let t0 = now()
        await closePanelQuietly()
        PanelWindow.testReduceMotion = false
        defer { PanelWindow.testReduceMotion = nil }
        let copyBox = UITestTextBox()
        guard let model = await openFixture(.allGreen, copyBox: copyBox) else {
            record("W17", "打开时 CPU", false, since: t0, "the panel did not open")
            return
        }
        let base = model.data
        // Settle: three data points, then 0.8 s without work, so the open animation does not count.
        for k in 1...3 {
            var d = base
            d.current.cpuPercent = 20 + Double(k)
            d.now = base.now.addingTimeInterval(Double(k) * 2)
            model.replace(d)
            await sleepMs(300)
        }
        await sleepMs(800)
        let cpu0 = cpuSeconds(), wall0 = now()
        var samples = 0
        while now() - wall0 < UITestCpuChecks.windowSeconds {
            samples += 1
            var d = base
            d.current.cpuPercent = 20 + Double(samples % 3)
            d.now = base.now.addingTimeInterval(Double(samples + 3) * 2)
            model.replace(d)
            await sleepMs(2000)
        }
        let wall = now() - wall0
        let share = (cpuSeconds() - cpu0) / Swift.max(0.001, wall) * 100
        await closeFixture()
        record("W17", "打开时 CPU", share <= UITestCpuChecks.limit, since: t0,
               "\(Int(wall.rounded())) s steady state with the panel open, a data point every 2 s (\(samples) points): process CPU "
                   + String(format: "%.2f", share) + " % of one core (limit 3 %). VM numbers do not prove the real Mac.",
               ["processCpuPercent": (share * 100).rounded() / 100, "samples": Double(samples)])
    }
}
#endif
