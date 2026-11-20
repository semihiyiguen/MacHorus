// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit.pwr_mgt

/// One "keep awake" period: until a time, or until switched off.
public struct KeepAwakeSession: Equatable, Sendable {
    public let started: Date
    /// Nil keeps the Mac awake until the user switches it off.
    public let ends: Date?
    /// The display stays on too (presentations); otherwise only the system.
    public let keepsDisplayOn: Bool

    public init(started: Date, duration: TimeInterval?, keepsDisplayOn: Bool) {
        self.started = started
        ends = duration.map { started.addingTimeInterval($0) }
        self.keepsDisplayOn = keepsDisplayOn
    }

    public func remaining(at now: Date) -> TimeInterval? {
        ends.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func hasEnded(at now: Date) -> Bool {
        ends.map { now >= $0 } ?? false
    }
}

/// A named power assertion, like `caffeinate`: listed by
/// `pmset -g assertions` under MacHorus with `name`. Released on deinit, and
/// by the system when the process ends, so it can never outlive the app.
public final class PowerAssertion {
    public static let name = "MacHorus: keep awake"
    let id: IOPMAssertionID

    /// `display`: also prevents the display from sleeping.
    public init?(display: Bool) {
        var id: IOPMAssertionID = 0
        let type = display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.name as CFString, &id)
        guard result == kIOReturnSuccess else { return nil }
        self.id = id
    }

    deinit {
        IOPMAssertionRelease(id)
    }
}
