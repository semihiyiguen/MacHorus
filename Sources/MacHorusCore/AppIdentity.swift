// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Stable identifiers of the app. Changing any of them drops granted
/// permissions and settings on every installed Mac.
public enum AppIdentity {
    public static let name = "MacHorus"
    public static let bundleIdentifier = "app.machorus.MacHorus"

    /// Version of the running app, read from the bundle's Info.plist.
    /// Falls back to 0.0.0 when running outside an app bundle (e.g. tests).
    public static func currentVersion(bundle: Bundle = .main) -> SemanticVersion {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(SemanticVersion.init) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }
}
