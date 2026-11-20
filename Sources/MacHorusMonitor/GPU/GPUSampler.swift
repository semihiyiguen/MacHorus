// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit

public struct GPUSnapshot: Equatable, Sendable {
    /// Share of time the GPU was busy, 0...1 (what Activity Monitor's GPU
    /// history shows).
    public let utilization: Double
    public let model: String?
    public let coreCount: Int?
    /// Memory the GPU is using right now.
    public let memoryInUse: UInt64?
}

/// Reads the `PerformanceStatistics` the GPU driver publishes in the I/O
/// Registry. Public, read-only, no permission; one registry read per round.
final class GPUSampler {
    private var accelerator = GPUSampler.findAccelerator()

    func sample() -> GPUSnapshot? {
        if let snapshot = accelerator.flatMap(Self.read) { return snapshot }
        // The driver can publish a new registry entry (e.g. after a GPU reset).
        accelerator = Self.findAccelerator()
        return accelerator.flatMap(Self.read)
    }

    private static func findAccelerator() -> IOObject? {
        IOObject(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator")))
    }

    private static func read(_ accelerator: IOObject) -> GPUSnapshot? {
        guard let statistics = property(accelerator.object, "PerformanceStatistics") as? [String: Any],
            let busy = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
        else { return nil }
        return GPUSnapshot(
            utilization: min(max(busy / 100, 0), 1),
            model: property(accelerator.object, "model") as? String,
            coreCount: (property(accelerator.object, "gpu-core-count") as? NSNumber)?.intValue,
            memoryInUse: (statistics["In use system memory"] as? NSNumber)?.uint64Value)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
