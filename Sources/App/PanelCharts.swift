// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Series data of the sidebar (C2) and small helpers shared by the panel.
// Output: The number transition modifier. The sidebar charts are added in C2.
// Pos: Charts of the v2 panel. They are drawn by hand with Path (no Swift Charts), so a static ImageRenderer render matches the live view
//      and the readout layer can change without a redraw of the main chart (gate W07).

import SwiftUI

// MARK: - Number transition

private struct NumericChange: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? ContentTransition.identity : ContentTransition.numericText())
            .animation(reduceMotion ? nil : PanelMotion.quick, value: value)
    }
}

extension View {
    /// Rolls the digits when the text changes. Direct replacement under Reduce Motion.
    func numericChange(_ value: String) -> some View {
        modifier(NumericChange(value: value))
    }
}
