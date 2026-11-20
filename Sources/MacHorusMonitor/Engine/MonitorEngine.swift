// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore

public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case power
    case thermal
    case gpu
    case processes
}

/// One sampling round; metrics that are switched off stay nil.
public struct MonitorSnapshot: Sendable {
    public let date: Date
    public let cpu: CPUSnapshot?
    public let memory: MemorySnapshot?
    public let disk: DiskSnapshot?
    public let network: NetworkSnapshot?
    public let battery: BatterySnapshot?
    public let thermal: ThermalSnapshot?
    public let gpu: GPUSnapshot?
    public let processes: ProcessesSnapshot?
}

/// Samples on its own executor and only while someone asks for data.
/// `start` and `stop` are cheap; when stopped nothing runs at all.
public actor MonitorEngine {
    private var cpu: CPUSampler?
    private var memory: MemorySampler?
    private var disk: DiskSampler?
    private var network: NetworkSampler?
    private var power: PowerSampler?
    private var thermal: ThermalSampler?
    private var gpu: GPUSampler?
    private var processes: ProcessSampler?
    /// Counts rounds; the process list is read every second round only.
    private var round = 0
    private var loop: Task<Void, Never>?
    private let privateAPIs: Set<PrivateAPI>

    /// `privateAPIs` are the private interfaces the policy allows (its kill
    /// switch, `DisabledPrivateAPIs`).
    public init(privateAPIs: Set<PrivateAPI> = Set(PrivateAPI.allCases)) {
        self.privateAPIs = privateAPIs
    }

    public var isRunning: Bool { loop != nil }

    /// Starts (or reconfigures) sampling. `deliver` runs on the main actor
    /// after every round; the first round follows immediately.
    public func start(
        metrics: Set<Metric>, interval: Duration,
        deliver: @escaping @MainActor @Sendable (MonitorSnapshot) -> Void
    ) async {
        await finishLoop()
        round = 0
        cpu = metrics.contains(.cpu) ? (cpu ?? CPUSampler()) : nil
        memory = metrics.contains(.memory) ? (memory ?? MemorySampler()) : nil
        disk = metrics.contains(.disk) ? (disk ?? DiskSampler()) : nil
        network =
            metrics.contains(.network)
            ? (network ?? NetworkSampler(allowConnectionStatistics: privateAPIs.contains(.networkStatistics))) : nil
        power = metrics.contains(.power) ? (power ?? PowerSampler()) : nil
        thermal =
            metrics.contains(.thermal)
            ? (thermal
                ?? ThermalSampler(
                    allowHIDSensors: privateAPIs.contains(.hidSensors), allowSMC: privateAPIs.contains(.smc))) : nil
        gpu = metrics.contains(.gpu) ? (gpu ?? GPUSampler()) : nil
        processes =
            metrics.contains(.processes)
            ? (processes ?? ProcessSampler(allowResponsibility: privateAPIs.contains(.processResponsibility))) : nil
        guard !metrics.isEmpty else {
            loop = nil
            return
        }
        loop = Task { [weak self] in
            // Rates need two readings: take the baselines first, the first
            // snapshot then shows real values instead of dashes or zeros.
            _ = await self?.sampleRound()
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled {
                guard let snapshot = await self?.sampleRound(), !Task.isCancelled else { return }
                await deliver(snapshot)
                // Tolerance lets macOS coalesce wake-ups with other timers.
                try? await Task.sleep(for: interval, tolerance: interval / 5)
            }
        }
    }

    /// Returns once no round is running any more, so no snapshot arrives
    /// after `stop()` has returned.
    public func stop() async {
        await finishLoop()
        // Release kernel handles; the next start takes a fresh baseline.
        // The thermal sampler stays: its HID client and SMC connection do
        // no work while unused, and opening them again cost 4.5 ms per
        // panel opening. NetworkStatistics must go: it keeps receiving
        // connection events.
        cpu = nil
        memory = nil
        disk = nil
        network = nil
        power = nil
        gpu = nil
        processes = nil
    }

    private func finishLoop() async {
        guard let running = loop else { return }
        loop = nil
        running.cancel()
        await running.value
    }

    func sampleRound() async -> MonitorSnapshot {
        let cadence = RoundCadence(round: round)
        round &+= 1
        // The connection query takes a few ms on its own queue; the other
        // metrics are read right after it, so all values share one moment.
        let connectionTotals = await network?.connectionStatistics?.refresh()
        return MonitorSnapshot(
            date: Date(), cpu: cpu?.sample(), memory: cadence.readsLevels ? memory?.sample() : nil,
            disk: disk?.sample(), network: network?.sample(connectionTotals: connectionTotals),
            battery: cadence.readsSlowLevels ? power?.sample() : nil,
            thermal: cadence.readsSlowLevels ? thermal?.sample() : nil,
            gpu: cadence.readsLevels ? gpu?.sample() : nil,
            processes: cadence.readsProcesses ? processes?.sample() : nil)
    }
}

/// Which samplers a round reads. Nil in a snapshot keeps the last value on
/// screen. Round 0 is the baseline and is not delivered.
struct RoundCadence {
    let round: Int

    /// Levels (memory, GPU) need no baseline.
    var readsLevels: Bool { round > 0 }

    /// Battery and temperatures change slowly (the HID sensors themselves
    /// refresh only about every 4 s): every other round, starting with the
    /// first delivered one.
    var readsSlowLevels: Bool { round == 1 || (round > 1 && round.isMultiple(of: 2)) }

    /// The process list is a rate too: baseline in round 0, then like the
    /// slow levels.
    var readsProcesses: Bool { round == 0 || readsSlowLevels }
}
