// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

public struct FanReading: Equatable, Sendable {
    public let rpm: Double
    public let minimumRPM: Double?
    public let maximumRPM: Double?

    /// Apple Silicon fans stop completely when cool (0 rpm).
    public var isRunning: Bool { rpm >= 1 }
}

/// `ProcessInfo.thermalState`: how much macOS is limiting performance.
public enum ThermalPressure: Int, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

public struct ThermalSnapshot: Equatable, Sendable {
    /// Hottest sensor of each group in °C; nil if this chip has none.
    public let performanceCores: Double?
    public let efficiencyCores: Double?
    /// Nil while the GPU is powered down.
    public let gpu: Double?
    public let battery: Double?
    public let ssd: Double?
    public let fans: [FanReading]
    public let pressure: ThermalPressure
    /// False if no known sensor exists on this Mac or the policy disables it.
    public let hasSensors: Bool
    /// Which groups this Mac has sensors for: rows without one are not shown
    /// (a missing sensor is not a reading of "nothing").
    public var groups: Set<SensorGroup> = []
    /// Hottest die sensor of the chip, for chips whose core sensors are named
    /// differently (seen on M1 as well: `PMU tdie`, `PMGR SOC Die`).
    public var die: Double? = nil

    /// Hottest CPU sensor: what limits the chip; the die when no core sensor
    /// is known on this chip.
    public var cpu: Double? { [performanceCores, efficiencyCores].compactMap { $0 }.max() ?? die }
}

/// Sensor groups by their HID name, verified on Apple M1 (docs/MEASUREMENTS.md).
/// Later chips may name their core sensors differently; the die sensors
/// then stand in for the CPU, and a group without sensors is not shown.
public enum SensorGroup: CaseIterable, Sendable {
    case performanceCores
    case efficiencyCores
    case gpu
    case battery
    case ssd
    case die

    init?(name: String) {
        switch name {
        case let name where name.hasPrefix("pACC MTR Temp Sensor"): self = .performanceCores
        case let name where name.hasPrefix("eACC MTR Temp Sensor"): self = .efficiencyCores
        case let name where name.hasPrefix("GPU MTR Temp Sensor"): self = .gpu
        case let name where name.hasPrefix("gas gauge battery"): self = .battery
        case let name where name.hasPrefix("NAND CH"): self = .ssd
        case let name
        where name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie")
            || name.hasPrefix("PMGR SOC Die Temp Sensor"):
            self = .die
        default: return nil
        }
    }
}

enum ThermalMath {
    /// Anything outside is a broken or uncalibrated sensor (seen: -21.7 °C).
    static let plausible = 10.0..<125.0
    /// MTR sensors of a powered-down block report exactly 30 °C: the GPU
    /// sensors fell from 40.8 to 30.00 within one second after a load.
    static let poweredDown = 30.0

    static func hottest(_ readings: [(name: String, celsius: Double)], in group: SensorGroup) -> Double? {
        let values = readings.filter { SensorGroup(name: $0.name) == group && plausible.contains($0.celsius) }
            .map(\.celsius)
        if group == .gpu, !values.isEmpty, values.allSatisfy({ $0 == poweredDown }) { return nil }
        return values.max()
    }
}

/// Temperatures from the HID sensors, fans from the SMC. Both read-only,
/// without any permission; each can be switched off by the policy.
final class ThermalSampler {
    private let sensors: HIDTemperatureSensors?
    private let smc: SMCReader?
    let fanCount: Int
    let groups: Set<SensorGroup>
    /// SMC temperature keys where the chip has no HID sensors for them
    /// (Intel Macs): the first key with a plausible value, read once.
    private let smcCPUKey: String?
    private let smcGPUKey: String?

    /// Intel SMC keys: CPU proximity/die/package, GPU proximity/die.
    static let smcCPUKeys = ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC", "TC0H"]
    static let smcGPUKeys = ["TG0P", "TG0D", "TGDD"]

