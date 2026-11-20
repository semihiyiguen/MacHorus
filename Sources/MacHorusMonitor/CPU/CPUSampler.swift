// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// Kernel tick counters of one CPU (or all CPUs together).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    init(_ ticks: (UInt32, UInt32, UInt32, UInt32)) {
        self.init(
            user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }
}

/// Share of time a CPU was busy between two samples, 0…1.
public struct CPULoad: Equatable, Sendable {
    public let user: Double
    public let system: Double

    public var total: Double { user + system }

    public static let zero = CPULoad(user: 0, system: 0)

    /// Busy share from two tick readings. Counters that went backwards (e.g.
    /// after a CPU came back online) count as no data rather than a spike.
    public static func between(_ old: CPUTicks, _ new: CPUTicks) -> CPULoad {
        guard new.user >= old.user, new.system >= old.system, new.idle >= old.idle, new.nice >= old.nice
        else { return .zero }
        let user = Double(new.user - old.user + new.nice - old.nice)
        let system = Double(new.system - old.system)
        let idle = Double(new.idle - old.idle)
        let total = user + system + idle
        guard total > 0 else { return .zero }
        return CPULoad(user: user / total, system: system / total)
    }
}

public enum CoreKind: String, Sendable {
    case performance
    case efficiency
    case unknown
}

public struct CPUSnapshot: Equatable, Sendable {
    public let total: CPULoad
    public let cores: [CPULoad]
    public let coreKinds: [CoreKind]

    /// Mean load of all cores of one kind, nil if there are none.
    public func average(of kind: CoreKind) -> Double? {
        let loads = zip(cores, coreKinds).filter { $0.1 == kind }.map(\.0.total)
        return loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)
    }
}

/// Samples total and per-core CPU load with two Mach calls; no subprocesses.
final class CPUSampler {
    private let host = HostPort()
    let coreKinds: [CoreKind]
    private var previousTotal: CPUTicks?
    private var previousCores: [CPUTicks] = []

    init() {
        coreKinds = CoreTopology.kinds()
    }

    /// The first call only records a baseline and returns nil.
    func sample() -> CPUSnapshot? {
        guard let total = totalTicks(), let cores = coreTicks() else { return nil }
        defer {
            previousTotal = total
            previousCores = cores
        }
        guard let previousTotal, previousCores.count == cores.count else { return nil }
        return CPUSnapshot(
            total: .between(previousTotal, total),
            cores: zip(previousCores, cores).map { CPULoad.between($0, $1) },
            coreKinds: cores.indices.map { $0 < coreKinds.count ? coreKinds[$0] : .unknown }
        )
    }

    private func totalTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host.port, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? CPUTicks(info.cpu_ticks) : nil
    }

    private func coreTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard
            host_processor_info(host.port, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        // The kernel allocates the array in our address space; give it back.
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).map { index in
            let base = index * stride
            return CPUTicks(
                user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            )
        }
    }
}
