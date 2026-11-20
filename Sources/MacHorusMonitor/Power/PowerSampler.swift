// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit
import IOKit.ps

public struct BatterySnapshot: Equatable, Sendable {
    /// Charge in percent, as the menu bar shows it.
    public let charge: Int
    public let isCharging: Bool
    public let isOnExternalPower: Bool
    /// Minutes until empty or full, nil while macOS is still estimating.
    public let minutesRemaining: Int?
    public let cycleCount: Int?
    /// "Maximum Capacity" from System Settings > Battery, in percent.
    public let healthPercent: Int?
    /// Positive while charging, negative while discharging, in watts.
    public let powerWatts: Double?
    public let adapterWatts: Int?
}

public enum BatteryMath {
    /// macOS' "Maximum Capacity" is the full-charge capacity relative to the
    /// design capacity, **rounded up** (observed: 4151/5103 = 81.34 % shows
    /// as 82 %). NominalChargeCapacity would read a few percent too high.
    public static func healthPercent(fullCharge: Int, design: Int) -> Int? {
        guard design > 0, fullCharge > 0 else { return nil }
        return Int((Double(fullCharge) * 100 / Double(design)).rounded(.up))
    }

    /// Battery power from millivolts and (signed) milliamperes.
    public static func watts(millivolts: Int, milliamperes: Int) -> Double {
        Double(millivolts) * Double(milliamperes) / 1_000_000
    }
}

/// IOPowerSources for charge and time, the AppleSmartBattery registry entry
/// for cycles, health and power. Macs without a battery return nil.
final class PowerSampler {
    private var battery: IOObject?
    private var looked = false

    func sample() -> BatterySnapshot? {
        guard let source = Self.internalBattery() else { return nil }
        if !looked {
            battery = IOObject(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")))
            looked = true
        }
        // Only the needed properties, not the whole registry dictionary.
        var registry: [String: Any] = [:]
        for key in ["Voltage", "Amperage", "CycleCount", "AdapterDetails", "BatteryData"] {
            if let battery, let value = Self.property(battery, key) { registry[key] = value }
        }
        // macOS 27 moved the capacities into the BatteryData dictionary.
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        func integer(_ dictionary: [String: Any], _ key: String) -> Int? {
            (dictionary[key] as? NSNumber)?.intValue
        }
        let isCharging = source[kIOPSIsChargingKey] as? Bool ?? false
        let state = source[kIOPSPowerSourceStateKey] as? String
        let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (source[minutesKey] as? NSNumber)?.intValue
        let current = integer(source, kIOPSCurrentCapacityKey) ?? 0
        let maximum = integer(source, kIOPSMaxCapacityKey) ?? 100
        let voltage = integer(registry, "Voltage")
        let amperage = integer(registry, "Amperage")
        let adapter = registry["AdapterDetails"] as? [String: Any]
        return BatterySnapshot(
            charge: maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current,
            isCharging: isCharging,
            isOnExternalPower: state == kIOPSACPowerValue,
            minutesRemaining: minutes.flatMap { $0 >= 0 ? $0 : nil },
            cycleCount: integer(registry, "CycleCount"),
            healthPercent: BatteryMath.healthPercent(
                fullCharge: integer(data, "FullChargeCapacity") ?? 0, design: integer(data, "DesignCapacity") ?? 0),
            // Apple's own figure first; voltage × current only as a fallback.
            powerWatts: integer(data, "BatteryPower").map { Double($0) / 1_000 }
                ?? voltage.flatMap { volts in
                    amperage.map { BatteryMath.watts(millivolts: volts, milliamperes: $0) }
                },
            adapterWatts: adapter.flatMap { integer($0, "Watts") }
        )
    }

    private static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }

    private static func property(_ entry: IOObject, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry.object, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
