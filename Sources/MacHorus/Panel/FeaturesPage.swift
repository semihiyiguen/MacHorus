// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusCore
import MacHorusMonitor
import SwiftUI

/// The feature categories that have features on this Mac.
struct FeaturesPage: View {
    let model: FeatureSettingsModel
    var readouts: MenuBarReadouts?
    var alerts: MonitorAlerts?
    var loginItem: LoginItemController?
    var clipboard: ClipboardController?
    var openAlerts: () -> Void = {}

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.pageSpacing) {
            // Small: opening at login, and one line how many features run.
            if let loginItem {
                PanelCard {
                    OpenAtLoginRow(controller: loginItem)
                    Divider()
                    LanguageRow()
                }
            }
            Label {
                Text("features.summary.title \(String(model.enabledCount)) \(String(model.switchable.count))")
                    + Text(verbatim: " · ") + Text("features.summary.short")
            } icon: {
                Image(systemName: "switch.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .help(Text("features.summary.message"))

            // The tools have no switches: each is a widget ("+ Widget").
            ForEach(FeatureCategory.allCases.filter { $0 != .tools }, id: \.self) { category in
                let rows = model.rows(in: category)
                if !rows.isEmpty {
                    SectionTitle(
                        verbatim: PanelTexts.title(category),
                        trailing: "\(rows.filter(\.isEnabled).count)/\(rows.count)")
                    PanelCard(spacing: 12) {
                        ForEach(rows) { row in
                            FeatureRowView(row: row, category: category) { model.setEnabled($0, for: row.id) }
                            if row.id == "monitor.menubar", row.isEnabled, let readouts {
                                MenuBarOptions(readouts: readouts)
                            }
                            if row.id == "monitor.alerts", row.isEnabled {
                                // The rules have their own section now.
                                Button("alerts.openRules") { openAlerts() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    .padding(.leading, 38)
                            }
                            if row.id == "clipboard.history", row.isEnabled, let clipboard {
                                ClipboardOptions(controller: clipboard)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FeatureRowView: View {
    let row: FeatureSettingsModel.Row
    let category: FeatureCategory
    let setEnabled: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: PanelTexts.featureSymbol(row.id, category: category), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(PanelTexts.featureTitle(row.id)).font(.callout.weight(.medium))
                    if row.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(Text("features.locked"))
                    }
                }
                HStack(spacing: 4) {
                    // Never cut off ("Jede App einzeln r…"): a second line if needed.
                    Text(PanelTexts.featureShort(row.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .help(Text(PanelTexts.featureSummary(row.id)))
                ForEach(row.permissions, id: \.self) { permission in
                    StatusChip(
                        text: PanelTexts.name(permission), symbol: PanelTexts.symbol(permission), tone: .attention)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { row.isEnabled }, set: setEnabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(row.isLocked)
                .accessibilityLabel(PanelTexts.featureTitle(row.id))
        }
    }
}

/// MacHorus itself at login; System Settings can change it too, so the
/// state is read again whenever the row appears.
private struct OpenAtLoginRow: View {
    let controller: LoginItemController

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: "power", tint: Theme.positive, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.openAtLogin.title").font(.callout.weight(.medium))
                if controller.state == .needsApproval {
                    Text("settings.openAtLogin.approval")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("settings.openAtLogin.openSettings") { controller.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text("settings.openAtLogin.short")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.openAtLogin.message"))
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { controller.state == .on }, set: { controller.setOn($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(Text("settings.openAtLogin.title"))
        }
        .onAppear { controller.refresh() }
    }
}

/// How much memory the whole app may take before the oldest clipboard
/// entries (50 MB) go.
private struct ClipboardOptions: View {
    let controller: ClipboardController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("settings.clipboard.limitShort").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
            }
            .help(Text("settings.clipboard.limit"))
            HStack(spacing: 6) {
                ForEach(ClipboardController.limits, id: \.self) { limit in
                    let selected = limit == controller.limit
                    Button {
                        controller.setLimit(limit)
                    } label: {
                        Text(verbatim: "\(limit) MB")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Theme.goldText : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selected ? Theme.gold.opacity(0.18) : .primary.opacity(0.05)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.leading, 38)
    }
}

/// Which values the menu bar shows.
private struct MenuBarOptions: View {
    let readouts: MenuBarReadouts

    private static let labels: [(MenuBarReadouts.Item, LocalizedStringKey)] = [
        (.cpu, "menubar.item.cpu"), (.memory, "menubar.item.memory"), (.gpu, "menubar.item.gpu"),
        (.temperature, "menubar.item.temperature"), (.network, "menubar.item.network"),
        (.battery, "menubar.item.battery"),
    ]

    var body: some View {
        // Three equal columns when they fit with the longest label at full
        // size ("Temperatur"), else two: six chips never leave one alone.
        ViewThatFits(in: .horizontal) {
            grid(columns: 3)
            grid(columns: 2)
        }
        .padding(.leading, 38)
    }

    /// Only what this Mac can show (`MenuBarReadouts.supported`).
    private var labels: [(MenuBarReadouts.Item, LocalizedStringKey)] {
        Self.labels.filter { label in readouts.supported.contains(label.0) }
    }

    private func grid(columns: Int) -> some View {
        let labels = self.labels
        let rows = stride(from: 0, to: labels.count, by: columns).map {
            labels[$0..<min($0 + columns, labels.count)]
        }
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.0) { item, title in chip(item, title) }
                }
            }
        }
    }

    private func chip(_ item: MenuBarReadouts.Item, _ title: LocalizedStringKey) -> some View {
        let shown = readouts.items.contains(item)
        return Button {
            readouts.setShown(item, !shown)
        } label: {
            Label(title, systemImage: shown ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(shown ? Theme.goldText : .secondary)
                .frame(minWidth: 104, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(shown ? Theme.gold.opacity(0.18) : .primary.opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

/// Deutsch or English; takes effect after MacHorus restarts (one click).
private struct LanguageRow: View {
    @State private var chosen = AppLanguage.current
    private let atLaunch = AppLanguage.current

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: "globe", tint: Theme.lapis, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.language.title").font(.callout.weight(.medium))
                if chosen != atLaunch {
                    Button("settings.language.restart") { AppLanguage.relaunch() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 6)
            // Just the language's name; a click lists the others.
            Menu {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        chosen = language
                    } label: {
                        if language == chosen {
                            Label(language.title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: language.title)
                        }
                    }
                }
            } label: {
                Text(verbatim: chosen.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("settings.language.title"))
            .onChange(of: chosen) { _, language in AppLanguage.choose(language) }
        }
    }
}
