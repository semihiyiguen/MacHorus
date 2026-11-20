// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct SMCValueTests {
    @Test func decodesTheEncodingsSeenOnAppleSilicon() throws {
        // Bytes as read on a test Mac (TB0T, TG0B, F0Mx).
        let float = withUnsafeBytes(of: Float(26.6).bitPattern.littleEndian) { Array($0) }
        #expect(try #require(SMCValue.decode(float, type: "flt ")) == Double(Float(26.6)))
        #expect(SMCValue.decode([0x99, 0x99, 0x1a, 0, 0, 0, 0, 0], type: "ioft").map { ($0 * 100).rounded() } == 2_660)
        #expect(SMCValue.decode([0x1a, 0x80], type: "sp78") == 26.5)
        #expect(SMCValue.decode([1], type: "ui8 ") == 1)
        #expect(SMCValue.decode([0x01, 0x00], type: "ui16") == 256)
    }

    @Test func rejectsUnknownTypesAndWrongSizes() {
        #expect(SMCValue.decode([0, 0, 0, 0], type: "hex_") == nil)
        #expect(SMCValue.decode([0, 0], type: "flt ") == nil)
        #expect(SMCValue.decode([], type: "ui8 ") == nil)
    }
}

@Suite struct ThermalMathTests {
    @Test func groupsSensorsByTheirNames() {
        // Names as the M1 reports them (MacHorus --print-sensors).
        #expect(SensorGroup(name: "pACC MTR Temp Sensor2") == .performanceCores)
        #expect(SensorGroup(name: "eACC MTR Temp Sensor0") == .efficiencyCores)
        #expect(SensorGroup(name: "GPU MTR Temp Sensor4") == .gpu)
        #expect(SensorGroup(name: "gas gauge battery") == .battery)
        #expect(SensorGroup(name: "NAND CH0 temp") == .ssd)
        // Die sensors stand in for the CPU on chips with other core names.
        for name in ["PMU tdie1", "PMU2 tdie3", "PMGR SOC Die Temp Sensor0"] {
            #expect(SensorGroup(name: name) == .die, "\(name) is a die sensor")
        }
        for name in ["PMU tdev4", "ANE MTR Temp Sensor1", "SOC MTR Temp Sensor0", "PMU TP3w"] {
            #expect(SensorGroup(name: name) == nil, "\(name) is not shown")
        }
    }

    @Test func cpuFallsBackToTheDieWithoutCoreSensors() {
        let withCores = ThermalSnapshot(
            performanceCores: 52, efficiencyCores: 44, gpu: nil, battery: nil, ssd: nil, fans: [], pressure: .nominal,
            hasSensors: true, groups: [.performanceCores, .efficiencyCores, .die], die: 61)
        #expect(withCores.cpu == 52, "core sensors win when the chip has them")
        let dieOnly = ThermalSnapshot(
            performanceCores: nil, efficiencyCores: nil, gpu: nil, battery: nil, ssd: nil, fans: [], pressure: .nominal,
            hasSensors: true, groups: [.die], die: 58)
        #expect(dieOnly.cpu == 58)
    }

    @Test func takesTheHottestPlausibleSensor() {
        let readings: [(name: String, celsius: Double)] = [
            ("pACC MTR Temp Sensor2", 54.6), ("pACC MTR Temp Sensor3", 48.1), ("pACC MTR Temp Sensor4", -21.7),
            ("eACC MTR Temp Sensor0", 130),
        ]
        #expect(ThermalMath.hottest(readings, in: .performanceCores) == 54.6)
        #expect(ThermalMath.hottest(readings, in: .efficiencyCores) == nil, "130 °C is not plausible")
        #expect(ThermalMath.hottest(readings, in: .battery) == nil)
    }

    @Test func gpuReadingExactly30MeansPoweredDown() {
        let idle: [(name: String, celsius: Double)] = [("GPU MTR Temp Sensor1", 30), ("GPU MTR Temp Sensor4", 30)]
        #expect(ThermalMath.hottest(idle, in: .gpu) == nil)
        let busy: [(name: String, celsius: Double)] = [("GPU MTR Temp Sensor1", 30), ("GPU MTR Temp Sensor4", 35.4)]
        #expect(ThermalMath.hottest(busy, in: .gpu) == 35.4)
    }

    @Test func fanAtZeroIsOff() {
        #expect(!FanReading(rpm: 0, minimumRPM: 1_199, maximumRPM: 7_199).isRunning)
        #expect(FanReading(rpm: 1_228, minimumRPM: 1_199, maximumRPM: 7_199).isRunning)
    }
}

/// Talks to the real sensors, SMC and GPU of the Mac running the tests.
@Suite struct ThermalGPUHardwareTests {
    @Test func readsChipSensorsAndFanCount() throws {
        let smc = try #require(SMCReader(), "AppleSMC is part of every Apple Silicon Mac")
        let fans = try #require(smc.value("FNum"))
        #expect(fans >= 0 && fans <= 8)
        #expect(smc.value("NoSuchKey") == nil)
        let sensors = try #require(HIDTemperatureSensors(include: { _ in true }))
        #expect(!sensors.names.isEmpty)
        #expect(sensors.read().contains { ThermalMath.plausible.contains($0.celsius) })
    }

