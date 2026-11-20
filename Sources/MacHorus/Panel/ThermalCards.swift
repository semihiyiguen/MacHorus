// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import SwiftUI

/// Temperatures from the chip's own sensors and the fan speed. macOS shows
/// neither; the values are checked against the SMC (docs/MEASUREMENTS.md).
struct ThermalCard: View {
    let thermal: ThermalSnapshot?
    let history: [Double]

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MonitorFormat.celsius(thermal?.cpu))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("monitor.thermal.cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let thermal { ThermalPressureChip(pressure: thermal.pressure) }
            }
            // 20–105 °C spans idle to the limit where Apple Silicon throttles.
            Sparkline(
                values: history.map { min(max(($0 - 20) / 85, 0), 1) }, color: Theme.attention,
                capacity: SystemMonitorModel.historyLength
            )
            .frame(height: 30)
            if let thermal {
                if thermal.hasSensors {
                    // Only sensors this chip has: a missing one is no reading.
                    if thermal.groups.contains(.performanceCores) {
                        DetailRow(
                            title: "monitor.thermal.performance", value: MonitorFormat.celsius(thermal.performanceCores)
                        )
                    }
                    if thermal.groups.contains(.efficiencyCores) {
                        DetailRow(
                            title: "monitor.thermal.efficiency", value: MonitorFormat.celsius(thermal.efficiencyCores))
                    }
                    if thermal.groups.isDisjoint(with: [.performanceCores, .efficiencyCores]),
                        thermal.groups.contains(.die)
                    {
                        DetailRow(title: "monitor.thermal.die", value: MonitorFormat.celsius(thermal.die))
                    }
                    if thermal.groups.contains(.gpu) {
                        // The GPU's sensors report nothing while it is powered down.
                        DetailRow(
                            title: "monitor.thermal.gpu",
                            value: thermal.gpu.map { MonitorFormat.celsius($0) }
                                ?? String(localized: "monitor.thermal.gpu.idle"))
                    }
                    if thermal.ssd != nil {
                        DetailRow(title: "monitor.thermal.ssd", value: MonitorFormat.celsius(thermal.ssd))
                    }
                    if thermal.battery != nil {
                        DetailRow(title: "monitor.thermal.battery", value: MonitorFormat.celsius(thermal.battery))
                    }
                } else {
                    Label("monitor.thermal.unavailable", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(thermal.fans.enumerated()), id: \.offset) { index, fan in
                    HStack {
                        Group {
                            if thermal.fans.count == 1 {
                                Text("monitor.thermal.fan")
                            } else {
                                Text("monitor.thermal.fan.numbered \(String(index + 1))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Text(fanText(fan)).font(.caption.weight(.medium)).monospacedDigit()
                    }
                }
            }
        }
    }

    private func fanText(_ fan: FanReading) -> String {
        guard fan.isRunning else { return String(localized: "monitor.thermal.fan.off") }
        let rpm = fan.rpm.formatted(.number.precision(.fractionLength(0)))
        return Bundle.main.localizedString(forKey: "monitor.thermal.fan.rpm %@", value: nil, table: nil)
            .replacingOccurrences(of: "%@", with: rpm)
    }
}

private struct ThermalPressureChip: View {
    let pressure: ThermalPressure

    var body: some View {
        switch pressure {
        case .nominal:
            StatusChip(
                text: String(localized: "monitor.thermal.pressure.nominal"), symbol: "circle.fill", tone: .positive)
        case .fair:
            StatusChip(
                text: String(localized: "monitor.thermal.pressure.fair"), symbol: "thermometer.medium",
                tone: .attention)
        case .serious:
            StatusChip(
                text: String(localized: "monitor.thermal.pressure.serious"), symbol: "thermometer.high",
                tone: .attention)
        case .critical:
            StatusChip(
                text: String(localized: "monitor.thermal.pressure.critical"), symbol: "flame.fill", tone: .attention)
        }
    }
}

struct GPUCard: View {
    let gpu: GPUSnapshot?
    let history: [Double]

    var body: some View {
        PanelCard(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MonitorFormat.percent(gpu?.utilization))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let model = gpu?.model, let cores = gpu?.coreCount {
                    Text("monitor.gpu.model \(model) \(String(cores))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let gpu {
                MeterBar(value: gpu.utilization, color: Theme.gold, height: 8)
            }
            Sparkline(values: history, color: Theme.gold, capacity: SystemMonitorModel.historyLength)
                .frame(height: 30)
            if let memory = gpu?.memoryInUse {
                DetailRow(title: "monitor.gpu.memory", value: MonitorFormat.bytes(memory))
            }
        }
    }
}
