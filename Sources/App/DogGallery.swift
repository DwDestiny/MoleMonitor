// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: An output directory from `--dog-gallery <directory>` (docs/DESIGN.md 4.8, 8.5).
// Output: The PNG gallery of all static dog poses and manifest.json. A release feature, not test code.
// Pos: Review and CI tool; the app never calls it at run time. Owner I2.
// SKELETON: creates the directory and writes no image.

import Foundation

@MainActor
enum DogGallery {
    /// Renders the gallery into `dir`. Returns an error text, or nil on success.
    static func render(to dir: URL) -> String? {
        // SKELETON: creates the directory, writes no image.
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return "Cannot create the gallery directory."
        }
        return nil
    }

    /// Entry for `--dog-gallery <directory>`. Never returns: exit 0 on success, 1 on failure, 2 for a missing path.
    static func run(_ args: [String]) -> Never {
        guard let path = MoleMonitorMain.argumentValue("--dog-gallery", in: args) else {
            FileHandle.standardError.write(Data("--dog-gallery needs an output directory.\n".utf8))
            exit(2)
        }
        if let error = render(to: URL(fileURLWithPath: path, isDirectory: true)) {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            exit(1)
        }
        print(path)
        exit(0)
    }
}
