// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusMonitor
import SwiftUI

/// Settings → Alarme: alerts on or off as a whole, notifications with a
/// test, and one card per alert with its current value, whether it is
/// active right now, its switch and its threshold.
struct AlertsPage: View {
    let alerts: MonitorAlerts
    let features: FeatureSettingsModel
    let monitor: SystemMonitorModel

    private var isOn: Bool { features.rows.first { $0.id == "monitor.alerts" }?.isEnabled == true }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.pageSpacing) {
            PanelCard(spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(symbol: "bell.badge", tint: Theme.gold, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("feature.monitor.alerts.title").font(.headline)
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Toggle(
                        "", isOn: Binding(get: { isOn }, set: { features.setEnabled($0, for: "monitor.alerts") })
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(Text("feature.monitor.alerts.title"))
                }
                if isOn, alerts.permission == .notAsked {
                    Divider()
                    // macOS has not been asked yet: one click asks it.
                    HStack(spacing: 8) {
                        Text("alerts.permission.notAsked").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button("alerts.permission.allow") { alerts.requestPermission() }
                            .buttonStyle(PillButtonStyle())
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else if isOn, alerts.permission == .denied {
                    Divider()
                    // Switched off in macOS: only System Settings can allow it again.
                    HStack(spacing: 8) {
                        Label("alerts.permission.denied", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button("tools.mixer.openSettings") {
                            PermissionStatusProvider.openSystemSettings(for: .notifications)
                        }
                        .buttonStyle(PillButtonStyle())
                        .font(.caption)
                    }
                } else if isOn {
                    Divider()
                    HStack(spacing: 8) {
                        Toggle(
                            "alerts.notifications",
                            isOn: Binding(
                                get: { alerts.sendsNotifications }, set: { alerts.setSendsNotifications($0) })
                        )
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        Spacer()
                        Button {
                            alerts.sendTestNotification()
                        } label: {
                            Label("alerts.test", systemImage: "bell")
                        }
                        .buttonStyle(PillButtonStyle())
                        .font(.caption)
                        .disabled(!alerts.sendsNotifications)
                    }
                }
            }
            if isOn {
                SectionTitle(title: "alerts.section.rules")
                AlertRuleCard(kind: .cpuBusy, isOn: \.cpuEnabled, alerts: alerts, now: now(.cpuBusy)) { rules in
                    RuleChoice(
                        alerts: alerts, values: AlertRules.cpuPercents, current: rules.cpuPercent,
                        title: { MonitorFormat.percent($0) }
                    ) {
                        $0.cpuPercent = $1
                    }
                    Text("alerts.rule.for").font(.caption).foregroundStyle(.secondary)
                    RuleChoice(
                        alerts: alerts, values: AlertRules.cpuMinuteChoices, current: rules.cpuMinutes,
                        title: AlertTexts.minutes
                    ) { $0.cpuMinutes = $1 }
                }
                AlertRuleCard(kind: .hot, isOn: \.hotEnabled, alerts: alerts, now: now(.hot)) { rules in
                    Text("alerts.rule.from").font(.caption).foregroundStyle(.secondary)
                    RuleChoice(
                        alerts: alerts, values: AlertRules.hotChoices, current: rules.hotCelsius, title: { "\($0) °C" }
                    ) {
                        $0.hotCelsius = $1
                    }
                }
                AlertRuleCard(kind: .memoryPressure, isOn: \.memoryEnabled, alerts: alerts, now: now(.memoryPressure)) {
                    _ in
                    Text("alerts.rule.critical").font(.caption).foregroundStyle(.secondary)
                }
                AlertRuleCard(kind: .diskFull, isOn: \.diskEnabled, alerts: alerts, now: now(.diskFull)) { rules in
                    Text("alerts.rule.below").font(.caption).foregroundStyle(.secondary)
                    if rules.diskMode == .percent {
                        RuleChoice(
                            alerts: alerts, values: AlertRules.diskPercents, current: rules.diskPercent,
                            title: { MonitorFormat.percent($0) }
                        ) {
                            $0.diskPercent = $1
                        }
                    } else {
                        RuleChoice(
                            alerts: alerts, values: AlertRules.diskGigabyteChoices, current: rules.diskGigabytes,
                            title: { "\($0) GB" }
                        ) { $0.diskGigabytes = $1 }
                    }
                    RuleChoice(
                        alerts: alerts, values: AlertRules.DiskMode.allCases, current: rules.diskMode,
                        title: {
                            String(localized: $0 == .percent ? "alerts.rule.inPercent" : "alerts.rule.inGigabytes")
                        }
                    ) { $0.diskMode = $1 }
                    .help(Text("alerts.rule.diskMode"))
                }
                if MonitorHardware.hasBattery {
                    AlertRuleCard(kind: .batteryLow, isOn: \.batteryEnabled, alerts: alerts, now: now(.batteryLow)) {
                        rules in
                        Text("alerts.rule.below").font(.caption).foregroundStyle(.secondary)
                        RuleChoice(
                            alerts: alerts, values: AlertRules.batteryPercents, current: rules.batteryPercent,
                            title: { MonitorFormat.percent($0) }
                        ) { $0.batteryPercent = $1 }
                    }
                }
                Text("alerts.footer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        // macOS decides; read it each time the page shows and after a visit
        // to System Settings.
        .task { alerts.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            alerts.refreshPermission()
        }
    }

    private var statusLine: String {
        guard isOn else { return String(localized: "alerts.status.off") }
        let count = AlertKind.allCases.filter(alerts.rules.isEnabled).count
        return alerts.active.isEmpty
            ? String(format: String(localized: "alerts.status.watching %@"), String(count))
            : String(format: String(localized: "alerts.status.active %@"), String(alerts.active.count))
    }

    /// The value the rule looks at, right now.
    private func now(_ kind: AlertKind) -> String? {
        switch kind {
        case .cpuBusy: monitor.cpu.map { MonitorFormat.percent($0.total.total) }
        case .hot: monitor.thermal?.cpu.map { MonitorFormat.celsius($0) }
        case .memoryPressure:
            monitor.memory.map {
                String(
                    localized: $0.pressure == .critical
                        ? "monitor.pressure.critical"
                        : $0.pressure == .warning ? "monitor.pressure.warning" : "monitor.pressure.normal")
            }
        case .diskFull:
            monitor.disk.map {
                MonitorFormat.storage($0.availableBytes) + " " + String(localized: "widget.summary.free")
            }
        case .batteryLow: monitor.battery.map { MonitorFormat.percent($0.charge) }
        }
    }
}

/// One alert: symbol, name, the value now, a state chip, its switch, and
/// the threshold controls below.
private struct AlertRuleCard<Controls: View>: View {
    let kind: AlertKind
    let isOn: WritableKeyPath<AlertRules, Bool>
    let alerts: MonitorAlerts
    let now: String?
    @ViewBuilder let controls: (AlertRules) -> Controls

    var body: some View {
        let enabled = alerts.rules[keyPath: isOn]
        let active = alerts.active.contains(kind)
        PanelCard(spacing: 8) {
            HStack(spacing: 10) {
                IconTile(symbol: AlertTexts.symbol(kind), tint: active ? Theme.critical : Theme.lapis, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: AlertTexts.title(kind)).font(.callout.weight(.semibold)).lineLimit(1)
                    if let now {
                        Text(verbatim: String(format: String(localized: "alerts.now %@"), now))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if enabled, active {
                    StatusChip(
                        text: String(localized: "alerts.chip.active"), symbol: "exclamationmark.triangle.fill",
                        tone: .critical)
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { value in
                            var rules = alerts.rules
                            rules[keyPath: isOn] = value
                            alerts.setRules(rules)
                        })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: AlertTexts.title(kind)))
            }
            HStack(spacing: 6) { controls(alerts.rules) }
                .padding(.leading, 40)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// A small menu with fixed values; the chosen one is ticked.
private struct RuleChoice<Value: Hashable>: View {
    let alerts: MonitorAlerts
    let values: [Value]
    let current: Value
    let title: (Value) -> String
    let set: (inout AlertRules, Value) -> Void

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    var rules = alerts.rules
                    set(&rules, value)
                    alerts.setRules(rules)
                } label: {
                    if value == current {
                        Label(title(value), systemImage: "checkmark")
                    } else {
                        Text(verbatim: title(value))
                    }
                }
            }
        } label: {
            Text(verbatim: title(current)).font(.caption.weight(.semibold).monospacedDigit())
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle())
        .fixedSize()
    }
}
