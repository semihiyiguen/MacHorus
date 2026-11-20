// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// A value outside what any Mac can deliver: a reading went wrong (a
/// counter wrapped, a sensor or interface reported nonsense). The widget
/// shows "?" instead of the number, the log and the diagnosis say what.
public struct Anomaly: Equatable, Sendable {
    public let metric: Metric
    /// English, for the log and the diagnosis text (bug reports quote both).
    public let text: String

    public init(metric: Metric, text: String) {
        self.metric = metric
        self.text = text
    }
}

/// Cheap range checks on one sampling round (a few comparisons; runs on
/// every round).
public enum Plausibility {
    /// 100 Gbit/s: faster than any Mac's interface.
    static let fastestNetwork = 12.5e9
    /// Faster than any internal or external SSD.
    static let fastestDisk = 50e9

    public static func check(_ snapshot: MonitorSnapshot) -> [Anomaly] {
        var found: [Anomaly] = []
        func flag(_ metric: Metric, _ text: String) { found.append(Anomaly(metric: metric, text: text)) }
        func share(_ value: Double) -> Bool { value.isFinite && value >= -0.01 && value <= 1.01 }

        if let cpu = snapshot.cpu {
            if !share(cpu.total.total) { flag(.cpu, "CPU load \(cpu.total.total) outside 0…1") }
            if cpu.cores.contains(where: { !share($0.total) }) { flag(.cpu, "a core's load outside 0…1") }
        }
        if let memory = snapshot.memory {
            if memory.physical == 0 {
                flag(.memory, "physical memory reported as 0")
            } else if Double(memory.used) > Double(memory.physical) * 1.05 {
                flag(.memory, "used \(memory.used) B above physical \(memory.physical) B")
            }
            if memory.swapTotal > 0, memory.swapUsed > memory.swapTotal {
                flag(.memory, "swap used \(memory.swapUsed) B above swap total \(memory.swapTotal) B")
            }
        }
        if let disk = snapshot.disk {
            if disk.totalBytes == 0 {
                flag(.disk, "disk size reported as 0")
            } else if disk.availableBytes > disk.totalBytes {
                flag(.disk, "free \(disk.availableBytes) B above size \(disk.totalBytes) B")
            }
            for rate in [disk.readBytesPerSecond, disk.writeBytesPerSecond]
            where !rate.isFinite || rate < 0 || rate > fastestDisk {
                flag(.disk, "disk rate \(rate) B/s outside 0…50 GB/s")
            }
        }
        if let network = snapshot.network {
            for rate in [network.downloadBytesPerSecond, network.uploadBytesPerSecond].compactMap({ $0 })
            where !rate.isFinite || rate < 0 || rate > fastestNetwork {
                flag(.network, "network rate \(rate) B/s outside 0…100 Gbit/s")
            }
        }
        if let battery = snapshot.battery {
            if !(0...100).contains(battery.charge) { flag(.power, "charge \(battery.charge) % outside 0…100") }
            if let health = battery.healthPercent, !(1...150).contains(health) {
                flag(.power, "battery health \(health) % outside 1…150")
            }
            if let watts = battery.powerWatts, !watts.isFinite || abs(watts) > 500 {
                flag(.power, "battery power \(watts) W outside ±500")
            }
        }
        if let thermal = snapshot.thermal {
            let readings = [thermal.performanceCores, thermal.efficiencyCores, thermal.gpu, thermal.ssd, thermal.die]
            if readings.compactMap({ $0 }).contains(where: { !ThermalMath.plausible.contains($0) }) {
                flag(.thermal, "a temperature outside 10…125 °C")
            }
            if thermal.fans.contains(where: { !$0.rpm.isFinite || $0.rpm < 0 || $0.rpm > 15000 }) {
                flag(.thermal, "a fan speed outside 0…15000 rpm")
            }
        }
        if let gpu = snapshot.gpu, !share(gpu.utilization) {
            flag(.gpu, "GPU load \(gpu.utilization) outside 0…1")
        }
        return found
    }
}
