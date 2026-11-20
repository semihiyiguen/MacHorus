// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct DiagnosisTests {
    private func facts(anomalies: [(date: Date, anomaly: Anomaly)] = []) -> DiagnosisFacts {
        DiagnosisFacts(
            app: "1.0.23 (74)",
            mac: MacIdentity(
                computerName: "Private Name", chip: "Apple M1", model: "MacBookPro17,1", memoryBytes: 16 << 30,
                systemVersion: "27.0.1"),
            architecture: "arm64",
            capabilities: HardwareCapabilities(
                temperatureGroups: [], fanCount: 0, hasGPUStatistics: false, hasBattery: true),
            allowedPrivateAPIs: ["HIDSensors"], enabledMetrics: [.cpu, .power],
            cpu: CPUSnapshot(total: CPULoad(user: 0.2, system: 0.05), cores: [], coreKinds: []), memory: nil,
            disk: nil, network: nil, battery: nil, thermal: nil, gpu: nil, anomalies: anomalies,
            features: ["monitor.system"], schema: 12, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func itSaysWhatThisMacCannotMeasure() {
        let text = Diagnosis.text(facts())
        #expect(text.hasPrefix("--- MacHorus diagnosis (1.0.23 (74)) ---"))
        #expect(text.contains("MacBookPro17,1 · arm64"))
        #expect(text.contains("no sensors found"))
        #expect(text.contains("no GPU statistics"))
        #expect(text.contains("CPU 25 %"))
        #expect(text.contains("Implausible readings: none"))
        #expect(text.contains("disk free none"))
        // Never the computer name (it often carries a person's name).
        #expect(!text.contains("Private Name"))
    }

    @Test func itListsImplausibleReadings() {
        let text = Diagnosis.text(
            facts(anomalies: [
                (Date(timeIntervalSince1970: 1_800_000_000), Anomaly(metric: .power, text: "charge 140 %"))
            ]))
        #expect(text.contains("power: charge 140 %"))
    }

    @Test func diskInDecimalGBAndAnIdleGPUIsNamed() {
        var facts = facts()
        facts.capabilities = HardwareCapabilities(
            temperatureGroups: [.gpu, .performanceCores], fanCount: 1, hasGPUStatistics: true, hasBattery: true)
        facts.disk = DiskSnapshot(
            totalBytes: 994_660_000_000, availableBytes: 598_870_000_000, readBytesPerSecond: 0,
            writeBytesPerSecond: 0, totalReadBytes: 0, totalWrittenBytes: 0)
        facts.thermal = ThermalSnapshot(
            performanceCores: 64, efficiencyCores: nil, gpu: nil, battery: nil, ssd: nil, fans: [], pressure: .nominal,
            hasSensors: true)
        let text = Diagnosis.text(facts)
        #expect(text.contains("disk free 598.9 GB of 994.7 GB"))
        #expect(text.contains("GPU idle (sensors report the powered-down 30 °C)"))
    }
}
