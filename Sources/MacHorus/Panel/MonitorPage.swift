// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusCore
import MacHorusMonitor
import SwiftUI

struct MonitorOffCard: View {
    let features: FeatureSettingsModel

    var body: some View {
        PanelCard {
            HStack(spacing: 12) {
                IconTile(symbol: PanelTexts.symbol(.monitor), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("monitor.off.title").font(.headline)
                    Text("monitor.off.message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Only the monitor; other features keep the user's choice.
            Button("monitor.off.enable") { features.setEnabled(true, for: "monitor.system") }
                .buttonStyle(PillButtonStyle())
        }
    }
}

struct CPUCard: View {
    let cpu: CPUSnapshot?
    let history: [Double]

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MonitorFormat.percent(cpu?.total.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        "monitor.cpu.split \(MonitorFormat.percent(cpu?.total.user)) \(MonitorFormat.percent(cpu?.total.system))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer()
            }
            Sparkline(values: history, capacity: SystemMonitorModel.historyLength)
                .frame(height: 38)
            if let cpu {
                // Only chips with performance and efficiency cores (not Intel).
                if let performance = cpu.average(of: .performance) {
                    ClusterRow(title: "monitor.cpu.performance", value: performance, color: Theme.gold)
                }
                if let efficiency = cpu.average(of: .efficiency) {
                    ClusterRow(title: "monitor.cpu.efficiency", value: efficiency, color: Theme.lapis)
                }
                CoreBars(
                    loads: cpu.cores.map(\.total),
                    colors: cpu.coreKinds.map { $0 == .performance ? Theme.gold : Theme.lapis }
                )
                .frame(height: 30)
                .help(Text("monitor.cpu.cores.help \(String(cpu.cores.count))"))
            }
        }
    }
}

private struct ClusterRow: View {
    let title: LocalizedStringKey
    let value: Double?
    let color: Color

    var body: some View {
        if let value {
            HStack(spacing: 10) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .leading)
                MeterBar(value: value, color: color)
                Text(MonitorFormat.percent(value))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

struct MemoryCard: View {
    let memory: MemorySnapshot?
    let history: [Double]

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MonitorFormat.bytes(memory?.used))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("monitor.memory.of \(MonitorFormat.bytes(memory?.physical))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let memory { PressureChip(pressure: memory.pressure) }
            }
            if let memory {
                StackedBar(segments: [
                    .init(id: "app", fraction: fraction(memory.app, memory), color: Theme.lapis),
                    .init(id: "wired", fraction: fraction(memory.wired, memory), color: Theme.gold),
                    .init(id: "compressed", fraction: fraction(memory.compressed, memory), color: Theme.attention),
                ])
                UsedFreeRow(
                    used: MonitorFormat.bytes(memory.used),
                    free: MonitorFormat.bytes(memory.physical > memory.used ? memory.physical - memory.used : 0))
                VStack(spacing: 6) {
                    LegendRow(color: Theme.lapis, title: "monitor.memory.app", value: memory.app)
                    LegendRow(color: Theme.gold, title: "monitor.memory.wired", value: memory.wired)
                    LegendRow(color: Theme.attention, title: "monitor.memory.compressed", value: memory.compressed)
                    LegendRow(color: .secondary.opacity(0.4), title: "monitor.memory.cached", value: memory.cachedFiles)
                    LegendRow(color: .clear, title: "monitor.memory.swap", value: memory.swapUsed)
                }
            }
            Sparkline(values: history, color: Theme.lapis, capacity: SystemMonitorModel.historyLength)
                .frame(height: 30)
        }
    }

    private func fraction(_ bytes: UInt64, _ memory: MemorySnapshot) -> Double {
        memory.physical > 0 ? Double(bytes) / Double(memory.physical) : 0
    }
}

/// "Used 12 GB … Free 4 GB" right under a bar (user feedback).
struct UsedFreeRow: View {
    let used: String
    let free: String

    var body: some View {
        HStack {
            Text("monitor.used \(used)")
            Spacer()
            Text("monitor.free \(free)")
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

private struct LegendRow: View {
    let color: Color
    let title: LocalizedStringKey
    let value: UInt64

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(MonitorFormat.bytes(value))
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }
}

private struct PressureChip: View {
    let pressure: MemoryPressure

    var body: some View {
        switch pressure {
        case .normal:
            StatusChip(text: String(localized: "monitor.pressure.normal"), symbol: "circle.fill", tone: .positive)
        case .warning:
            StatusChip(
                text: String(localized: "monitor.pressure.warning"), symbol: "exclamationmark.triangle.fill",
                tone: .attention)
        case .critical:
            StatusChip(
                text: String(localized: "monitor.pressure.critical"), symbol: "xmark.octagon.fill", tone: .critical)
        }
    }
}

enum MonitorFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// A whole percentage (battery charge, a volume level), written the way
    /// the language does: "46%" in English, "46 %" in German.
    static func percent(_ whole: Int) -> String {
        (Double(whole) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// Storage sizes in decimal units, as Finder shows them.
    static func storage(_ value: UInt64?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    /// Transfer rates in decimal units per second (KB/s, MB/s).
    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file) + "/s"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(0))) + " °C"
    }

    static func duration(minutes: Int?) -> String {
        guard let minutes else { return "–" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// Scales a rate history to 0…1 for a sparkline; a small floor keeps an
    /// idle line flat instead of magnifying noise.
    static func normalized(_ values: [Double], floor: Double = 64 * 1_024) -> [Double] {
        let top = max(values.max() ?? 0, floor)
        return values.map { $0 / top }
    }
}
