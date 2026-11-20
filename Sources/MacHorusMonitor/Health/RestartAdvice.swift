// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// When the Mac was started, from `kern.boottime` (the value `uptime` and
/// `sysctl kern.boottime` show). Time asleep counts, as there.
public enum SystemUptime {
    public static let bootDate: Date? = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }()

    public static func uptime(at now: Date = Date()) -> TimeInterval? {
        bootDate.map { max(0, now.timeIntervalSince($0)) }
    }
}

/// How strongly MacHorus recommends a restart, and why. The thresholds are
/// MacHorus' own rules (docs/MEASUREMENTS.md), not an Apple guideline:
/// every reason is shown with its value, so the advice can be checked.
public struct RestartAdvice: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case none
        case low
        case medium
        case high

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Reason: Equatable, Sendable {
        /// Seconds since the start.
        case uptime(TimeInterval)
        /// Swap in use and its share of the physical memory.
        case swap(bytes: UInt64, share: Double)
        case memoryPressure(MemoryPressure)
    }

    public let level: Level
    /// Every reason that raises the level, the strongest first.
    public let reasons: [(reason: Reason, level: Level)]

    public static func == (lhs: RestartAdvice, rhs: RestartAdvice) -> Bool {
        lhs.level == rhs.level && lhs.reasons.map(\.reason) == rhs.reasons.map(\.reason)
            && lhs.reasons.map(\.level) == rhs.reasons.map(\.level)
    }
}

public enum RestartAdvisor {
    static let day: TimeInterval = 86_400

    public static func advise(uptime: TimeInterval?, memory: MemorySnapshot?) -> RestartAdvice {
        var reasons: [(reason: RestartAdvice.Reason, level: RestartAdvice.Level)] = []
        if let uptime {
            // Weekly restarts are common IT advice; long uptimes postpone
            // updates and let swap and caches grow.
            let level: RestartAdvice.Level =
                uptime >= 30 * day ? .high : uptime >= 14 * day ? .medium : uptime >= 7 * day ? .low : .none
            if level > .none { reasons.append((.uptime(uptime), level)) }
        }
        if let memory, memory.physical > 0 {
            let share = Double(memory.swapUsed) / Double(memory.physical)
            let level: RestartAdvice.Level =
                share >= 1 ? .high : share >= 0.5 ? .medium : share >= 0.25 ? .low : .none
            if level > .none { reasons.append((.swap(bytes: memory.swapUsed, share: share), level)) }
            switch memory.pressure {
            case .critical: reasons.append((.memoryPressure(.critical), .high))
            case .warning: reasons.append((.memoryPressure(.warning), .medium))
            case .normal: break
            }
        }
        reasons.sort { $0.level > $1.level }
        return RestartAdvice(level: reasons.first?.level ?? .none, reasons: reasons)
    }
}
