// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusTools

@Suite struct DevicesTests {
    private let printer = PrintQueue.Printer(name: "Office", displayName: "Office", isStopped: false, reasons: [])
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func job(_ state: PrintQueue.Job.State, age: TimeInterval) -> PrintQueue.Job {
        PrintQueue.Job(id: 1, printer: "Office", title: "Doc", state: state, created: now - age, bytes: 1_024)
    }

    @Test func aJobIsStuckWhenHeldStoppedOrOld() {
        #expect(!PrintQueue.isStuck(job(.printing, age: 30), printers: [printer], now: now))
        #expect(PrintQueue.isStuck(job(.pending, age: 4 * 60), printers: [printer], now: now))
        #expect(PrintQueue.isStuck(job(.held, age: 5), printers: [printer], now: now))
        let stopped = PrintQueue.Printer(name: "Office", displayName: "Office", isStopped: true, reasons: ["paused"])
        #expect(PrintQueue.isStuck(job(.pending, age: 5), printers: [stopped], now: now))
    }

    /// The real system: nothing here may fail or hang, whatever is attached.
    @Test func readingTheRealSystemNeverFails() {
        _ = PrintQueue.printers()
        _ = PrintQueue.jobs()
        _ = ConnectedDevices.usbDevices()
        _ = ConnectedDevices.powerAdapter()
        let drives = ConnectedDevices.externalDrives()
        #expect(!drives.contains { $0.url.path == "/" }, "the startup disk is never offered for ejecting")
    }
}
