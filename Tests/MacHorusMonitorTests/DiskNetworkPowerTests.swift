// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import Testing
import os

@testable import MacHorusMonitor

@Suite struct DiskMathTests {
    @Test func ratesAreBytesPerSecond() {
        let old = DiskCounters(read: 1_000, written: 500, uptime: 10)
        let new = DiskCounters(read: 5_000, written: 2_500, uptime: 12)
        let rates = DiskCounters.rates(old, new)
        #expect(rates.read == 2_000)
        #expect(rates.write == 1_000)
    }

    @Test func countersGoingBackwardsGiveZeroNotASpike() {
        let old = DiskCounters(read: 5_000, written: 5_000, uptime: 10)
        let new = DiskCounters(read: 100, written: 6_000, uptime: 12)
        #expect(DiskCounters.rates(old, new) == (0, 0))
        #expect(DiskCounters.rates(old, old) == (0, 0))
    }

    @Test func liveCapacityMatchesStatfs() throws {
        let disk = try #require(DiskSampler().sample())
        var stats = statfs()
        try #require(statfs("/", &stats) == 0)
        #expect(disk.totalBytes == UInt64(stats.f_blocks) * UInt64(stats.f_bsize))
        // Free space can change between the two calls; allow 64 MB.
        let free = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
        #expect(abs(Int64(disk.availableBytes) - Int64(free)) <= 64 * 1_048_576)
        #expect(disk.totalReadBytes > 0, "The startup disk has been read since boot")
    }
}

@Suite struct NetworkMathTests {
    @Test func blindInboundCounterIsDetected() {
        #expect(InboundCounting.isBlind(sentPackets: 500, receivedPackets: 0))
        #expect(!InboundCounting.isBlind(sentPackets: 500, receivedPackets: 3))
        // Too little traffic to judge.
        #expect(!InboundCounting.isBlind(sentPackets: 5, receivedPackets: 0))
    }

    @Test func countsOnlyRealInterfaces() {
        #expect(InterfaceFilter.counts("en0"))
        #expect(InterfaceFilter.counts("pdp_ip0"))
        for name in ["lo0", "utun5", "awdl0", "llw0", "bridge0", "anpi0", "gif0"] {
            #expect(!InterfaceFilter.counts(name), "\(name) would double-count or is not traffic")
        }
    }

    @Test func silentConnectionStatisticsAreDetected() {
        #expect(ConnectionCounting.isBroken(connectionBytes: 0, interfaceBytesSent: 2_000_000))
        #expect(!ConnectionCounting.isBroken(connectionBytes: 1, interfaceBytesSent: 2_000_000))
        // An idle Mac: too little traffic to judge.
        #expect(!ConnectionCounting.isBroken(connectionBytes: 0, interfaceBytesSent: 10_000))
    }

    @Test func ratesFromConnectionTotals() throws {
        let sampler = NetworkSampler(allowConnectionStatistics: true)
        try #require(sampler.connectionStatistics != nil, "NetworkStatistics is part of every supported macOS")
        typealias Totals = NetworkStatisticsAdapter.Totals
        let first = try #require(sampler.sample(connectionTotals: Totals(received: 1_000, sent: 100, uptime: 10)))
        #expect(first.measurement == .connections)
        #expect(first.downloadBytesPerSecond == nil, "One reading is not a rate")
        let second = try #require(sampler.sample(connectionTotals: Totals(received: 5_000, sent: 700, uptime: 12)))
        #expect(second.downloadBytesPerSecond == 2_000)
        #expect(second.uploadBytesPerSecond == 300)
        // A timed-out query gives no rate instead of a guess.
        let third = try #require(sampler.sample(connectionTotals: nil))
        #expect(third.downloadBytesPerSecond == nil)
        #expect(third.measurement == .connections)
    }

    @Test func killSwitchFallsBackToInterfaceCounters() throws {
        let sampler = NetworkSampler(allowConnectionStatistics: false)
        #expect(sampler.connectionStatistics == nil)
        let snapshot = try #require(sampler.sample())
        #expect(snapshot.measurement != .connections)
        #expect(snapshot.connectionTotals == nil)
    }

