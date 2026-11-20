// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import SwiftUI

/// Which Mac this is and how it is doing: all good is one green line; what
/// needs attention follows as points (info, warning, critical), each with
/// its own symbol and opening the page that shows more.
struct MacCard: View {
    let monitor: SystemMonitorModel
    let alerts: Set<AlertKind>
    let updates: SoftwareUpdates?
    var peripherals: PeripheralsModel?
    var dismissals: StatusDismissals?
    var culprits: [AlertKind: AlertCulpritRow] = [:]
    var alertRules = AlertRules()
    let open: (PanelTab) -> Void
    private let mac = MacIdentity.current
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        let wifi = peripherals?.wifi
        let items = StatusSummary.items(
            restart: monitor.restartAdvice, disk: monitor.disk, battery: monitor.battery, thermal: monitor.thermal,
            alerts: alerts, updates: updates, accessories: peripherals?.accessories ?? [], wifi: wifi,
            wifiIsPrimary: wifi != nil && wifi?.interface == monitor.network?.primaryInterface,
            dismissed: dismissals?.set ?? [], rules: alertRules)
        PanelCard(spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: PanelTab.overview.symbol, tint: Theme.lapis, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: DemoMode.isOn ? DemoMode.computerName : mac.computerName ?? mac.model ?? "Mac")
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            // Uptime and restart advice side by side; stacked rather than
            // cut off when the card is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    uptime.fixedSize()
                    Spacer(minLength: 4)
                    RestartChip(level: monitor.restartAdvice.level).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    uptime
                    RestartChip(level: monitor.restartAdvice.level)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        StatusPoint(item: item, monitor: monitor, dismissals: dismissals, open: open)
                        if case .alert(let kind) = item.kind, let culprit = culprits[kind] {
                            CulpritLine(culprit: culprit)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var uptime: some View {
        Label {
            Text("monitor.health.uptime \(RestartTexts.duration(monitor.uptime))")
        } icon: {
            Image(systemName: "clock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var subtitle: String {
        let parts = [mac.chip, mac.memoryBytes.map { MonitorFormat.bytes($0) }, "macOS \(mac.systemVersion)"]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// One point: a symbol for how urgent (info, warning, critical; not by
/// colour alone), what it is and its value. Info points can be hidden.
private struct StatusPoint: View {
    let item: StatusItem
    let monitor: SystemMonitorModel
    var dismissals: StatusDismissals?
    let open: (PanelTab) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let target {
                Button {
                    // The restart point opens its reasons, not just the page.
                    if case .restart = item.kind { monitor.showsRestartReasons = true }
                    open(target)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        content
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: spoken))
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spoken))
            }
            if let dismissals, item.dismissKey != nil {
                Button {
                    dismissals.dismiss(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("overview.hint.dismiss"))
                .accessibilityLabel(Text("overview.hint.dismiss"))
            }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tone.color)
                .frame(width: 14)
                .accessibilityHidden(true)
            (Text(verbatim: StatusTexts.title(item)).font(.caption.weight(.semibold))
                + Text(verbatim: StatusTexts.detail(item).map { " · " + $0 } ?? "").font(.caption)
                .foregroundColor(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
    }

    private var symbol: String {
        switch item.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var tone: Tone {
        switch item.severity {
        case .info: .neutral
        case .warning: .attention
        case .critical: .critical
        }
    }

    private var spoken: String {
        let level: String =
            switch item.severity {
            case .info: String(localized: "overview.hint.level.info")
            case .warning: String(localized: "overview.hint.level.warning")
            case .critical: String(localized: "overview.hint.level.critical")
            }
        return ([level, StatusTexts.title(item)] + [StatusTexts.detail(item)].compactMap { $0 }).joined(separator: ", ")
    }

    /// The page that shows more; nil when the point already says it all.
    private var target: PanelTab? {
        switch item.kind {
        case .updates: .tools
        case .accessoryBattery: .tools
        default: .monitor
        }
    }
}

/// Who causes a CPU, heat or memory alert, with a way to quit it (the same
/// checks and confirmation as the process list).
private struct CulpritLine: View {
    let culprit: AlertCulpritRow

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProcessActions.icon(for: culprit.row.identity))
                .frame(width: 14, height: 14)
            Text(verbatim: culprit.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if ProcessActions.canAct(on: culprit.row.identity) {
                Button("alerts.culprit.quit") { ProcessActions.quit(culprit.row) }
                    .buttonStyle(PillButtonStyle())
                    .font(.caption)
            }
        }
        .padding(.leading, 22)
    }
}

/// Words for the status points.
enum StatusTexts {
    static func title(_ item: StatusItem) -> String {
        switch item.kind {
        // The chip above says how strongly; the point says why.
        case .restart(let reason, _): RestartTexts.text(reason)
        case .alert(let kind): AlertTexts.title(kind)
        case .diskAlmostFull: String(localized: "overview.hint.disk")
        case .batteryWorn: String(localized: "overview.hint.battery")
        case .thermal: String(localized: "overview.hint.thermal")
        case .updates(let count, _):
            count == 1
                ? String(localized: "overview.hints.updates.one")
                : String(localized: "overview.hints.updates \(String(count))")
        case .accessoryBattery(let accessory):
            RestartTexts.localized("overview.hint.accessory %@").replacingOccurrences(
                of: "%@", with: PeripheralTexts.name(accessory.kind))
        case .weakWiFi: String(localized: "overview.hint.wifi")
        }
    }

    static func detail(_ item: StatusItem) -> String? {
        switch item.kind {
        case .restart: nil
        case .alert(let kind): AlertTexts.detail(kind)
        case .diskAlmostFull(let bytes, let share):
            String(
                format: RestartTexts.localized("overview.hint.disk.detail %@ %@"), MonitorFormat.storage(bytes),
                share.formatted(.percent.precision(.fractionLength(0))))
        case .batteryWorn(let health):
            RestartTexts.localized("overview.hint.battery.detail %@").replacingOccurrences(
                of: "%@", with: MonitorFormat.percent(health))
        case .thermal(let pressure):
            String(
                localized: pressure == .critical
                    ? "monitor.thermal.pressure.critical" : "monitor.thermal.pressure.serious")
        case .updates(_, let needsRestart):
            needsRestart
                ? String(localized: "overview.hints.updates.restart")
                : String(localized: "overview.hints.updates.detail")
        case .accessoryBattery(let accessory): MonitorFormat.percent(accessory.percent)
        case .weakWiFi(let rssi):
            RestartTexts.localized("overview.hint.wifi.detail %@").replacingOccurrences(of: "%@", with: "\(rssi)")
        }
    }
}

struct RingsCard: View {
    let monitor: SystemMonitorModel

    var body: some View {
        PanelCard {
            HStack(spacing: 4) {
                RingGauge(
                    value: monitor.cpu?.total.total, text: MonitorFormat.percent(monitor.cpu?.total.total),
                    title: "overview.ring.cpu", color: LoadColor.cpu(monitor.cpu?.total.total))
                RingGauge(
                    value: monitor.memory?.usedFraction, text: MonitorFormat.percent(monitor.memory?.usedFraction),
                    title: "overview.ring.memory", color: LoadColor.memory(monitor.memory?.pressure))
                RingGauge(
                    value: monitor.disk?.usedFraction, text: MonitorFormat.percent(monitor.disk?.usedFraction),
                    title: "overview.ring.disk", color: LoadColor.disk(monitor.disk?.usedFraction))
                if let battery = monitor.battery {
                    RingGauge(
                        value: Double(battery.charge) / 100, text: MonitorFormat.percent(battery.charge),
                        title: "overview.ring.battery",
                        color: battery.color)
                }
            }
        }
    }
}
