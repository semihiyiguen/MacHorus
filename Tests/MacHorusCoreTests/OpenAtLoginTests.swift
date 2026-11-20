// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusCore

@Suite struct OpenAtLoginTests {
    private let installed = URL(fileURLWithPath: "/Applications/MacHorus.app")

    @Test func installedCopyTurnsItOnAtItsFirstLaunch() {
        #expect(OpenAtLogin.turnsOnAtLaunch(alreadyDecided: false, bundleURL: installed))
        #expect(
            OpenAtLogin.turnsOnAtLaunch(
                alreadyDecided: false, bundleURL: URL(fileURLWithPath: "/System/Volumes/Data/Applications/MacHorus.app")
            ))
    }

    @Test func neverAgainOnceDecided() {
        // The user may have switched it off, here or in System Settings.
        #expect(!OpenAtLogin.turnsOnAtLaunch(alreadyDecided: true, bundleURL: installed))
    }

    @Test(arguments: [
        "/Users/someone/Projects/MacHorus/build/MacHorus.app",
        "/Users/someone/Applications/MacHorus.app",
        "/Applications Old/MacHorus.app",
        "/Volumes/Installer/MacHorus.app",
    ])
    func otherCopiesNeverTurnItOnAlone(path: String) {
        #expect(!OpenAtLogin.turnsOnAtLaunch(alreadyDecided: false, bundleURL: URL(fileURLWithPath: path)))
    }

    @Test func pathIsStandardizedFirst() {
        let dotted = URL(fileURLWithPath: "/Applications/../Users/someone/MacHorus.app")
        #expect(!OpenAtLogin.isInstalled(dotted))
    }
}
