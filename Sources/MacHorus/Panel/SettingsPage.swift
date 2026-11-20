// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import SwiftUI

/// Everything about MacHorus itself: which features run, which permissions
/// they use, and the app's details.
struct SettingsPage: View {
    let model: PanelModel
    @Bindable var navigation: PanelNavigation
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.pageSpacing) {
            HStack(spacing: 8) {
                PillPicker(
                    options: [
                        (.features, "settings.section.features"), (.alerts, "settings.section.alerts"),
                        (.privacy, "settings.section.privacy"),
                        (.about, "settings.section.about"),
                    ],
                    selection: $navigation.settingsSection)
                AppearanceMenu(selection: $appearance)
            }
            switch navigation.settingsSection {
            case .features:
                FeaturesPage(
                    model: model.features, readouts: model.readouts, alerts: model.alerts, loginItem: model.loginItem,
                    clipboard: model.tools?.clipboard, openAlerts: { navigation.settingsSection = .alerts })
            case .alerts:
                if let alerts = model.alerts {
                    AlertsPage(alerts: alerts, features: model.features, monitor: model.monitor)
                }
            case .privacy:
                PrivacyPage(model: model.permissions, networkOnClick: model.tools?.network.isEnabled == true)
            case .about: InfoPage()
            }
        }
    }
}

/// Light, dark or like the system, as a round half-black, half-white
/// button; the system's setting is the default.
private struct AppearanceMenu: View {
    @Binding var selection: String

    private var current: AppearanceChoice { AppearanceChoice(rawValue: selection) ?? .system }

    var body: some View {
        Menu {
            ForEach(AppearanceChoice.allCases) { choice in
                Button {
                    selection = choice.rawValue
                    choice.apply()
                } label: {
                    if choice == current {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Label(choice.title, systemImage: choice.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: String(localized: "appearance.help") + ": " + current.title))
        .accessibilityLabel(Text("appearance.help"))
    }
}
