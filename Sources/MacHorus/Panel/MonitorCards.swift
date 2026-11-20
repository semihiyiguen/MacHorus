// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import MacHorusTools
import SwiftUI

struct NetworkCard: View {
    let network: NetworkSnapshot?
    let history: [Double]
    var peripherals: PeripheralsModel?
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(spacing: 8) {
                // "–" means no reading yet; "Not measurable" only when the
                // source cannot count incoming traffic at all.
                RateTile(
                    symbol: "arrow.down", title: "monitor.network.down",
                    value: MonitorFormat.rate(network?.downloadBytesPerSecond),
                    unavailable: network?.measurement == .interfacesInboundBlind)
                RateTile(
                    symbol: "arrow.up", title: "monitor.network.up",
                    value: MonitorFormat.rate(network?.uploadBytesPerSecond), unavailable: false)
            }
            Sparkline(values: MonitorFormat.normalized(history), capacity: SystemMonitorModel.historyLength)
                .frame(height: 30)
            if let network {
                DetailRow(title: "monitor.network.interface", value: network.primaryInterface ?? "–")
                DetailRow(title: "monitor.network.ip", value: network.localIPv4 ?? "–")
                if let wifi = peripherals?.wifi {
                    DetailRow(
                        title: "monitor.network.wifi.signal",
                        value: "\(wifi.rssi) dBm · \(PeripheralTexts.level(wifi.level))")
                    DetailRow(title: "monitor.network.wifi.link", value: PeripheralTexts.link(wifi))
                }
                if network.measurement == .interfacesInboundBlind {
                    Label("monitor.network.blind", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Wi-Fi link quality every 5 s while this card shows (one CoreWLAN call).
        .task(id: panelIsShown) {
            while panelIsShown, let peripherals, !Task.isCancelled {
                peripherals.refreshWiFi()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

}

private struct RateTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let unavailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if unavailable {
                Text("monitor.network.unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(Text("monitor.network.blind"))
            } else {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

struct DiskCard: View {
    let disk: DiskSnapshot?
    let history: [Double]
    var usage: DiskUsageModel?

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MonitorFormat.storage(disk?.availableBytes))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("monitor.disk.free \(MonitorFormat.storage(disk?.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let disk {
                MeterBar(value: disk.usedFraction, color: Theme.lapis, height: 8)
                UsedFreeRow(
                    used: MonitorFormat.storage(disk.usedBytes), free: MonitorFormat.storage(disk.availableBytes))
                HStack(spacing: 8) {
                    MetricTile(
                        symbol: "arrow.down.doc", title: "monitor.disk.read",
                        value: MonitorFormat.rate(disk.readBytesPerSecond))
                    MetricTile(
                        symbol: "arrow.up.doc", title: "monitor.disk.write",
                        value: MonitorFormat.rate(disk.writeBytesPerSecond))
                }
            }
            Sparkline(values: MonitorFormat.normalized(history), capacity: SystemMonitorModel.historyLength)
                .frame(height: 30)
            if let usage { DiskUsageSection(usage: usage) }
        }
    }
}

/// The largest folders and files in the home folder, on request.
private struct DiskUsageSection: View {
    let usage: DiskUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("disk.usage.folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if usage.isScanning {
                    ProgressView().controlSize(.mini)
                    Text("disk.usage.scanning").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(usage.report == nil ? "disk.usage.scan" : "disk.usage.rescan") { usage.scan() }
                        .buttonStyle(PillButtonStyle())
                        .font(.caption)
                }
            }
            if let report = usage.report {
                ForEach(report.folders) { row($0, symbol: "folder") }
                if !report.files.isEmpty {
                    Text("disk.usage.files").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(report.files) { row($0, symbol: "doc") }
                }
                if !report.denied.isEmpty {
                    Text("disk.usage.denied \(report.denied.prefix(3).joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("disk.usage.asOf \(report.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if !usage.isScanning {
                Text("disk.usage.hint").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: DiskUsageReport.Entry, symbol: String) -> some View {
        Button {
            usage.reveal(entry.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.caption).foregroundStyle(Theme.goldText).frame(width: 16)
                Text(verbatim: entry.relativePath).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(MonitorFormat.storage(entry.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("disk.usage.reveal"))
    }
}

struct BatteryCard: View {
    let battery: BatterySnapshot?

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(battery.map { MonitorFormat.percent($0.charge) } ?? "–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let battery { stateText(battery) }
                Spacer()
            }
            if let battery {
                MeterBar(
                    value: Double(battery.charge) / 100,
                    color: battery.color,
                    height: 8)
                DetailRow(
                    title: battery.isCharging ? "monitor.battery.untilFull" : "monitor.battery.remaining",
                    value: battery.isOnExternalPower && !battery.isCharging
                        ? "–" : MonitorFormat.duration(minutes: battery.minutesRemaining))
                DetailRow(
                    title: "monitor.battery.health",
                    value: battery.healthPercent.map { MonitorFormat.percent($0) } ?? "–")
                DetailRow(title: "monitor.battery.cycles", value: battery.cycleCount.map(String.init) ?? "–")
                DetailRow(
                    title: "monitor.battery.power",
                    value: battery.powerWatts.map { abs($0).formatted(.number.precision(.fractionLength(1))) + " W" }
                        ?? "–")
            }
        }
    }

    private var symbol: String {
        guard let battery else { return "battery.100" }
        if battery.isCharging { return "battery.100.bolt" }
        if battery.isOnExternalPower { return "powerplug" }
        return battery.charge <= 20 ? "battery.25" : "battery.75"
    }

    @ViewBuilder private func stateText(_ battery: BatterySnapshot) -> some View {
        Group {
            if battery.isCharging {
                Text("monitor.battery.charging")
            } else if battery.isOnExternalPower {
                Text("monitor.battery.onPower")
            } else {
                Text("monitor.battery.discharging")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DetailRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}
