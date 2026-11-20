// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Testing

@testable import MacHorusMonitor

@Suite struct StatusSummaryTests {
    private let gib: UInt64 = 1 << 30
    private let fine = RestartAdvice(level: .none, reasons: [])

    private func disk(free: UInt64) -> DiskSnapshot {
        DiskSnapshot(
            totalBytes: 1_000 * gib, availableBytes: free * gib, readBytesPerSecond: 0, writeBytesPerSecond: 0,
            totalReadBytes: 0, totalWrittenBytes: 0)
    }

    private func thermal(_ pressure: ThermalPressure) -> ThermalSnapshot {
        ThermalSnapshot(
            performanceCores: 50, efficiencyCores: 45, gpu: nil, battery: 30, ssd: 35, fans: [], pressure: pressure,
            hasSensors: true)
    }

    private func items(
        restart: RestartAdvice? = nil, disk: DiskSnapshot? = nil, thermal: ThermalSnapshot? = nil,
        alerts: Set<AlertKind> = [], updates: SoftwareUpdates? = nil
    ) -> [StatusItem] {
        StatusSummary.items(
            restart: restart ?? fine, disk: disk, battery: nil, thermal: thermal, alerts: alerts, updates: updates)
    }

    @Test func aHealthyMacHasNothingToSay() {
        #expect(items(disk: disk(free: 600), thermal: thermal(.nominal)).isEmpty)
    }

    @Test func worstFirstAndRedForWhatCannotWait() {
        let restart = RestartAdvisor.advise(uptime: 9 * RestartAdvisor.day, memory: nil)
        let updates = SoftwareUpdates(
            munkiItems: [.init(name: "Tool", version: "2", restart: .required, isRemoval: false)], problemItems: [],
            lastCheck: nil, appleUpdates: [])
        let list = items(restart: restart, disk: disk(free: 40), alerts: [.cpuBusy, .hot], updates: updates)
        #expect(list.first?.kind == .alert(.hot))
        #expect(list.first?.severity == .critical)
        #expect(list.filter { $0.severity == .critical }.count == 2, "hot, and 4 % free disk")
        #expect(list.contains { $0.kind == .updates(count: 1, needsRestart: true) && $0.severity == .info })
        #expect(list.last?.kind == .updates(count: 1, needsRestart: true), "info comes last")
        #expect(list.contains { $0.kind == .restart(.uptime(9 * RestartAdvisor.day), .low) && $0.severity == .warning })
        // Equal severity keeps the order: restart reason before the busy CPU.
        let warnings = list.filter { $0.severity == .warning }.map(\.kind)
        #expect(warnings.first == .restart(.uptime(9 * RestartAdvisor.day), .low))
    }

    @Test func infoCanBeHiddenUntilItChanges() {
        let battery = BatterySnapshot.sample(health: 78)
        let worn = StatusSummary.items(
            restart: fine, disk: nil, battery: battery, thermal: nil, alerts: [], updates: nil)
        #expect(worn.map(\.severity) == [.info])
        let key = try! #require(worn.first?.dismissKey)
        #expect(
            StatusSummary.items(
                restart: fine, disk: nil, battery: battery, thermal: nil, alerts: [], updates: nil, dismissed: [key]
            ).isEmpty)
        // Five points further worn: shown again.
        #expect(
            StatusSummary.items(
                restart: fine, disk: nil, battery: .sample(health: 74), thermal: nil, alerts: [], updates: nil,
                dismissed: [key]
            ).count == 1)
        // Warnings and critical points cannot be hidden.
        #expect(items(disk: disk(free: 40)).first?.dismissKey == nil)
    }

    @Test func nothingIsSaidTwice() {
        // Disk alert and disk hint share the 10 % rule; heat alert and throttling too.
        let list = items(disk: disk(free: 80), thermal: thermal(.serious), alerts: [.diskFull, .hot])
        #expect(list.map(\.kind) == [.alert(.hot), .alert(.diskFull)])
        // Critical memory pressure as a restart reason replaces the alert.
        let pages = VMPageCounts(
            internalPages: 1_000, purgeablePages: 0, externalPages: 1_000, wiredPages: 500, compressorPages: 500)
        let memory = MemorySnapshot(
            pages: pages, pageSize: 16_384, physical: 16 * gib, swapUsed: 0, swapTotal: 0, pressure: .critical)
        let restart = RestartAdvisor.advise(uptime: nil, memory: memory)
        let pressure = items(restart: restart, alerts: [.memoryPressure])
        #expect(pressure.map(\.kind) == [.restart(.memoryPressure(.critical), .high)])
        #expect(pressure.first?.severity == .critical)
    }
}

extension BatterySnapshot {
    fileprivate static func sample(health: Int) -> BatterySnapshot {
        BatterySnapshot(
            charge: 50, isCharging: false, isOnExternalPower: false, minutesRemaining: nil, cycleCount: 400,
            healthPercent: health, powerWatts: nil, adapterWatts: nil)
    }
}
