// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin

/// Raw page counts from `host_statistics64(HOST_VM_INFO64)`.
public struct VMPageCounts: Equatable, Sendable {
    public var internalPages: UInt64
    public var purgeablePages: UInt64
    public var externalPages: UInt64
    public var wiredPages: UInt64
    public var compressorPages: UInt64

    public init(
        internalPages: UInt64, purgeablePages: UInt64, externalPages: UInt64, wiredPages: UInt64,
        compressorPages: UInt64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.externalPages = externalPages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
    }
}

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Memory as Activity Monitor shows it ("Memory" tab), in bytes.
public struct MemorySnapshot: Equatable, Sendable {
    public let physical: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cachedFiles: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: MemoryPressure

    /// Activity Monitor's "Memory Used": app + wired + compressed.
    public var used: UInt64 { app + wired + compressed }

    public var usedFraction: Double {
        physical > 0 ? min(1, Double(used) / Double(physical)) : 0
    }

    /// Activity Monitor's formulas (see docs/MEASUREMENTS.md):
    /// app = anonymous pages − purgeable, cached files = file-backed + purgeable.
    public init(
        pages: VMPageCounts, pageSize: UInt64, physical: UInt64, swapUsed: UInt64, swapTotal: UInt64,
        pressure: MemoryPressure
    ) {
        let appPages = pages.internalPages > pages.purgeablePages ? pages.internalPages - pages.purgeablePages : 0
        self.physical = physical
        app = appPages * pageSize
        wired = pages.wiredPages * pageSize
        compressed = pages.compressorPages * pageSize
        cachedFiles = (pages.externalPages + pages.purgeablePages) * pageSize
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}

/// Reads memory counters with one Mach call and three sysctls; no subprocesses.
final class MemorySampler {
    private let host = HostPort()
    private let pageSize = UInt64(sysctlValue("hw.pagesize", as: Int64.self) ?? 16_384)
    private let physical = sysctlValue("hw.memsize", as: UInt64.self) ?? 0

    func sample() -> MemorySnapshot? {
        guard let pages = pageCounts() else { return nil }
        let swap = sysctlValue("vm.swapusage", as: xsw_usage.self)
        let level = sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self).map(Int.init) ?? 1
        return MemorySnapshot(
            pages: pages, pageSize: pageSize, physical: physical,
            swapUsed: swap?.xsu_used ?? 0, swapTotal: swap?.xsu_total ?? 0,
            pressure: MemoryPressure(rawValue: level) ?? .normal
        )
    }

    func pageCounts() -> VMPageCounts? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host.port, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            internalPages: UInt64(info.internal_page_count),
            purgeablePages: UInt64(info.purgeable_count),
            externalPages: UInt64(info.external_page_count),
            wiredPages: UInt64(info.wire_count),
            compressorPages: UInt64(info.compressor_page_count)
        )
    }
}
