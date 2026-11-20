// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// One thing on this Mac that needs attention, for the overview's status.
public struct StatusItem: Equatable, Sendable {
    /// Info: good to know, can be hidden. Yellow: can wait. Red: act now.
    public enum Severity: Int, Comparable, Sendable {
        case info = 0
        case warning = 1
        case critical = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: Equatable, Sendable {
        case restart(RestartAdvice.Reason, RestartAdvice.Level)
        case alert(AlertKind)
        case diskAlmostFull(availableBytes: UInt64, share: Double)
        case batteryWorn(healthPercent: Int)
        case thermal(ThermalPressure)
        case updates(count: Int, needsRestart: Bool)
        case accessoryBattery(AccessoryBattery)
        /// Wi-Fi is the connection in use and its signal is weak (dBm).
        case weakWiFi(rssi: Int)
    }

    public let kind: Kind
    public let severity: Severity

    /// Info points can be hidden until they change: a further worn battery
    /// (each 5 points) or a different number of updates shows again.
    public var dismissKey: String? {
        switch kind {
        case .batteryWorn(let health): "battery.\(health / 5)"
        case .updates(let count, let needsRestart): "updates.\(count).\(needsRestart ? 1 : 0)"
        default: nil
        }
    }
}

/// Merges restart reasons, hints, alerts and pending updates into one list,
/// worst first, without saying the same thing twice.
public enum StatusSummary {
    public static func items(
        restart: RestartAdvice, disk: DiskSnapshot?, battery: BatterySnapshot?, thermal: ThermalSnapshot?,
        alerts: Set<AlertKind>, updates: SoftwareUpdates?, accessories: [AccessoryBattery] = [],
        wifi: WiFiQuality? = nil, wifiIsPrimary: Bool = false, dismissed: Set<String> = [],
        rules: AlertRules = AlertRules()
    ) -> [StatusItem] {
        var items: [StatusItem] = []
        for (reason, level) in restart.reasons {
            items.append(StatusItem(kind: .restart(reason, level), severity: level == .high ? .critical : .warning))
        }
        let hasCriticalPressureReason = restart.reasons.contains { $0.reason == .memoryPressure(.critical) }
        for kind in AlertKind.allCases where alerts.contains(kind) {
            // The restart reason already says it, with its value.
            if kind == .memoryPressure && hasCriticalPressureReason { continue }
            items.append(StatusItem(kind: .alert(kind), severity: kind == .cpuBusy ? .warning : .critical))
        }
        // The same limit as the disk alert; switched off, no hint either.
        if let disk, disk.totalBytes > 0, !alerts.contains(.diskFull), rules.diskEnabled, rules.diskIsLow(disk) {
            let share = Double(disk.availableBytes) / Double(disk.totalBytes)
            var half = rules
            half.diskPercent = max(rules.diskPercent / 2, 1)
            half.diskGigabytes = max(rules.diskGigabytes / 2, 1)
            items.append(
                StatusItem(
                    kind: .diskAlmostFull(availableBytes: disk.availableBytes, share: share),
                    severity: half.diskIsLow(disk) ? .critical : .warning))
        }
        // Worn batteries and pending updates are no emergency: info only,
        // so the list does not cry wolf every day.
        if let health = battery?.healthPercent, health < 80 {
            items.append(StatusItem(kind: .batteryWorn(healthPercent: health), severity: .info))
        }
        if let pressure = thermal?.pressure, pressure == .serious || pressure == .critical, !alerts.contains(.hot) {
            items.append(StatusItem(kind: .thermal(pressure), severity: pressure == .critical ? .critical : .warning))
        }
        if let updates, updates.count > 0 {
            items.append(
                StatusItem(
                    kind: .updates(count: updates.count, needsRestart: updates.restart >= .recommended),
                    severity: .info))
        }
        // A keyboard or mouse running empty: yellow at 15 %, red at 5 %.
        for accessory in accessories where accessory.percent <= 15 {
            items.append(
                StatusItem(kind: .accessoryBattery(accessory), severity: accessory.percent <= 5 ? .critical : .warning))
        }
        // Only when Wi-Fi carries the traffic (not with a cable plugged in).
        if let wifi, wifiIsPrimary, wifi.rssi < -75 {
            items.append(StatusItem(kind: .weakWiFi(rssi: wifi.rssi), severity: .warning))
        }
        items.removeAll { $0.dismissKey.map(dismissed.contains) ?? false }
        // Worst first; equal ones keep the order above.
        return items.enumerated().sorted { ($1.element.severity, $0.offset) < ($0.element.severity, $1.offset) }
            .map(\.element)
    }
}
