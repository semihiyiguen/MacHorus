// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import IOKit

/// Startup volume capacity and the throughput of all block storage drivers.
public struct DiskSnapshot: Equatable, Sendable {
    /// Size of the APFS container that holds the startup volume.
    public let totalBytes: UInt64
    /// Free in the container, as `df` and `diskutil` report it (purgeable
    /// space that macOS could free on demand is not included).
    public let availableBytes: UInt64
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    /// Lifetime counters since boot, used to verify against `iostat -I`.
    public let totalReadBytes: UInt64
    public let totalWrittenBytes: UInt64

    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

/// Byte counters at one moment; rates come from two of these.
struct DiskCounters: Equatable {
    var read: UInt64
    var written: UInt64
    var uptime: TimeInterval

    /// Bytes per second between two readings; a counter that went backwards
    /// (disk removed, driver reloaded) yields zero instead of a huge spike.
    static func rates(_ old: DiskCounters, _ new: DiskCounters) -> (read: Double, write: Double) {
        let seconds = new.uptime - old.uptime
        guard seconds > 0, new.read >= old.read, new.written >= old.written else { return (0, 0) }
        return (Double(new.read - old.read) / seconds, Double(new.written - old.written) / seconds)
    }
}

/// Reads one statfs and one property per block storage driver per round;
/// the driver handles are looked up once and refreshed every 30 rounds.
final class DiskSampler {
    private var drivers: [IOObject] = []
    private var roundsSinceLookup = Int.max
    private var previous: DiskCounters?

    func sample(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> DiskSnapshot? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let blockSize = UInt64(stats.f_bsize)
        let counters = readCounters(uptime: uptime)
        let rates = previous.map { DiskCounters.rates($0, counters) } ?? (read: 0, write: 0)
        previous = counters
        return DiskSnapshot(
            totalBytes: UInt64(stats.f_blocks) * blockSize,
            availableBytes: UInt64(stats.f_bavail) * blockSize,
            readBytesPerSecond: rates.read,
            writeBytesPerSecond: rates.write,
            totalReadBytes: counters.read,
            totalWrittenBytes: counters.written
        )
    }

    private func readCounters(uptime: TimeInterval) -> DiskCounters {
        if roundsSinceLookup >= 30 {
            drivers = Self.blockStorageDrivers()
            roundsSinceLookup = 0
        }
        roundsSinceLookup += 1
        // Keys from IOKit/storage/IOBlockStorageDriver.h (kIOBlockStorageDriverStatistics*).
        var counters = DiskCounters(read: 0, written: 0, uptime: uptime)
        for driver in drivers {
            guard
                let statistics = IORegistryEntryCreateCFProperty(
                    driver.object, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
            else { continue }
            counters.read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            counters.written +=
                (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return counters
    }

    private static func blockStorageDrivers() -> [IOObject] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS, let services = IOObject(iterator)
        else { return [] }
        var drivers: [IOObject] = []
        while let driver = IOObject(IOIteratorNext(services.object)) { drivers.append(driver) }
        return drivers
    }
}
