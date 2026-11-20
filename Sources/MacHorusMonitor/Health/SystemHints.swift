// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Things worth the user's attention, each from one measured value and a
/// documented rule (docs/MEASUREMENTS.md). An empty list means all is well.
public enum SystemHint: Equatable, Sendable {
    /// The restart advice is low or higher; its reasons explain why.
    case restart(RestartAdvice.Level)
    /// Less than 10 % of the startup disk is free.
    case diskAlmostFull(availableBytes: UInt64, share: Double)
    /// The battery holds less than 80 % of its design capacity.
    case batteryWorn(healthPercent: Int)
    /// macOS slows the Mac down to cool it (thermal state serious or critical).
    case thermalThrottling(ThermalPressure)

    public static func hints(
        restart: RestartAdvice, disk: DiskSnapshot?, battery: BatterySnapshot?, thermal: ThermalSnapshot?
    ) -> [SystemHint] {
        var hints: [SystemHint] = []
        if restart.level > .none { hints.append(.restart(restart.level)) }
        if let disk, disk.totalBytes > 0 {
            let share = Double(disk.availableBytes) / Double(disk.totalBytes)
            if share < 0.1 { hints.append(.diskAlmostFull(availableBytes: disk.availableBytes, share: share)) }
        }
        if let health = battery?.healthPercent, health < 80 { hints.append(.batteryWorn(healthPercent: health)) }
        if let pressure = thermal?.pressure, pressure == .serious || pressure == .critical {
            hints.append(.thermalThrottling(pressure))
        }
        return hints
    }
}
