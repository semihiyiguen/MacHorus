// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit.pwr_mgt
import Testing

@testable import MacHorusTools

@Suite struct KeepAwakeTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func timedSessionEndsOnTime() {
        let session = KeepAwakeSession(started: start, duration: 3_600, keepsDisplayOn: true)
        #expect(session.remaining(at: start.addingTimeInterval(600)) == 3_000)
        #expect(!session.hasEnded(at: start.addingTimeInterval(3_599)))
        #expect(session.hasEnded(at: start.addingTimeInterval(3_600)))
        #expect(session.remaining(at: start.addingTimeInterval(4_000)) == 0)
    }

    @Test func openSessionNeverEnds() {
        let session = KeepAwakeSession(started: start, duration: nil, keepsDisplayOn: false)
        #expect(session.remaining(at: start.addingTimeInterval(1e9)) == nil)
        #expect(!session.hasEnded(at: start.addingTimeInterval(1e9)))
    }

    /// Whether this session may create power assertions at all. A CI runner
    /// without a login session may refuse; then there is nothing to check.
    static let canCreateAssertions: Bool = {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacHorus test probe" as CFString, &id)
        guard result == kIOReturnSuccess else { return false }
        IOPMAssertionRelease(id)
        return true
    }()

    /// The assertion exists with its name while the object lives and is gone
    /// afterwards. Asked by its id: the per-process list of powerd looked
    /// different on the macOS 26 runner (pipelines #50814-#50816).
    @Test(.enabled(if: canCreateAssertions, "this session may not create power assertions"))
    func assertionIsCreatedAndReleased() throws {
        func name(_ id: IOPMAssertionID) -> String? {
            guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else {
                return nil
            }
            return properties[kIOPMAssertionNameKey as String] as? String
        }
        var assertion = PowerAssertion(display: false)
        let id = try #require(assertion?.id)
        #expect(name(id) == PowerAssertion.name)
        assertion = nil
        #expect(name(id) == nil, "Released with the object")
    }
}
