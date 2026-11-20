// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct AlertEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(at seconds: TimeInterval, cpu: Double? = nil, battery: Int? = nil, onPower: Bool = false)
        -> MonitorSnapshot
    {
        MonitorSnapshot(
            date: start.addingTimeInterval(seconds),
            cpu: cpu.map { CPUSnapshot(total: CPULoad(user: $0, system: 0), cores: [], coreKinds: []) },
            memory: nil, disk: nil, network: nil,
            battery: battery.map {
                BatterySnapshot(
                    charge: $0, isCharging: false, isOnExternalPower: onPower, minutesRemaining: nil, cycleCount: nil,
                    healthPercent: nil, powerWatts: nil, adapterWatts: nil)
            },
            thermal: nil, gpu: nil, processes: nil)
    }

    /// One round every 4 s (the interval with the panel closed) from `from`
    /// through `to`; returns the seconds at which an alert fired.
    private func feed(_ evaluator: inout AlertEvaluator, _ from: TimeInterval, _ to: TimeInterval, cpu: Double)
        -> [TimeInterval]
    {
        stride(from: from, through: to, by: 4).filter { !evaluator.evaluate(snapshot(at: $0, cpu: cpu)).isEmpty }
    }

    @Test func busyCPUMustLastTwoMinutes() {
        var evaluator = AlertEvaluator()
        #expect(feed(&evaluator, 0, 116, cpu: 0.95).isEmpty)
        #expect(evaluator.active.isEmpty)
        #expect(evaluator.evaluate(snapshot(at: 120, cpu: 0.95)) == [.cpuBusy])
        #expect(evaluator.active == [.cpuBusy])
    }

    @Test func aDipStartsTheWaitAgain() {
        var evaluator = AlertEvaluator()
        #expect(feed(&evaluator, 0, 96, cpu: 0.95).isEmpty)
        #expect(feed(&evaluator, 100, 100, cpu: 0.4).isEmpty)
        #expect(feed(&evaluator, 104, 240, cpu: 0.95) == [224])
    }

    @Test func missingMetricKeepsTheState() {
        // Battery and temperatures are read every other round.
        var evaluator = AlertEvaluator()
        let fired = stride(from: 0.0, through: 120, by: 4).filter {
            let cpu = $0.truncatingRemainder(dividingBy: 8) == 0 ? 0.95 : nil
            return !evaluator.evaluate(snapshot(at: $0, cpu: cpu)).isEmpty
        }
        #expect(fired == [120])
    }

    @Test func aPauseInSamplingStartsTheWaitAgain() {
        // Busy for 100 s, then the screen is locked for a minute: the
        // condition was not seen holding, so the two minutes start anew.
        var evaluator = AlertEvaluator()
        #expect(feed(&evaluator, 0, 100, cpu: 0.95).isEmpty)
        #expect(feed(&evaluator, 160, 300, cpu: 0.95) == [280])
        // An active alert is not kept across a pause either.
        #expect(evaluator.active == [.cpuBusy])
        #expect(evaluator.evaluate(snapshot(at: 400, cpu: 0.95)).isEmpty)
        #expect(evaluator.active.isEmpty)
    }

    @Test func cooldownOfFifteenMinutes() {
        var evaluator = AlertEvaluator()
        #expect(evaluator.evaluate(snapshot(at: 0, battery: 10)) == [.batteryLow])
        #expect(evaluator.evaluate(snapshot(at: 60, battery: 9)).isEmpty, "Still low, but in the cooldown")
        #expect(evaluator.active == [.batteryLow])
        #expect(evaluator.evaluate(snapshot(at: 901, battery: 8)) == [.batteryLow])
    }

    @Test func batteryOnPowerOrAbove15IsFine() {
        var evaluator = AlertEvaluator()
        #expect(evaluator.evaluate(snapshot(at: 0, battery: 10, onPower: true)).isEmpty)
        #expect(evaluator.evaluate(snapshot(at: 1, battery: 15)).isEmpty)
        #expect(evaluator.active.isEmpty)
    }

    @Test func switchedOffKindsNeverAlert() {
        var evaluator = AlertEvaluator()
        var rules = AlertRules()
        rules.batteryEnabled = false
        #expect(evaluator.evaluate(snapshot(at: 0, battery: 10), rules: rules).isEmpty)
        #expect(evaluator.active.isEmpty)
    }

    @Test func thresholdsFollowTheRules() {
        var rules = AlertRules()
        rules.batteryPercent = 30
        rules.cpuPercent = 70
        rules.cpuMinutes = 1
        var evaluator = AlertEvaluator()
        #expect(evaluator.evaluate(snapshot(at: 0, battery: 25), rules: rules) == [.batteryLow])
        var cpu = AlertEvaluator()
        #expect(cpu.evaluate(snapshot(at: 0, cpu: 0.75), rules: rules).isEmpty)
        #expect(cpu.evaluate(snapshot(at: 30, cpu: 0.75), rules: rules).isEmpty)
        #expect(cpu.evaluate(snapshot(at: 60, cpu: 0.75), rules: rules) == [.cpuBusy], "one minute at 70 %")
    }

    @Test func aBigDiskCanAlertByGigabytes() {
        let disk = DiskSnapshot(
            totalBytes: 2_000_000_000_000, availableBytes: 150_000_000_000, readBytesPerSecond: 0,
            writeBytesPerSecond: 0, totalReadBytes: 0, totalWrittenBytes: 0)
        var rules = AlertRules()
        #expect(rules.diskIsLow(disk), "7.5 % free is below the default 10 %")
        rules.diskMode = .gigabytes
        rules.diskGigabytes = 100
        #expect(!rules.diskIsLow(disk), "150 GB free is more than 100 GB")
        rules.diskGigabytes = 200
        #expect(rules.diskIsLow(disk))
    }

    @Test func storedRulesKeepDefaultsForMissingFields() {
        var rules = AlertRules()
        rules.hotCelsius = 95
        rules.diskMode = .gigabytes
        #expect(AlertRules(stored: rules.stored) == rules)
        #expect(AlertRules(stored: Data(#"{"hotCelsius":80}"#.utf8)).cpuPercent == 90)
        #expect(AlertRules(stored: Data("garbage".utf8)) == AlertRules())
    }

    /// Versions before 1.0.20 stored no rules: the defaults are the fixed
    /// rules those versions used, so alerts behave as before the update.
    @Test func withoutStoredRulesTheOldFixedRulesApply() {
        let rules = AlertRules(stored: nil)
        #expect(rules.enabledKinds == Set(AlertKind.allCases))
        #expect(rules.cpuPercent == 90 && rules.cpuMinutes == 2 && rules.hotCelsius == 90)
        #expect(rules.diskMode == .percent && rules.diskPercent == 10 && rules.batteryPercent == 15)
    }
}
