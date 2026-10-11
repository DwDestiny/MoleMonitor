// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A DogInput and a size (docs/DESIGN.md 4, 8.3, 8.4).
// Output: The animated Bichon view of the status card.
// Pos: The only view that may use TimelineView (docs/DESIGN.md 10.4). I3 calls `DogView(input:size:)`. Owner I2.
// SKELETON: draws a rounded rectangle with the text "SKELETON". No animation, no timer.

import SwiftUI

struct DogView: View {
    var input: DogInput
    var size: CGSize

    init(input: DogInput, size: CGSize) {
        self.input = input
        self.size = size
    }

    var body: some View {
        // SKELETON
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary, lineWidth: 1)
            Text("SKELETON")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(width: size.width, height: size.height)
    }
}
