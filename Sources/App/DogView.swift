// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A DogInput and a size (docs/DESIGN.md 4, 8.3, 8.4).
// Output: The Bichon view of the status card.
// Pos: The only view that may use TimelineView (docs/DESIGN.md 10.4). I3 calls `DogView(input:size:)`. Owner I2.
//
// Stage 1: static pose only (phi = pi / 2), drawn once per input change with DogRenderer. No TimelineView, no timer.
// The view exists only while the status card is open. Stage 2 adds the TimelineView behind Reduce Motion.

import SwiftUI

struct DogView: View {
    var input: DogInput
    var size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    init(input: DogInput, size: CGSize) {
        self.input = input
        self.size = size
    }

    var body: some View {
        let input = self.input
        let dark = (colorScheme == .dark)
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                DogRenderer.drawStatic(input, dark: dark, in: DogView.fit(canvasSize), ctx: cg)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel(Text(DogView.label(input)))
    }

    /// The 4:3 design box, fitted and centered in the view.
    static func fit(_ s: CGSize) -> CGRect {
        let k = min(s.width / CGFloat(DogArt.designSize.w), s.height / CGFloat(DogArt.designSize.h))
        let w = CGFloat(DogArt.designSize.w) * k, h = CGFloat(DogArt.designSize.h) * k
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }

    /// VoiceOver text: what the dog does, in Chinese.
    static func label(_ input: DogInput) -> String {
        if input.isStatic { return "比熊：正在统计" }
        var parts = [String]()
        switch DogMotor.staticGait(for: input) {
        case .lie: parts.append("比熊趴着休息")
        case .stand: parts.append("比熊站着")
        case .walk: parts.append("比熊在走")
        case .trot: parts.append("比熊在小跑")
        case .sprint: parts.append("比熊在冲刺")
        }
        if input.thermal == .serious || input.thermal == .critical { parts.append("热得喘气") }
        if let item = input.worstProblem, input.worstLevel == .yellow || input.worstLevel == .red {
            parts.append("在留意" + item.label)
        }
        return parts.joined(separator: "，")
    }
}