    @Test func liveCountersAreMonotonic() throws {
        let first = try #require(NetworkSampler.interfaceCounters())
        Thread.sleep(forTimeInterval: 0.2)
        let second = try #require(NetworkSampler.interfaceCounters())
        for interface in second {
            guard let earlier = first.first(where: { $0.name == interface.name }) else { continue }
            #expect(interface.sentBytes >= earlier.sentBytes)
            #expect(interface.receivedBytes >= earlier.receivedBytes)
        }
        #expect(second.contains { $0.name == "lo0" }, "Loopback always exists")
    }

    @Test func namesComeFromTheLinkAddressLikeIfIndexToName() throws {
        // Same names as the system's own lookup, without its cost.
        let counters = try #require(NetworkSampler.interfaceCounters())
        for interface in counters {
            let index = if_nametoindex(interface.name)
            #expect(index != 0, "\(interface.name) is a real interface name")
        }
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        try #require(getifaddrs(&list) == 0)
        defer { freeifaddrs(list) }
        for entry in sequence(first: list!, next: { $0.pointee.ifa_next }) {
            names.insert(String(cString: entry.pointee.ifa_name))
        }
        #expect(Set(counters.map(\.name)) == names)
    }

    @Test func linkNameParsesASockaddrDL() {
        // sdl_len 20, AF_LINK, index 12, type 6, nlen 3, alen 6, slen 0, "en0", MAC.
        let bytes: [UInt8] =
            [20, UInt8(AF_LINK), 12, 0, 6, 3, 6, 0] + Array("en0".utf8) + [1, 2, 3, 4, 5, 6] + [0, 0, 0]
        bytes.withUnsafeBytes { raw in
            #expect(NetworkSampler.linkName(raw, at: 0, end: raw.count, addresses: RTA_IFP) == "en0")
            #expect(NetworkSampler.linkName(raw, at: 0, end: raw.count, addresses: 0) == nil, "No link address flagged")
            #expect(NetworkSampler.linkName(raw, at: 0, end: 10, addresses: RTA_IFP) == nil, "Name past the message")
        }
    }
}

/// Talks to the real NetworkStatistics framework. Serialized, so the
/// descriptor count is not disturbed by a parallel adapter.
@Suite(.serialized) struct NetworkStatisticsAdapterTests {
    @Test func totalsGrowAndCarryTheTime() throws {
        let adapter = try #require(NetworkStatisticsAdapter())
        let first = try #require(adapter.refreshWaiting())
        let second = try #require(adapter.refreshWaiting())
        #expect(second.received >= first.received)
        #expect(second.sent >= first.sent)
        #expect(second.uptime > first.uptime)
    }

    @Test func completionRunsExactlyOnce() async throws {
        let adapter = try #require(NetworkStatisticsAdapter())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // Timeout 0 races the answer: whichever comes first wins, never both.
        for _ in 0..<20 {
            adapter.query(timeout: 0) { _ in calls.withLock { $0 += 1 } }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.withLock { $0 } == 20)
    }

    @Test func createAndDestroyRepeatedly() async throws {
        // Opening and closing the panel creates and releases an adapter;
        // each one holds a kernel control socket that must be closed again.
        func openDescriptors() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let before = try openDescriptors()
        for _ in 0..<25 {
            let adapter = try #require(NetworkStatisticsAdapter())
            _ = await adapter.refresh()
        }
        #expect(try openDescriptors() <= before + 2, "A leaked socket per adapter would add 25")
    }
}

@Suite struct BatteryMathTests {
    @Test func healthIsFullChargeOverDesign() {
        // Measured on a test Mac while System Settings showed 82 %:
        // 81.34 % and 81.80 % both display as 82 %, so macOS rounds up.
        #expect(BatteryMath.healthPercent(fullCharge: 4_151, design: 5_103) == 82)
        #expect(BatteryMath.healthPercent(fullCharge: 4_174, design: 5_103) == 82)
        #expect(BatteryMath.healthPercent(fullCharge: 5_103, design: 5_103) == 100)
        #expect(BatteryMath.healthPercent(fullCharge: 0, design: 5_103) == nil)
        #expect(BatteryMath.healthPercent(fullCharge: 4_000, design: 0) == nil)
    }

    @Test func wattsKeepTheSignOfTheCurrent() {
        #expect(abs(BatteryMath.watts(millivolts: 12_098, milliamperes: -346) - -4.186) < 0.001)
        #expect(BatteryMath.watts(millivolts: 12_000, milliamperes: 2_000) == 24)
    }
}
