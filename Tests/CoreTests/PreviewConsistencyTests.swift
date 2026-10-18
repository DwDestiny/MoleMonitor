// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The preview fixtures (PreviewScenario) of the five scenarios with data, and the sidebar, panel row and record builders.
// Output: Assertions that every number of a scenario comes from its one series: disk growth windows, axis labels, used space,
//         problem durations, peaks (docs/DESIGN_V3.md 9, Fable round 2 item E).
// Pos: Called from main.swift via runPreviewConsistencyTests(); no top-level code in this file. Owner R2.

import Foundation

func runPreviewConsistencyTests() {
    section("Preview data: one series per scenario")
    let tz = TimeZone(identifier: "UTC") ?? TimeZone.current
    let cases: [PreviewCase] = [.allGreen, .diskRed, .multi, .cpuYellow, .powerYellow]

    for c in cases {
        let f = PreviewScenario.fixture(c, full: true, now: now)
        let name = c.rawValue
        func sidebar(_ item: SidebarItem, _ range: SidebarRange) -> SidebarInput {
            SidebarInput(item: item, range: range, trend: f.trend, rollups: PreviewScenario.fixtureRollups(c, hours: 24, now: now),
                         diskSeries: f.diskSeries, diskTrigger: f.diskTrigger, sleeps: f.sleeps, current: f.current,
                         verdicts: f.verdicts, status: f.status, now: now, timeZone: tz)
        }

        // Disk: windows are end point differences of the series, and they grow with the window.
        let series = f.diskSeries
        func growth(_ days: Double) -> Double? {
            let start = now.addingTimeInterval(-days * 86400)
            let pts = series.filter { $0.t >= start && $0.t <= now }
            guard let a = pts.first, let b = pts.last else { return nil }
            return b.gb - a.gb
        }
        guard let last = series.last, let g1 = growth(1), let g5 = growth(5), let g7 = growth(7), let g30 = growth(30) else {
            expect(false, "\(name): disk series has points"); continue
        }
        expect(g1 <= g5 + 0.01 && g5 <= g7 + 0.01 && g7 <= g30 + 0.01, "\(name): disk growth 1d \(g1) <= 5d \(g5) <= 7d \(g7) <= 30d \(g30)")
        expect(SidebarStats.diskGrowthText(sidebar(.disk, .d7), days: 7) == TextFormat.signedDiskGB(Int64((g7 * 1e9).rounded())),
               "\(name): sidebar 7 day text is the series end point difference")
        expect(SidebarStats.diskGrowthText(sidebar(.disk, .d30), days: 30) == TextFormat.signedDiskGB(Int64((g30 * 1e9).rounded())),
               "\(name): sidebar 30 day text is the series end point difference")
        if let engine5 = f.status.items.disk.growth["5d"]?.bytes {
            expect(abs(Double(engine5) / 1e9 - g5) <= 1.0, "\(name): main column 5 day growth \(Double(engine5) / 1e9) is the series difference \(g5)")
            expect(Double(engine5) / 1e9 <= g7 + 1.0, "\(name): main column 5 days is not above the sidebar 7 days")
        }

        // Used space is the series end, and the axis names the series extremes.
        expect(Int((Double(f.current.diskUsed ?? 0) / 1e9).rounded()) == Int(last.gb.rounded()),
               "\(name): used \(Double(f.current.diskUsed ?? 0) / 1e9) is the series end \(last.gb)")
        for range in [SidebarRange.d7, .d30] {
            let chart = SidebarChart.make(sidebar(.disk, range))
            let g = range == .d7 ? g7 : g30
            let marks = chart.axisMarks
            expect(marks.count == 2, "\(name) \(range.rawValue): two axis labels")
            if marks.count == 2 {
                expect(marks[1].text == String(format: "%.0f GB", last.gb), "\(name) \(range.rawValue): top label \(marks[1].text) is the series end")
                let lo = Double(marks[0].text.replacingOccurrences(of: " GB", with: "")) ?? -1000
                let hi = Double(marks[1].text.replacingOccurrences(of: " GB", with: "")) ?? 1000
                expect(abs((hi - lo) - g) <= 1.0, "\(name) \(range.rawValue): label difference \(hi - lo) is the growth \(g)")
                expect(marks[0].y >= 0 && marks[1].y <= 1 && marks[0].y < marks[1].y, "\(name) \(range.rawValue): labels sit inside the plot")
            }
        }

        // Problems: the main column duration is the record duration, and the peak is the series maximum.
        let trendPoints = f.trend.segments.flatMap { $0 }
        for e in f.events where e.end == nil {
            guard let v = f.verdicts.first(where: { $0.item == e.item }) else { expect(false, "\(name): verdict for \(e.item)"); continue }
            expect(v.since == e.start, "\(name) \(e.item.rawValue): the verdict starts when the record starts")
            let row = SidebarRecords.row(e, now: now, tz: tz)
            expect(row.duration == TextFormat.duration(since: v.since, now: now), "\(name) \(e.item.rawValue): record duration \(row.duration) is the main column duration")
            expect(PanelAnomalies.episode(v, now: now, timeZone: tz)?.hasPrefix("已持续 " + row.duration) == true, "\(name) \(e.item.rawValue): the sidebar header says the same duration")
            let inEpisode = trendPoints.filter { $0.t >= e.start }
            switch e.item {
            case .cpu:
                let top = inEpisode.compactMap { $0.cpu }.max() ?? -1
                expect(Int(top.rounded()) == Int((e.peakValue ?? -2).rounded()), "\(name): cpu record peak \(String(describing: e.peakValue)) is the series maximum \(top)")
                let stat = SidebarStats.make(sidebar(.cpu, .h2)).first { $0.label == "峰值" }?.value
                expect(stat == TextFormat.percent(top), "\(name): sidebar cpu peak \(String(describing: stat)) equals the record peak")
            case .memory:
                let top = inEpisode.compactMap { $0.pressurePercent }.max() ?? -1
                expect(top == Int((e.peakValue ?? -2).rounded()), "\(name): memory record peak is the pressure maximum \(top)")
            case .disk:
                expect(Int((e.peakValue ?? -2).rounded()) == Int(((Double(f.status.items.disk.growth["5d"]?.bytes ?? 0)) / 1e9).rounded()),
                       "\(name): disk record value is the 5 day growth of the main column")
            default: break
            }
        }

        // The disk problem row: duration and free space, no repeated growth number.
        if let dv = f.verdicts.first(where: { $0.item == .disk && $0.isProblem }) {
            let input = PanelRowsInput(verdicts: f.verdicts, current: f.current, dataState: .fresh, diskGrowth: f.status.items.disk.growth,
                                       topApps: f.apps, now: now, timeZone: tz)
            let row = PanelRows.row(.disk, input)
            let free = CapacityFormat.disk(f.current).available
            expect(row.problemNote == "已持续 " + TextFormat.duration(since: dv.since, now: now) + "，可用 " + free,
                   "\(name): disk note is duration and free space, got \(String(describing: row.problemNote))")
            expect(row.problemNote?.contains("胖了") == false && row.problemNote?.contains("GB") == true && row.value.hasPrefix("+"),
                   "\(name): the disk note does not repeat the growth")
        }
    }
}
