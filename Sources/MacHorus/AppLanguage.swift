// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit

/// The app's language, English by default or German, chosen in the
/// settings. macOS reads a bundle's language once at launch,
/// so a change takes effect after a restart of MacHorus (offered at once).
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    static let key = "appLanguage"

    var id: Self { self }

    /// Shown in its own language, so anyone finds theirs.
    var title: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// Called first thing at launch, before any text is looked up.
    static func applyAtLaunch() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// Quits and opens MacHorus again (a helper shell waits for the exit).
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
