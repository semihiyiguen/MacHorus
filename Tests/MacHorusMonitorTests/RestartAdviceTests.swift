// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct RestartAdviceTests {
    private let gib: UInt64 = 1 << 30

    private func memory(swap: UInt64, pressure: MemoryPressure = .normal) -> MemorySnapshot {
        let pages = VMPageCounts(
            internalPages: 1_000, purgeablePages: 0, externalPages: 1_000, wiredPages: 500, compressorPages: 500)
        return MemorySnapshot(
            pages: pages, pageSize: 16_384, physical: 16 * gib, swapUsed: swap, swapTotal: 20 * gib, pressure: pressure)
    }

    @Test func freshMacNeedsNothing() {
        let advice = RestartAdvisor.advise(uptime: 2 * RestartAdvisor.day, memory: memory(swap: gib))
        #expect(advice.level == .none)
        #expect(advice.reasons.isEmpty)
    }

    @Test func uptimeThresholds() {
        let levels = [6.9, 7, 14, 30].map { days in
            RestartAdvisor.advise(uptime: days * RestartAdvisor.day, memory: nil).level
        }
        #expect(levels == [.none, .low, .medium, .high])
    }

    @Test func swapShareOfPhysicalMemory() {
        let levels = [3, 4, 8, 16].map { swap in
            RestartAdvisor.advise(uptime: nil, memory: memory(swap: UInt64(swap) * gib)).level
        }
        #expect(levels == [.none, .low, .medium, .high])
    }

    @Test func strongestReasonWinsAndComesFirst() {
        let advice = RestartAdvisor.advise(
            uptime: 8 * RestartAdvisor.day, memory: memory(swap: 9 * gib, pressure: .critical))
        #expect(advice.level == .high)
        #expect(advice.reasons.map(\.level) == [.high, .medium, .low])
        #expect(advice.reasons.first?.reason == .memoryPressure(.critical))
    }

    @Test func bootDateMatchesSysctl() throws {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        try #require(sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0)
        let date = try #require(SystemUptime.bootDate)
        #expect(abs(date.timeIntervalSince1970 - TimeInterval(boot.tv_sec)) < 1)
        #expect((SystemUptime.uptime() ?? 0) > 0)
    }
}

@Suite struct SystemHintTests {
    private let gib: UInt64 = 1 << 30
    private let fine = RestartAdvice(level: .none, reasons: [])

    private func disk(free: UInt64) -> DiskSnapshot {
        DiskSnapshot(
            totalBytes: 1_000 * gib, availableBytes: free * gib, readBytesPerSecond: 0, writeBytesPerSecond: 0,
            totalReadBytes: 0, totalWrittenBytes: 0)
    }

    private func battery(health: Int) -> BatterySnapshot {
        BatterySnapshot(
            charge: 50, isCharging: false, isOnExternalPower: false, minutesRemaining: nil, cycleCount: 400,
            healthPercent: health, powerWatts: nil, adapterWatts: nil)
    }

    private func thermal(_ pressure: ThermalPressure) -> ThermalSnapshot {
        ThermalSnapshot(
            performanceCores: 50, efficiencyCores: 45, gpu: nil, battery: 30, ssd: 35, fans: [], pressure: pressure,
            hasSensors: true)
    }

    @Test func healthyMacHasNoHints() {
        let hints = SystemHint.hints(
            restart: fine, disk: disk(free: 600), battery: battery(health: 82), thermal: thermal(.fair))
        #expect(hints.isEmpty)
    }

    @Test func eachRuleAtItsThreshold() {
        #expect(SystemHint.hints(restart: fine, disk: disk(free: 99), battery: nil, thermal: nil).count == 1)
        #expect(SystemHint.hints(restart: fine, disk: disk(free: 100), battery: nil, thermal: nil).isEmpty)
        #expect(
            SystemHint.hints(restart: fine, disk: nil, battery: battery(health: 79), thermal: nil) == [
                .batteryWorn(healthPercent: 79)
            ])
        #expect(SystemHint.hints(restart: fine, disk: nil, battery: battery(health: 80), thermal: nil).isEmpty)
        #expect(
            SystemHint.hints(restart: fine, disk: nil, battery: nil, thermal: thermal(.serious)) == [
                .thermalThrottling(.serious)
            ])
        let restart = RestartAdvisor.advise(uptime: 8 * RestartAdvisor.day, memory: nil)
        #expect(SystemHint.hints(restart: restart, disk: nil, battery: nil, thermal: nil) == [.restart(.low)])
    }

    @Test func identityReadsThisMac() throws {
        let mac = MacIdentity.current
        #expect(mac.chip?.hasPrefix("Apple") == true, "Apple Silicon only")
        #expect((mac.memoryBytes ?? 0) >= 8 * gib)
        #expect(mac.systemVersion.split(separator: ".").count >= 2)
        #expect(
            MacIdentity.version(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)) == "15.6.1")
        #expect(
            MacIdentity.version(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == "27.0")
    }
}
