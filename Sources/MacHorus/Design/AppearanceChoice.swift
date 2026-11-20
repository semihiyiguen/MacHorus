// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit

/// Light or dark for MacHorus itself. The default follows the system and
/// switches with it; a choice is remembered.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "appearance"

    var id: Self { self }

    static var stored: AppearanceChoice {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "appearance.system")
        case .light: String(localized: "appearance.light")
        case .dark: String(localized: "appearance.dark")
        }
    }

    /// nil: the system's appearance, also when it changes later.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
