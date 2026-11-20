// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import SwiftUI

/// How long the Mac has been on, and whether a restart is advisable; the
/// chip opens the reasons (also from the overview's restart point).
struct HealthStrip: View {
    @Bindable var monitor: SystemMonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    Text("monitor.health.uptime \(RestartTexts.duration(monitor.uptime))")
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Narrow: two lines rather than "3 Tg., 14 S…".
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    monitor.showsRestartReasons.toggle()
                } label: {
                    RestartChip(level: monitor.restartAdvice.level).fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(monitor.restartAdvice.reasons.isEmpty)
                .help(Text("monitor.health.reasons.help"))
            }
            if monitor.showsRestartReasons, !monitor.restartAdvice.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(monitor.restartAdvice.reasons.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: RestartChip.symbol(item.level))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(RestartChip.tone(item.level).color)
                                .accessibilityHidden(true)
                            Text(verbatim: RestartTexts.text(item.reason))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("monitor.health.rules")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
            }
        }
    }
}

struct RestartChip: View {
    let level: RestartAdvice.Level

    var body: some View {
        switch level {
        case .none:
            StatusChip(
                text: String(localized: "monitor.health.restart.none"), symbol: "checkmark.circle.fill", tone: .positive
            )
        case .low:
            StatusChip(text: String(localized: "monitor.health.restart.low"), symbol: "arrow.clockwise", tone: .accent)
        case .medium:
            StatusChip(
                text: String(localized: "monitor.health.restart.medium"), symbol: "arrow.clockwise.circle",
                tone: .attention)
        case .high:
            StatusChip(
                text: String(localized: "monitor.health.restart.high"), symbol: "exclamationmark.arrow.circlepath",
                tone: .critical)
        }
    }

    static func tone(_ level: RestartAdvice.Level) -> Tone {
        switch level {
        case .none: .positive
        case .low: .accent
        case .medium: .attention
        case .high: .critical
        }
    }

    /// The level also as a shape, not by colour alone.
    static func symbol(_ level: RestartAdvice.Level) -> String {
        switch level {
        case .none: "checkmark.circle.fill"
        case .low: "info.circle.fill"
        case .medium: "exclamationmark.triangle.fill"
        case .high: "xmark.octagon.fill"
        }
    }
}

/// The Wi-Fi signal under the network row, as the expanded card shows it;
/// read every 5 s while visible (one CoreWLAN call, off the main thread).
struct WiFiLine: View {
    let peripherals: PeripheralsModel
    let primary: String?

    var body: some View {
        if let wifi = peripherals.wifi {
            let weak = wifi.interface == primary && wifi.rssi < -75
            Label {
                Text(verbatim: "\(wifi.rssi) dBm · \(PeripheralTexts.level(wifi.level))")
            } icon: {
                Image(systemName: weak ? "wifi.exclamationmark" : "wifi")
            }
            .font(.caption)
            .foregroundStyle(weak ? Theme.attention : .secondary)
            .padding(.leading, 24)
            .help(Text("monitor.network.wifi.signal"))
        }
    }
}

struct UsageRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let meter: Double?
    let color: Color
    let history: [Double]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Name, bar and value on one line; the history below.
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // A fixed column, so the bars start at the same place.
                    .frame(width: 118, alignment: .leading)
                if let meter {
                    MeterBar(value: meter, color: color, height: 4).frame(minWidth: 24)
                } else {
                    Spacer(minLength: 6)
                }
                Text(verbatim: value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(2)
            }
            if let history {
                Sparkline(values: history, color: color, capacity: SystemMonitorModel.historyLength)
                    .frame(height: 14)
                    .padding(.leading, 24)
            }
        }
    }
}

/// Texts of the restart advice, shared by the overview and the monitor.
enum RestartTexts {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "–" }
        return Duration.seconds(Int64(seconds)).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    static func text(_ reason: RestartAdvice.Reason) -> String {
        switch reason {
        case .uptime(let seconds):
            return localized("monitor.health.reason.uptime %@").replacingOccurrences(of: "%@", with: duration(seconds))
        case .swap(let bytes, let share):
            return String(
                format: localized("monitor.health.reason.swap %@ %@"), MonitorFormat.bytes(bytes),
                share.formatted(.percent.precision(.fractionLength(0))))
        case .memoryPressure(let pressure):
            return localized(pressure == .critical ? "monitor.health.reason.critical" : "monitor.health.reason.warning")
        }
    }

    static func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }
}
