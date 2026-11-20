// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import SwiftUI

/// The permissions as System Settings lists them: each one the active
/// features use, what for, and its state; below, plainly, what MacHorus
/// does with data. No badges and no slogans.
struct PrivacyPage: View {
    let model: PermissionsModel
    var networkOnClick = false

    var body: some View {
        let rows = model.rows.filter { model.declared.contains($0.permission) }
        LazyVStack(alignment: .leading, spacing: Theme.pageSpacing) {
            SectionTitle(title: "privacy.section.permissions")
            PanelCard(spacing: 12) {
                if rows.isEmpty {
                    Text("privacy.none").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in PermissionRowView(row: row) }
            }
            Text(networkOnClick ? "privacy.statement.onClick" : "privacy.statement.offline")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct PermissionRowView: View {
    let row: PermissionRow

    var body: some View {
        InfoRow(
            symbol: PanelTexts.symbol(row.permission),
            tint: Theme.lapis,
            title: PanelTexts.name(row.permission),
            subtitle: subtitle
        ) {
            if row.isMissing {
                Button("privacy.open") { PermissionStatusProvider.openSystemSettings(for: row.permission) }
                    .buttonStyle(PillButtonStyle())
            } else {
                chip
            }
        }
    }

    private var subtitle: String {
        if row.usedBy.isEmpty {
            return row.isUnneeded
                ? String(localized: "privacy.unneeded") : String(localized: "privacy.notInUse")
        }
        let names = row.usedBy.map(PanelTexts.featureTitle)
        return String(format: String(localized: "privacy.usedBy %@"), names.formatted(.list(type: .and)))
    }

    /// The state as plain text, like System Settings.
    private var chip: some View {
        Text(state).font(.callout).foregroundStyle(.secondary)
    }

    private var state: LocalizedStringKey {
        switch row.state {
        case .granted: "permission.state.granted"
        case .notApplicable: "permission.state.perApp"
        case .denied, .notDetermined, .notChecked: "privacy.notInUse.chip"
        }
    }
}
