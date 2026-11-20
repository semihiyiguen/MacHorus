// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct RingBufferTests {
    @Test func keepsTheNewestValuesInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.last == 5)
        #expect(buffer.count == 3)
    }

    @Test func behavesBeforeItIsFull() {
        var buffer = RingBuffer<Int>(capacity: 4)
        buffer.append(7)
        buffer.append(8)
        #expect(buffer.elements == [7, 8])
        #expect(buffer.last == 8)
        buffer.removeAll()
        #expect(buffer.isEmpty && buffer.last == nil)
    }
}

@Suite struct CPULoadTests {
    @Test func computesBusyShareFromTicks() {
        let old = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let new = CPUTicks(user: 160, system: 70, idle: 1_000, nice: 20)
        // Δ user+nice 80, system 20, idle 150 → busy 100 of 250.
        let load = CPULoad.between(old, new)
        #expect(abs(load.user - 0.32) < 1e-9)
        #expect(abs(load.system - 0.08) < 1e-9)
        #expect(abs(load.total - 0.4) < 1e-9)
    }

    @Test func treatsCountersGoingBackwardsAsNoData() {
        let old = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let reset = CPUTicks(user: 10, system: 5, idle: 900, nice: 0)
        #expect(CPULoad.between(old, reset) == .zero)
        #expect(CPULoad.between(old, old) == .zero)
    }

    @Test func averagesPerCoreKind() {
        let snapshot = CPUSnapshot(
            total: .zero,
            cores: [CPULoad(user: 0.2, system: 0), CPULoad(user: 0.4, system: 0), CPULoad(user: 1, system: 0)],
            coreKinds: [.efficiency, .efficiency, .performance])
        #expect(abs((snapshot.average(of: .efficiency) ?? -1) - 0.3) < 1e-9)
        #expect(snapshot.average(of: .performance) == 1)
        #expect(snapshot.average(of: .unknown) == nil)
    }
}

@Suite struct MemoryFormulaTests {
    @Test func followsActivityMonitorFormulas() {
        let pages = VMPageCounts(
            internalPages: 1_000, purgeablePages: 100, externalPages: 400, wiredPages: 300, compressorPages: 200)
        let memory = MemorySnapshot(
            pages: pages, pageSize: 16_384, physical: 16_384 * 4_096, swapUsed: 0, swapTotal: 0, pressure: .normal)
        #expect(memory.app == 900 * 16_384)
        #expect(memory.wired == 300 * 16_384)
        #expect(memory.compressed == 200 * 16_384)
        #expect(memory.cachedFiles == 500 * 16_384)
        #expect(memory.used == 1_400 * 16_384)
        #expect(abs(memory.usedFraction - 1_400.0 / 4_096) < 1e-9)
    }

    @Test func neverUnderflowsWhenPurgeableExceedsInternal() {
        let pages = VMPageCounts(
            internalPages: 10, purgeablePages: 50, externalPages: 0, wiredPages: 0, compressorPages: 0)
        let memory = MemorySnapshot(
            pages: pages, pageSize: 16_384, physical: 1, swapUsed: 0, swapTotal: 0, pressure: .normal)
        #expect(memory.app == 0)
    }
}

/// Live readings, checked against independent sources on this Mac.
@Suite struct LiveSamplerTests {
    @Test func topologyMatchesKernelCounts() {
        let kinds = CoreTopology.kinds()
        var ncpu: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        #expect(kinds.count == Int(ncpu))
        if !kinds.contains(.unknown) {
            #expect(
                kinds.filter { $0 == .performance }.count
                    == Int(sysctlValue("hw.perflevel0.logicalcpu", as: Int32.self) ?? -1))
        }
    }

    @Test func cpuSamplerReportsEveryCoreInRange() throws {
        let sampler = CPUSampler()
        #expect(sampler.sample() == nil, "First call only records the baseline")
        Thread.sleep(forTimeInterval: 0.2)
        let snapshot = try #require(sampler.sample())
        #expect(snapshot.cores.count == sampler.coreKinds.count)
        for load in snapshot.cores + [snapshot.total] {
            #expect((0...1).contains(load.total))
        }
    }

    @Test func memoryMatchesSysctlAndPhysicalLimits() throws {
        let memory = try #require(MemorySampler().sample())
        #expect(memory.physical == sysctlValue("hw.memsize", as: UInt64.self))
        #expect(memory.used > 0 && memory.used <= memory.physical)
        #expect(memory.wired > 0)
        let swap = try #require(sysctlValue("vm.swapusage", as: xsw_usage.self))
        // Swap can move between the two reads; allow 64 MB.
        let difference = Int64(memory.swapUsed) - Int64(swap.xsu_used)
        #expect(abs(difference) <= 64 * 1_048_576)
    }

    @Test func engineDeliversSnapshotsAndStops() async throws {
        let engine = MonitorEngine()
        let received = Received()
        await engine.start(metrics: [.cpu, .memory], interval: .milliseconds(200)) { snapshot in
            received.snapshots.append(snapshot)
        }
        try await Task.sleep(for: .milliseconds(1_200))
        await engine.stop()
        let count = await received.count
        #expect(count >= 2)
        #expect(await received.snapshots.first?.cpu != nil)
        #expect(await received.snapshots.first?.memory != nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await received.count == count, "No snapshots after stop")
        #expect(await engine.isRunning == false)
    }

    @Test func engineReadsProcessesRightAwayThenEveryOtherRound() async throws {
        let engine = MonitorEngine()
        let received = Received()
        await engine.start(metrics: [.processes], interval: .milliseconds(150)) { snapshot in
            received.snapshots.append(snapshot)
        }
        // Wait for rounds, not for a fixed time: CI runners can be slow.
        for _ in 0..<100 where await received.count < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        await engine.stop()
        let pattern = await received.snapshots.prefix(4).map { $0.processes != nil }
        // Delivered rounds 1-4: the list is there when the panel opens.
        #expect(pattern == [true, true, false, true])
    }

    @Test func cadenceReadsEverythingOnceBeforeThinningOut() {
        let rounds = (0..<6).map(RoundCadence.init(round:))
        #expect(rounds.map(\.readsLevels) == [false, true, true, true, true, true])
        #expect(rounds.map(\.readsSlowLevels) == [false, true, true, false, true, false])
        #expect(rounds.map(\.readsProcesses) == [true, true, true, false, true, false])
    }
}

@MainActor
private final class Received {
    var snapshots: [MonitorSnapshot] = []
    var count: Int { snapshots.count }
}
