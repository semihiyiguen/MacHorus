// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import Testing

@testable import MacHorusCore

/// Cross-checks SelfUsageSampler against the counters Activity Monitor uses.
@Suite struct SelfUsageAccuracyTests {
    /// Activity Monitor's "Memory" column is `ri_phys_footprint` from proc_pid_rusage.
    private func activityMonitorFootprint() throws -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        try #require(result == 0)
        return info.ri_phys_footprint
    }

    @Test func footprintMatchesActivityMonitorCounter() throws {
        // Tests run in parallel in this process and allocate in between
        // (under the sanitizers by several MB): bracket the reading with a
        // reference before and after instead of comparing two moments.
        let before = try activityMonitorFootprint()
        let measured = try #require(SelfUsageSampler.footprint())
        let after = try activityMonitorFootprint()
        let slack: UInt64 = 256 * 1_024
        #expect(
            measured + slack >= min(before, after) && measured <= max(before, after) + slack,
            "measured \(measured), reference \(before)…\(after)")
    }

    /// Activity Monitor's "CPU Time" is `ri_user_time + ri_system_time` from
    /// proc_pid_rusage, in Mach time units.
    private func activityMonitorCPUTime() throws -> TimeInterval {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        try #require(result == 0)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    @Test func cpuShareMatchesActivityMonitorCPUTime() throws {
        // How much CPU a busy loop gets depends on the machine's load and the
        // test's priority: at background priority on a loaded Mac it got only
        // 19-46 % instead of 100 %, so a fixed threshold failed although the
        // sampler was right. Other tests also run in parallel in this process.
        // The reference is therefore the process's CPU time over the same
        // interval, read with the Activity Monitor counter around each sample.
        var sampler = SelfUsageSampler()
        let first = ProcessInfo.processInfo.systemUptime
        let beforeFirst = try activityMonitorCPUTime()
        _ = sampler.sample(now: first)
        let afterFirst = try activityMonitorCPUTime()
        var accumulator = 0.0
        while ProcessInfo.processInfo.systemUptime - first < 0.3 { accumulator += sin(accumulator) + 1 }
        #expect(accumulator > 0)
        let second = ProcessInfo.processInfo.systemUptime
        let beforeSecond = try activityMonitorCPUTime()
        let cpu = try #require(sampler.sample(now: second)?.cpuPercent)
        let afterSecond = try activityMonitorCPUTime()
        let wall = second - first
        let low = (beforeSecond - afterFirst) / wall * 100
        let high = (afterSecond - beforeFirst) / wall * 100
        #expect(low > 0, "the busy loop ran")
        // getrusage counts whole microseconds; half a percentage point covers
        // that and the two counters being read a moment apart.
        #expect(cpu >= low - 0.5 && cpu <= high + 0.5, "measured \(cpu) %, reference \(low)…\(high) %")
    }
}
