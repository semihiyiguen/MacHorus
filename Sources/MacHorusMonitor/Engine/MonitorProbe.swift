// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore

/// Synchronous readings for verification (`MacHorus --print-monitor`), so the
/// values the panel shows can be compared with vm_stat, sysctl and top.
public enum MonitorProbe {
    /// Calls `handle` after every round, so a caller can react to the first
    /// reading (the network check starts its download then).
    public static func run(
        rounds: Int, interval: TimeInterval, privateAPIs: Set<PrivateAPI> = Set(PrivateAPI.allCases),
        _ handle: (MonitorSnapshot) -> Void
    ) {
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let disk = DiskSampler()
        // Fresh interface counters every round: the output is compared with netstat.
        let network = NetworkSampler(
            allowConnectionStatistics: privateAPIs.contains(.networkStatistics), interfaceRefreshEvery: 1)
        let power = PowerSampler()
        let thermal = ThermalSampler(
            allowHIDSensors: privateAPIs.contains(.hidSensors), allowSMC: privateAPIs.contains(.smc))
        let gpu = GPUSampler()
        let processes = ProcessSampler(allowResponsibility: privateAPIs.contains(.processResponsibility))
        _ = cpu.sample()
        _ = disk.sample()
        _ = processes.sample()
        _ = network.sample(connectionTotals: network.connectionStatistics?.refreshWaiting())
        for _ in 0..<max(1, rounds) {
            Thread.sleep(forTimeInterval: interval)
            let connectionTotals = network.connectionStatistics?.refreshWaiting()
            handle(
                MonitorSnapshot(
                    date: Date(), cpu: cpu.sample(), memory: memory.sample(), disk: disk.sample(),
                    network: network.sample(connectionTotals: connectionTotals), battery: power.sample(),
                    thermal: thermal.sample(), gpu: gpu.sample(), processes: processes.sample()))
        }
    }

