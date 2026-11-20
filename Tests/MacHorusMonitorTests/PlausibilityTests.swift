// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct PlausibilityTests {
    private let gib: UInt64 = 1 << 30

    private func snapshot(
        cpu: Double? = 0.3, charge: Int? = 80, free: UInt64 = 100, temperature: Double? = 50, gpu: Double? = 0.1
    ) -> MonitorSnapshot {
        MonitorSnapshot(
            date: Date(),
            cpu: cpu.map { CPUSnapshot(total: CPULoad(user: $0, system: 0), cores: [], coreKinds: []) },
            memory: nil,
            disk: DiskSnapshot(
                totalBytes: 500 * gib, availableBytes: free * gib, readBytesPerSecond: 0, writeBytesPerSecond: 0,
                totalReadBytes: 0, totalWrittenBytes: 0),
            network: nil,
            battery: charge.map {
                BatterySnapshot(
                    charge: $0, isCharging: false, isOnExternalPower: false, minutesRemaining: nil, cycleCount: 300,
                    healthPercent: 90, powerWatts: 8, adapterWatts: nil)
            },
            thermal: ThermalSnapshot(
                performanceCores: temperature, efficiencyCores: nil, gpu: nil, battery: nil, ssd: nil, fans: [],
                pressure: .nominal, hasSensors: true),
            gpu: gpu.map { GPUSnapshot(utilization: $0, model: nil, coreCount: nil, memoryInUse: nil) },
            processes: nil)
    }

    @Test func normalValuesPass() {
        #expect(Plausibility.check(snapshot()).isEmpty)
        #expect(Plausibility.check(snapshot(cpu: 1, charge: 100, free: 500, gpu: 1)).isEmpty)
    }

    @Test func impossibleValuesAreNamedByMetric() {
        let found = Plausibility.check(snapshot(cpu: 3, charge: 140, free: 900, temperature: 400, gpu: -2))
        #expect(Set(found.map(\.metric)) == [.cpu, .power, .disk, .thermal, .gpu])
        #expect(found.allSatisfy { !$0.text.isEmpty })
        #expect(Plausibility.check(snapshot(cpu: .nan)).map(\.metric) == [.cpu])
    }
}
