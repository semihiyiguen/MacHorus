// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusCore

@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("1", SemanticVersion(major: 1, minor: 0, patch: 0)),
        ("1.2", SemanticVersion(major: 1, minor: 2, patch: 0)),
        ("1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("0.0.1", SemanticVersion(major: 0, minor: 0, patch: 1)),
        ("10.20.30", SemanticVersion(major: 10, minor: 20, patch: 30)),
    ])
    func parsesValidVersions(input: String, expected: SemanticVersion) {
        #expect(SemanticVersion(input) == expected)
    }

    @Test(arguments: ["", ".", "1.", ".1", "1..2", "1.2.3.4", "a.b.c", "1.2.x", " 1.2.3", "-1.0.0", "+1", "1.2.3-beta"])
    func rejectsInvalidVersions(input: String) {
        #expect(SemanticVersion(input) == nil)
    }

    @Test func comparesComponentWise() {
        #expect(SemanticVersion("1.2.3")! < SemanticVersion("1.2.4")!)
        #expect(SemanticVersion("1.2.9")! < SemanticVersion("1.10.0")!)
        #expect(SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!)
        #expect(SemanticVersion("1.2")! == SemanticVersion("1.2.0")!)
    }

    @Test func describesAsDottedTriple() {
        #expect(SemanticVersion("3")!.description == "3.0.0")
    }

    @Test func currentVersionFallsBackOutsideAppBundle() {
        let bundle = Bundle(for: BundleToken.self)
        #expect(AppIdentity.currentVersion(bundle: bundle) == SemanticVersion(major: 0, minor: 0, patch: 0))
    }
}

private final class BundleToken {}