    init(allowHIDSensors: Bool = true, allowSMC: Bool = true) {
        sensors = allowHIDSensors ? HIDTemperatureSensors(include: { SensorGroup(name: $0) != nil }) : nil
        smc = allowSMC ? SMCReader() : nil
        // Laptops have one or two fans, desktops up to a few; MacBook Air none.
        fanCount = min(Int(smc?.value("FNum") ?? 0), 8)
        let hidGroups = Set((sensors?.names ?? []).compactMap(SensorGroup.init(name:)))
        let smc = smc
        func firstPlausible(_ keys: [String]) -> String? {
            keys.first { key in smc?.value(key).map(ThermalMath.plausible.contains) ?? false }
        }
        smcCPUKey =
            hidGroups.isDisjoint(with: [.performanceCores, .efficiencyCores, .die])
            ? firstPlausible(Self.smcCPUKeys) : nil
        smcGPUKey = hidGroups.contains(.gpu) ? nil : firstPlausible(Self.smcGPUKeys)
        var groups = hidGroups
        if smcCPUKey != nil { groups.insert(.die) }
        if smcGPUKey != nil { groups.insert(.gpu) }
        self.groups = groups
    }

    func sample() -> ThermalSnapshot {
        let readings = sensors?.read() ?? []
        let fans: [FanReading] = (0..<fanCount).compactMap { index in
            guard let smc, let rpm = smc.value("F\(index)Ac") else { return nil }
            return FanReading(
                rpm: max(0, rpm), minimumRPM: smc.value("F\(index)Mn"), maximumRPM: smc.value("F\(index)Mx"))
        }
        func smcValue(_ key: String?) -> Double? {
            guard let key, let value = smc?.value(key), ThermalMath.plausible.contains(value) else { return nil }
            return value
        }
        return ThermalSnapshot(
            performanceCores: ThermalMath.hottest(readings, in: .performanceCores),
            efficiencyCores: ThermalMath.hottest(readings, in: .efficiencyCores),
            gpu: ThermalMath.hottest(readings, in: .gpu) ?? smcValue(smcGPUKey),
            battery: ThermalMath.hottest(readings, in: .battery),
            ssd: ThermalMath.hottest(readings, in: .ssd),
            fans: fans,
            pressure: ThermalPressure(ProcessInfo.processInfo.thermalState),
            hasSensors: !groups.isEmpty,
            groups: groups,
            die: ThermalMath.hottest(readings, in: .die) ?? smcValue(smcCPUKey))
    }
}

/// What this Mac can measure, read once at launch: features and menu bar
/// values that cannot work here are not offered at all (a desktop has no
/// battery, a MacBook Air no fan, a new chip may name its sensors
/// differently). Cheap: one sensor list, one SMC key, one registry read.
public struct HardwareCapabilities: Equatable, Sendable {
    public let temperatureGroups: Set<SensorGroup>
    public let fanCount: Int
    public let hasGPUStatistics: Bool
    public let hasBattery: Bool

    public init(temperatureGroups: Set<SensorGroup>, fanCount: Int, hasGPUStatistics: Bool, hasBattery: Bool) {
        self.temperatureGroups = temperatureGroups
        self.fanCount = fanCount
        self.hasGPUStatistics = hasGPUStatistics
        self.hasBattery = hasBattery
    }

    /// Temperatures or fans: something for the thermal card to show.
    public var hasThermalReadings: Bool { !temperatureGroups.isEmpty || fanCount > 0 }

    /// A CPU temperature for the menu bar.
    public var hasCPUTemperature: Bool {
        !temperatureGroups.isDisjoint(with: [.performanceCores, .efficiencyCores, .die])
    }

    /// The same sources the samplers use, so what is offered is what works.
    public static func probe(allowHIDSensors: Bool, allowSMC: Bool) -> HardwareCapabilities {
        let thermal = ThermalSampler(allowHIDSensors: allowHIDSensors, allowSMC: allowSMC)
        return HardwareCapabilities(
            temperatureGroups: thermal.groups, fanCount: thermal.fanCount,
            hasGPUStatistics: GPUSampler().sample() != nil, hasBattery: MonitorHardware.hasBattery)
    }
}