    @Test func killSwitchesLeaveNoData() {
        let snapshot = ThermalSampler(allowHIDSensors: false, allowSMC: false).sample()
        #expect(!snapshot.hasSensors)
        #expect(snapshot.cpu == nil)
        #expect(snapshot.fans.isEmpty)
    }

    @Test func gpuUtilizationIsAShare() throws {
        let gpu = try #require(GPUSampler().sample())
        #expect((0...1).contains(gpu.utilization))
        #expect((gpu.coreCount ?? 0) > 0)
    }
}

@Suite struct ProcessMathTests {
    private func reading(_ pid: pid_t, cpu: UInt64, memory: UInt64) -> ProcessReading {
        ProcessReading(identity: ProcessIdentity(pid: pid, started: 1), cpuTime: cpu, memory: memory)
    }

    @Test func groupsHelpersUnderTheirAppAndKeepsTheSums() {
        let app = ProcessIdentity(pid: 10, started: 1)
        let readings = [
            reading(10, cpu: 3_000, memory: 100), reading(11, cpu: 5_000, memory: 50),
            reading(20, cpu: 1_000, memory: 7),
        ]
        let previous =
            [app: 1_000, ProcessIdentity(pid: 11, started: 1): 1_000, ProcessIdentity(pid: 20, started: 1): 1_000]
            as [ProcessIdentity: UInt64]
        let rows = ProcessMath.rows(readings, previous: previous, elapsedNanoseconds: 10_000) { identity in
            identity.pid == 11 ? app : identity
        }
        let grouped = rows.first { $0.identity == app }
        #expect(grouped?.processCount == 2)
        #expect(grouped?.memory == 150)
        // (2000 + 4000) ns of CPU in 10000 ns: 0.6 of one core.
        #expect(abs((grouped?.cpu ?? 0) - 0.6) < 1e-12)
        #expect(rows.reduce(0) { $0 + $1.memory } == 157, "Grouping must not lose or double anything")
    }

    @Test func newProcessHasNoRateYet() {
        let rows = ProcessMath.rows([reading(5, cpu: 9_000, memory: 1)], previous: [:], elapsedNanoseconds: 1_000) {
            $0
        }
        #expect(rows.first?.cpu == 0)
    }

    @Test func searchCoversEveryRowAndEqualValuesKeepTheirOrder() {
        let rows = [("Safari", 0.1), ("Mail", 0.3), ("Safari Helper", 0.3), ("Notes", 0)].enumerated().map {
            index, row in
            ProcessUsage(
                identity: ProcessIdentity(pid: pid_t(10 - index), started: 1), name: row.0, cpu: row.1,
                memory: UInt64(index + 1), processCount: 1)
        }
        let snapshot = ProcessesSnapshot(rows: rows, visibleCount: 4, hiddenCount: 0)
        // Equal CPU (0.3): the lower PID first, every time.
        #expect(snapshot.top(.cpu, limit: 5).map(\.name) == ["Safari Helper", "Mail", "Safari"])
        #expect(
            snapshot.top(.cpu, limit: 5) { $0.name.localizedStandardContains("safari") }.map(\.name) == [
                "Safari Helper", "Safari",
            ])
        #expect(snapshot.top(.memory, limit: 1).map(\.name) == ["Notes"])
    }

    @Test func topDropsIdleRowsAndSorts() {
        let rows = [0.2, 0, 0.9, 0.5].enumerated().map { index, cpu in
            ProcessUsage(
                identity: ProcessIdentity(pid: pid_t(index + 2), started: 1), name: "", cpu: cpu, memory: 0,
                processCount: 1)
        }
        #expect(ProcessMath.top(rows, by: \.cpu, limit: 2).map(\.cpu) == [0.9, 0.5])
    }
}

/// Starts and ends real child processes.
@Suite struct ProcessInspectorTests {
    @Test func signalsOnlyTheSameOwnProcess() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let identity = try #require(ProcessInspector.identity(of: child.processIdentifier))
        #expect(ProcessInspector.canSignal(identity))
        // A recycled PID has another start time: refused.
        let recycled = ProcessIdentity(pid: identity.pid, started: identity.started + 1)
        #expect(!ProcessInspector.canSignal(recycled))
        #expect(!ProcessInspector.send(SIGTERM, to: recycled))
        #expect(child.isRunning)
        #expect(ProcessInspector.send(SIGTERM, to: identity))
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
        #expect(!ProcessInspector.canSignal(identity), "Gone processes cannot be signalled")
    }

    @Test func refusesSelfLaunchdAndOtherUsers() throws {
        let me = try #require(ProcessInspector.identity(of: getpid()))
        #expect(!ProcessInspector.canSignal(me))
        #expect(!ProcessInspector.canSignal(ProcessIdentity(pid: 1, started: 0)))
        // macOS 27 hides other users' processes, older systems show them:
        // either way none of them may ever be signalled.
        let (readings, hidden) = ProcessSampler().readAll()
        let foreign = readings.filter { ProcessInspector.userID(of: $0.identity.pid) != getuid() }
        for reading in foreign {
            #expect(
                !ProcessInspector.canSignal(reading.identity), "pid \(reading.identity.pid) belongs to another user")
        }
        #expect(!readings.isEmpty)
        #expect(hidden >= 0)
    }
}
