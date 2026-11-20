// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// A condition that must hold for a while before it alerts, and that alerts
/// again only after a cooldown (docs/MEASUREMENTS.md).
public enum AlertKind: String, CaseIterable, Sendable {
    /// Total CPU load at or above 90 % for two minutes.
    case cpuBusy
    /// Hottest CPU sensor at or above 90 °C, or macOS throttling, for a minute.
    case hot
    /// Memory pressure critical for 30 seconds.
    case memoryPressure
    /// Less than 10 % of the startup disk free.
    case diskFull
    /// Battery below 15 % and not on power.
    case batteryLow

    /// How long the condition must hold with the default rules.
    public var holdSeconds: TimeInterval { AlertRules().holdSeconds(self) }

    /// Whether the condition holds in this snapshot under `rules`; nil if
    /// the metric is not measured.
    func holds(in snapshot: MonitorSnapshot, rules: AlertRules = AlertRules()) -> Bool? {
        switch self {
        case .cpuBusy:
            return snapshot.cpu.map { $0.total.total >= Double(rules.cpuPercent) / 100 }
        case .hot:
            guard let thermal = snapshot.thermal else { return nil }
            let throttling = thermal.pressure == .serious || thermal.pressure == .critical
            return throttling || (thermal.cpu ?? 0) >= Double(rules.hotCelsius)
        case .memoryPressure:
            return snapshot.memory.map { $0.pressure == .critical }
        case .diskFull:
            return snapshot.disk.map(rules.diskIsLow)
        case .batteryLow:
            return snapshot.battery.map { $0.charge < rules.batteryPercent && !$0.isOnExternalPower }
        }
    }
}

/// Turns snapshots into alerts: a condition must hold for `holdSeconds`
/// (measured from its first sighting, ended by any snapshot without it),
/// then alerts once; the same kind alerts again only after `cooldown`.
public struct AlertEvaluator: Sendable {
    public static let cooldown: TimeInterval = 15 * 60
    /// A longer pause between two readings of a kind (sampling stopped,
    /// e.g. while the screen was locked) starts its wait again: the
    /// condition was not seen holding the whole time.
    public static let maxGap: TimeInterval = 30

    private var since: [AlertKind: Date] = [:]
    private var lastSeen: [AlertKind: Date] = [:]
    private var lastAlert: [AlertKind: Date] = [:]
    /// Kinds whose condition holds long enough right now.
    public private(set) var active: Set<AlertKind> = []

    public init() {}

    /// Returns the kinds that alert now (new, outside their cooldown).
    public mutating func evaluate(_ snapshot: MonitorSnapshot, rules: AlertRules = AlertRules()) -> [AlertKind] {
        var fired: [AlertKind] = []
        for kind in AlertKind.allCases {
            guard rules.isEnabled(kind) else {
                // Switched off: forget it, it starts from scratch when back on.
                since[kind] = nil
                active.remove(kind)
                continue
            }
            // A metric not in this snapshot (e.g. read every other round)
            // keeps the state as it is.
            guard let holds = kind.holds(in: snapshot, rules: rules) else { continue }
            if let seen = lastSeen[kind], snapshot.date.timeIntervalSince(seen) > Self.maxGap {
                since[kind] = nil
                active.remove(kind)
            }
            lastSeen[kind] = snapshot.date
            guard holds else {
                since[kind] = nil
                active.remove(kind)
                continue
            }
            let start = since[kind] ?? snapshot.date
            since[kind] = start
            guard snapshot.date.timeIntervalSince(start) >= rules.holdSeconds(kind) else { continue }
            active.insert(kind)
            if let last = lastAlert[kind], snapshot.date.timeIntervalSince(last) < Self.cooldown { continue }
            lastAlert[kind] = snapshot.date
            fired.append(kind)
        }
        return fired
    }
}