    /// One line of `key=value` pairs per snapshot; byte values are exact.
    public static func line(_ snapshot: MonitorSnapshot) -> String {
        var fields = [String(format: "time=%.3f", snapshot.date.timeIntervalSince1970)]
        if let cpu = snapshot.cpu {
            fields.append(String(format: "cpu.total=%.4f", cpu.total.total))
            fields.append("cpu.cores=\(cpu.cores.count)")
            fields.append("cpu.performanceCores=\(cpu.coreKinds.filter { $0 == .performance }.count)")
            fields.append("cpu.efficiencyCores=\(cpu.coreKinds.filter { $0 == .efficiency }.count)")
        }
        if let memory = snapshot.memory {
            fields += [
                "mem.physical=\(memory.physical)", "mem.used=\(memory.used)", "mem.app=\(memory.app)",
                "mem.wired=\(memory.wired)", "mem.compressed=\(memory.compressed)",
                "mem.cached=\(memory.cachedFiles)", "mem.swapUsed=\(memory.swapUsed)",
                "mem.pressure=\(memory.pressure.rawValue)",
            ]
        }
        if let disk = snapshot.disk {
            fields += [
                "disk.total=\(disk.totalBytes)", "disk.available=\(disk.availableBytes)",
                "disk.readTotal=\(disk.totalReadBytes)", "disk.writtenTotal=\(disk.totalWrittenBytes)",
                String(format: "disk.readRate=%.0f", disk.readBytesPerSecond),
                String(format: "disk.writeRate=%.0f", disk.writeBytesPerSecond),
            ]
        }
        if let network = snapshot.network {
            fields.append("net.primary=\(network.primaryInterface ?? "-")")
            fields.append("net.ipv4=\(network.localIPv4 ?? "-")")
            let tunnels = network.vpnTunnels.map { "\($0.interface):\($0.ipv4)" }
            fields.append("net.vpn=\(tunnels.isEmpty ? "-" : tunnels.joined(separator: ","))")
            fields.append("net.measurement=\(network.measurement.rawValue)")
            fields.append("net.downRate=\(network.downloadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "-")")
            fields.append("net.upRate=\(network.uploadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "-")")
            if let totals = network.connectionTotals {
                fields.append("net.connections.rx=\(totals.received)")
                fields.append("net.connections.tx=\(totals.sent)")
            }
            for interface in network.interfaces {
                fields.append("net.\(interface.name).rx=\(interface.receivedBytes)")
                fields.append("net.\(interface.name).tx=\(interface.sentBytes)")
            }
        }
        if let thermal = snapshot.thermal {
            func celsius(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
            fields += [
                "thermal.sensors=\(thermal.hasSensors ? 1 : 0)",
                "thermal.performanceCores=\(celsius(thermal.performanceCores))",
                "thermal.efficiencyCores=\(celsius(thermal.efficiencyCores))",
                "thermal.gpu=\(celsius(thermal.gpu))", "thermal.battery=\(celsius(thermal.battery))",
                "thermal.ssd=\(celsius(thermal.ssd))", "thermal.pressure=\(thermal.pressure.rawValue)",
                "thermal.fans=\(thermal.fans.count)",
            ]
            for (index, fan) in thermal.fans.enumerated() {
                fields.append(String(format: "thermal.fan%d.rpm=%.0f", index, fan.rpm))
            }
        }
        if let gpu = snapshot.gpu {
            fields += [
                String(format: "gpu.utilization=%.4f", gpu.utilization),
                "gpu.cores=\(gpu.coreCount.map(String.init) ?? "-")",
                "gpu.memoryInUse=\(gpu.memoryInUse.map(String.init) ?? "-")",
            ]
        }
        if let processes = snapshot.processes {
            fields += [
                "proc.visible=\(processes.visibleCount)", "proc.hidden=\(processes.hiddenCount)",
                "proc.grouped=\(processes.rows.reduce(0) { $0 + $1.processCount })",
            ]
            for (index, row) in processes.topCPU.enumerated() {
                fields.append("proc.cpu\(index).pid=\(row.identity.pid)")
                fields.append(String(format: "proc.cpu%d.value=%.4f", index, row.cpu))
                fields.append("proc.cpu\(index).count=\(row.processCount)")
            }
            for (index, row) in processes.topMemory.enumerated() {
                fields.append("proc.mem\(index).pid=\(row.identity.pid)")
                fields.append("proc.mem\(index).bytes=\(row.memory)")
                fields.append("proc.mem\(index).count=\(row.processCount)")
            }
        }
        if let battery = snapshot.battery {
            fields += [
                "power.charge=\(battery.charge)", "power.charging=\(battery.isCharging ? 1 : 0)",
                "power.external=\(battery.isOnExternalPower ? 1 : 0)",
                "power.minutes=\(battery.minutesRemaining.map(String.init) ?? "-")",
                "power.cycles=\(battery.cycleCount.map(String.init) ?? "-")",
                "power.health=\(battery.healthPercent.map(String.init) ?? "-")",
                "power.watts=\(battery.powerWatts.map { String(format: "%.2f", $0) } ?? "-")",
            ]
        }
        return fields.joined(separator: " ")
    }

    /// Every temperature sensor and fan key with its current value, so a
    /// tester on another chip can show which sensors exist there
    /// (`MacHorus --print-sensors`). Names and numbers only.
    public static func sensorListing() -> [String] {
        var lines = (HIDTemperatureSensors(include: { _ in true })?.read() ?? [])
            .sorted { $0.name < $1.name }
            .map { String(format: "hid %@ = %.2f", $0.name, $0.celsius) }
        if let smc = SMCReader() {
            let fans = Int(smc.value("FNum") ?? 0)
            lines.append("smc FNum = \(fans)")
            for index in 0..<min(fans, 8) {
                for suffix in ["Ac", "Mn", "Mx", "Tg"] {
                    lines.append(
                        "smc F\(index)\(suffix) = \(smc.value("F\(index)\(suffix)").map { String(format: "%.0f", $0) } ?? "-")"
                    )
                }
            }
        }
        return lines
    }

    /// CPU time per call of every sampler (`MacHorus --benchmark-samplers`),
    /// so a cost claim is a measurement. Process CPU time, because the
    /// network query runs on its own queue.
    public static func benchmark(
        rounds: Int, only: String? = nil, privateAPIs: Set<PrivateAPI> = Set(PrivateAPI.allCases)
    ) -> [String] {
        func cpuTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
        func measure(_ name: String, _ body: () -> Void) -> String? {
            if let only, !name.hasPrefix(only) { return nil }
            body()  // warm-up: first reads open handles
            Thread.sleep(forTimeInterval: 0.05)
            var total: UInt64 = 0
            for _ in 0..<rounds {
                let start = cpuTime()
                body()
                total += cpuTime() - start
                Thread.sleep(forTimeInterval: 0.05)
            }
            return String(format: "%@ %.3f ms", name, Double(total) / Double(rounds) / 1_000_000)
        }
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let disk = DiskSampler()
        let network = NetworkSampler(allowConnectionStatistics: privateAPIs.contains(.networkStatistics))
        let power = PowerSampler()
        let thermal = ThermalSampler(
            allowHIDSensors: privateAPIs.contains(.hidSensors), allowSMC: privateAPIs.contains(.smc))
        let gpu = GPUSampler()
        let processes = ProcessSampler(allowResponsibility: privateAPIs.contains(.processResponsibility))
        return [
            measure("cpu") { _ = cpu.sample() },
            measure("memory") { _ = memory.sample() },
            measure("disk") { _ = disk.sample() },
            measure("network.connections") { _ = network.connectionStatistics?.refreshWaiting() },
            measure("network.interfaces") { _ = NetworkSampler.interfaceCounters() },
            measure("network.sample") { _ = network.sample() },
            measure("power") { _ = power.sample() },
            measure("thermal") { _ = thermal.sample() },
            measure("gpu") { _ = gpu.sample() },
            measure("processes") { _ = processes.sample() },
        ].compactMap { $0 }
    }
}
