// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// "Open at login": an installed copy (in /Applications, where Munki puts
/// it) turns it on once, at its first launch. After that only the user
/// decides, in MacHorus or in System Settings, and MacHorus never turns it
/// back on by itself. A development build elsewhere never turns it on alone.
public enum OpenAtLogin {
    /// Set once the first launch turned it on or the user switched it.
    public static let decidedKey = "openAtLoginDecided"

    public static func turnsOnAtLaunch(alreadyDecided: Bool, bundleURL: URL) -> Bool {
        !alreadyDecided && isInstalled(bundleURL)
    }

    public static func isInstalled(_ bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix("/System/Volumes/Data/Applications/")
    }
}
