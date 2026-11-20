// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// For bug reports (`MacHorus --print-diagnosis`): what MacHorus can
/// measure on this Mac, one fresh round of readings, impossible readings
/// and what is switched on, so it shows why a value is missing or wrong.
/// English and fixed in form, like the log. No serial number, computer
/// name, addresses or app names.
public struct DiagnosisFacts: Sendable {
    public var app: String
    public var mac: MacIdentity
    /// "arm64", "x86_64" or "x86_64 (Rosetta)".
    public var architecture: String
    public var capabilities: HardwareCapabilities
    public var allowedPrivateAPIs: [String]
    public var enabledMetrics: Set<Metric>
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var disk: DiskSnapshot?
    public var network: NetworkSnapshot?
    public var battery: BatterySnapshot?
    public var thermal: ThermalSnapshot?
    public var gpu: GPUSnapshot?
    public var anomalies: [(date: Date, anomaly: Anomaly)]
    public var features: [String]
    public var schema: Int
    public var now: Date

    public init(
        app: String, mac: MacIdentity, architecture: String, capabilities: HardwareCapabilities,
        allowedPrivateAPIs: [String], enabledMetrics: Set<Metric>, cpu: CPUSnapshot?, memory: MemorySnapshot?,
        disk: DiskSnapshot?, network: NetworkSnapshot?, battery: BatterySnapshot?, thermal: ThermalSnapshot?,
        gpu: GPUSnapshot?, anomalies: [(date: Date, anomaly: Anomaly)], features: [String], schema: Int, now: Date
    ) {
        self.app = app
        self.mac = mac
        self.architecture = architecture
        self.capabilities = capabilities
        self.allowedPrivateAPIs = allowedPrivateAPIs
        self.enabledMetrics = enabledMetrics
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.thermal = thermal
        self.gpu = gpu
        self.anomalies = anomalies
        self.features = features
        self.schema = schema
        self.now = now
    }
}

public enum Diagnosis {
    public static func text(_ facts: DiagnosisFacts) -> String {
        let gib = 1_073_741_824.0
        func percent(_ share: Double?) -> String { share.map { String(format: "%.0f %%", $0 * 100) } ?? "none" }
        func gigabytes(_ bytes: UInt64?) -> String {
            bytes.map { String(format: "%.1f GB", Double($0) / gib) } ?? "none"
        }
        // Storage like Finder: decimal GB.
        func storage(_ bytes: UInt64?) -> String {
            bytes.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "none"
        }
        func rate(_ value: Double?) -> String { value.map { String(format: "%.0f B/s", $0) } ?? "none" }
        func celsius(_ value: Double?) -> String { value.map { String(format: "%.0f °C", $0) } ?? "none" }
        func mark(_ metric: Metric) -> String { facts.enabledMetrics.contains(metric) ? "yes" : "no" }
        let caps = facts.capabilities
        // Idle GPU blocks report exactly 30 °C, which MacHorus ignores.
        let gpuTemperature =
            facts.thermal?.gpu.map { celsius($0) }
            ?? (facts.thermal != nil && caps.temperatureGroups.contains(.gpu)
                ? "idle (sensors report the powered-down 30 °C)" : "none")
        let mac = facts.mac
        var lines = [
            "--- MacHorus diagnosis (\(facts.app)) ---",
            "Mac: \(mac.model ?? "unknown") · \(facts.architecture)",
            "Private interfaces allowed: \(facts.allowedPrivateAPIs.isEmpty ? "none" : facts.allowedPrivateAPIs.sorted().joined(separator: ", "))",
            "",
            "Measurable on this Mac:",
            "  CPU \(mark(.cpu)) · memory \(mark(.memory)) · disk \(mark(.disk)) · network \(mark(.network)) · processes \(mark(.processes))",
            "  GPU \(mark(.gpu))\(caps.hasGPUStatistics ? "" : " (no GPU statistics from IOAccelerator)")",
            "  temperature \(mark(.thermal)): "
                + (caps.temperatureGroups.isEmpty
                    ? "no sensors found (HID, and SMC keys on Intel)"
                    : caps.temperatureGroups.map { "\($0)" }.sorted().joined(separator: ", ")),
            "  fans: \(caps.fanCount)",
            "  battery \(mark(.power))\(caps.hasBattery ? "" : " (no internal battery)")",
            "",
            "Readings, measured for this diagnosis (none = this Mac delivered no value):",
            "  CPU \(percent(facts.cpu?.total.total)) · cores \(facts.cpu?.cores.count ?? 0)",
            "  memory used \(gigabytes(facts.memory?.used)) of \(gigabytes(facts.memory?.physical)) · swap \(gigabytes(facts.memory?.swapUsed))",
            "  disk free \(storage(facts.disk?.availableBytes)) of \(storage(facts.disk?.totalBytes))",
            "  network down \(rate(facts.network?.downloadBytesPerSecond)) · up \(rate(facts.network?.uploadBytesPerSecond)) · method \(facts.network?.measurement.rawValue ?? "none") · connected \(facts.network.map { $0.primaryInterface != nil ? "yes" : "no" } ?? "none")",
            "  temperature CPU \(celsius(facts.thermal?.cpu)) · GPU \(gpuTemperature) · pressure \(facts.thermal.map { "\($0.pressure)" } ?? "none")",
            "  GPU \(percent(facts.gpu?.utilization))",
            "  battery \(facts.battery.map { "\($0.charge) %" } ?? "none") · health \(facts.battery?.healthPercent.map { "\($0) %" } ?? "none") · cycles \(facts.battery?.cycleCount.map(String.init) ?? "none")",
            "",
        ]
        if facts.anomalies.isEmpty {
            lines.append("Implausible readings: none")
        } else {
            lines.append("Implausible readings (newest first):")
            for entry in facts.anomalies {
                let time = ISO8601DateFormatter.string(
                    from: entry.date, timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
                lines.append("  \(time) \(entry.anomaly.metric.rawValue): \(entry.anomaly.text)")
            }
        }
        lines.append("")
        lines.append("Features on (\(facts.features.count)): \(facts.features.sorted().joined(separator: ", "))")
        lines.append("Settings schema: \(facts.schema)")
        return lines.joined(separator: "\n")
    }
}
