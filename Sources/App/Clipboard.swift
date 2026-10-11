// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: A plain text (the prompt for the agent).
// Output: The text on the general pasteboard as one plain-text item; a light haptic tick on a trackpad.
// Pos: Mac-only wrapper (docs/DESIGN.md 7.7, 8.2). Call on the main thread. It does not read the pasteboard.

import AppKit

enum Clipboard {
    /// Returns true when the pasteboard took the text.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        let ok = board.setString(text, forType: .string)
        if ok {
            // UNVERIFIED-ON-MAC: perform(_:performanceTime:) spelling. A Mac without a trackpad ignores the call.
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        return ok
    }
}
