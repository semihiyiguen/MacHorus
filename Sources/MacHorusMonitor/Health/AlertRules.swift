// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// When each alert comes, set by the user: on or off, and its threshold.
/// The defaults are the fixed rules of 1.0–1.0.19. A 2 TB disk with 10 %
/// free still has 200 GB: there the user can switch to "less than N GB".
public struct AlertRules: Equatable, Sendable, Codable {
    public enum DiskMode: String, Codable, Sendable, CaseIterable {
        case percent
        case gigabytes
    }

    public var cpuEnabled = true
    /// Total CPU load in percent.
    public var cpuPercent = 90
    public var cpuMinutes = 2

    public var hotEnabled = true
    /// Hottest CPU sensor in °C (macOS throttling alerts too).
    public var hotCelsius = 90

    public var memoryEnabled = true

    public var diskEnabled = true
    public var diskMode = DiskMode.percent
    public var diskPercent = 10
    public var diskGigabytes = 20

    public var batteryEnabled = true
    public var batteryPercent = 15

    /// Offered values (menus instead of free input: nothing invalid can be set).
    public static let cpuPercents = [70, 80, 90, 95]
    public static let cpuMinuteChoices = [1, 2, 5, 10]
    public static let hotChoices = [80, 85, 90, 95, 100]
    public static let diskPercents = [5, 10, 15, 20]
    public static let diskGigabyteChoices = [10, 20, 50, 100, 200]
    public static let batteryPercents = [5, 10, 15, 20, 30]

    public init() {}

    public func isEnabled(_ kind: AlertKind) -> Bool {
        switch kind {
        case .cpuBusy: cpuEnabled
        case .hot: hotEnabled
        case .memoryPressure: memoryEnabled
        case .diskFull: diskEnabled
        case .batteryLow: batteryEnabled
        }
    }

    public var enabledKinds: Set<AlertKind> { Set(AlertKind.allCases.filter(isEnabled)) }

    public func holdSeconds(_ kind: AlertKind) -> TimeInterval {
        switch kind {
        case .cpuBusy: TimeInterval(cpuMinutes * 60)
        case .hot: 60
        case .memoryPressure: 30
        case .diskFull, .batteryLow: 0
        }
    }

    /// The startup disk is below the user's limit.
    public func diskIsLow(_ disk: DiskSnapshot) -> Bool {
        guard disk.totalBytes > 0 else { return false }
        switch diskMode {
        case .percent: return Double(disk.availableBytes) / Double(disk.totalBytes) < Double(diskPercent) / 100
        case .gigabytes: return disk.availableBytes < UInt64(diskGigabytes) * 1_000_000_000
        }
    }

    /// Stored as JSON; anything unreadable (or from an older build without
    /// a field) keeps the defaults for what is missing.
    public init(stored data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(AlertRules.self, from: $0) } ?? AlertRules()
    }

    public var stored: Data? { try? JSONEncoder().encode(self) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertRules()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        cpuEnabled = value(.cpuEnabled, defaults.cpuEnabled)
        cpuPercent = value(.cpuPercent, defaults.cpuPercent)
        cpuMinutes = value(.cpuMinutes, defaults.cpuMinutes)
        hotEnabled = value(.hotEnabled, defaults.hotEnabled)
        hotCelsius = value(.hotCelsius, defaults.hotCelsius)
        memoryEnabled = value(.memoryEnabled, defaults.memoryEnabled)
        diskEnabled = value(.diskEnabled, defaults.diskEnabled)
        diskMode = value(.diskMode, defaults.diskMode)
        diskPercent = value(.diskPercent, defaults.diskPercent)
        diskGigabytes = value(.diskGigabytes, defaults.diskGigabytes)
        batteryEnabled = value(.batteryEnabled, defaults.batteryEnabled)
        batteryPercent = value(.batteryPercent, defaults.batteryPercent)
    }
}
