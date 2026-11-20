// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// Resource use of the MacHorus process itself.
public struct ResourceUsage: Equatable, Sendable {
    /// Share of one CPU core since the previous sample, in percent; nil on the first sample.
    public let cpuPercent: Double?
    /// Physical memory footprint as shown by Activity Monitor ("Memory").
    public let footprintBytes: UInt64
}

/// Measures the app's own CPU and memory use with two cheap syscalls, no
/// subprocesses. Call `sample()` only while the value is visible.
public struct SelfUsageSampler: Sendable {
    private var previous: (cpu: TimeInterval, wall: TimeInterval)?

    public init() {}

    public mutating func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ResourceUsage? {
        guard let footprint = Self.footprint() else { return nil }
        let cpu = Self.cpuTime()
        var percent: Double?
        if let previous, now > previous.wall {
            percent = max(0, (cpu - previous.cpu) / (now - previous.wall) * 100)
        }
        previous = (cpu, now)
        return ResourceUsage(cpuPercent: percent, footprintBytes: footprint)
    }

    static func cpuTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
