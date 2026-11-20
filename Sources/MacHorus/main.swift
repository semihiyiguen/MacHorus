// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import CoreAudio
import MacHorusCore
import MacHorusMonitor
import MacHorusTools

// German by default, English on request (settings); before any text.
AppLanguage.applyAtLaunch()

// Verification mode: `MacHorus --print-monitor [rounds]` prints the monitor's
// readings and exits (used by scripts/dev/verify-monitor.py). The policy
// applies here too; `--interface-counters` forces the network fallback,
// `--processes-ungrouped` lists every process on its own row.
if let index = CommandLine.arguments.firstIndex(of: "--print-monitor") {
    let next = CommandLine.arguments.index(after: index)
    let rounds = next < CommandLine.arguments.endIndex ? Int(CommandLine.arguments[next]) ?? 3 : 3
    var privateAPIs = Set(PrivateAPI.allCases).filter(PolicyLoader.load().allows)
    if CommandLine.arguments.contains("--interface-counters") { privateAPIs.remove(.networkStatistics) }
    if CommandLine.arguments.contains("--processes-ungrouped") { privateAPIs.remove(.processResponsibility) }
    MonitorProbe.run(rounds: rounds, interval: 1, privateAPIs: privateAPIs) { snapshot in
        print(MonitorProbe.line(snapshot))
        fflush(stdout)
    }
    exit(0)
}

// `MacHorus --benchmark-samplers [rounds] [name]` prints the CPU time per
// sampler call, optionally of one sampler only.
if let index = CommandLine.arguments.firstIndex(of: "--benchmark-samplers") {
    let rest = CommandLine.arguments[CommandLine.arguments.index(after: index)...]
    let rounds = rest.first.flatMap(Int.init) ?? 20
    let only = rest.dropFirst().first
    for line in MonitorProbe.benchmark(rounds: rounds, only: only) { print(line) }
    exit(0)
}

// `MacHorus --print-sensors` lists every temperature sensor and fan value.
if CommandLine.arguments.contains("--print-sensors") {
    for line in MonitorProbe.sensorListing() { print(line) }
    exit(0)
}

// `MacHorus --network-check` runs the network check once and prints each
// step (it connects to captive.apple.com, as the button does).
if CommandLine.arguments.contains("--network-check") {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let result = await NetworkCheck.run()
        for step in NetworkCheck.Step.allCases {
            print("\(step.rawValue): \(result.outcomes[step].map { String(describing: $0) } ?? "-")")
        }
        print("interface: \(result.interface ?? "-"), router: \(result.router ?? "-"), vpn: \(result.vpnInterfaces)")
        print("verdict: \(result.verdict)")
        done.signal()
    }
    done.wait()
    exit(0)
}

// `MacHorus --print-devices`: drives, USB devices, power adapter, printers
// and print jobs as the tools page reads them, with the time each took.
if CommandLine.arguments.contains("--print-devices") {
    func timed<T>(_ label: String, _ read: () -> T) -> T {
        let start = DispatchTime.now()
        let value = read()
        print("\(label): \((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) ms")
        return value
    }
    for drive in timed("drives", ConnectedDevices.externalDrives) { print("  drive: \(drive.name)") }
    for device in timed("usb", ConnectedDevices.usbDevices) { print("  usb: \(device.name) hub=\(device.isHub)") }
    print("  adapter: \(String(describing: timed("adapter", ConnectedDevices.powerAdapter)))")
    for printer in timed("printers", PrintQueue.printers) {
        print("  printer: \(printer.displayName) stopped=\(printer.isStopped) \(printer.reasons)")
    }
    for job in timed("jobs", PrintQueue.jobs) { print("  job: \(job.id) \(job.printer) \(job.state)") }
    exit(0)
}

// Verification modes for the tools (scripts/dev/verify-tools.py compares
// them with the system's own tools): `--print-updates`,
// `--print-ports`, `--print-microphones`, `--print-audio-devices`;
// `--set-audio-device output|input <id>` switches like the audio box does.
// `--print-diagnosis` prints a diagnosis for bug reports from
// one fresh round, without the app running; settings are only read.
if CommandLine.arguments.contains("--print-diagnosis") {
    let privateAPIs = Set(PrivateAPI.allCases).filter(PolicyLoader.load().allows)
    let hardware = HardwareCapabilities.probe(
        allowHIDSensors: privateAPIs.contains(.hidSensors), allowSMC: privateAPIs.contains(.smc))
    var round: MonitorSnapshot?
    MonitorProbe.run(rounds: 1, interval: 1, privateAPIs: privateAPIs) { round = $0 }
    var metrics: Set<Metric> = [.cpu, .memory, .disk, .network, .processes]
    if hardware.hasGPUStatistics { metrics.insert(.gpu) }
    if hardware.hasThermalReadings { metrics.insert(.thermal) }
    if hardware.hasBattery { metrics.insert(.power) }
    let version = AppIdentity.currentVersion().description
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    print(
        Diagnosis.text(
            DiagnosisFacts(
                app: "\(version) (\(build))", mac: .current, architecture: "command line", capabilities: hardware,
                allowedPrivateAPIs: privateAPIs.map(\.rawValue), enabledMetrics: metrics, cpu: round?.cpu,
                memory: round?.memory, disk: round?.disk, network: round?.network, battery: round?.battery,
                thermal: round?.thermal, gpu: round?.gpu,
                anomalies: round.map { r in Plausibility.check(r).map { (date: r.date, anomaly: $0) } } ?? [],
                features: UserDefaults.standard.stringArray(forKey: SettingsStore.Key.enabledFeatures) ?? [],
                schema: UserDefaults.standard.integer(forKey: SettingsStore.Key.schemaVersion), now: Date())))
    exit(0)
}
if CommandLine.arguments.contains("--print-updates") {
    let updates = SoftwareUpdates.read() ?? SoftwareUpdates.appleUpdatesOnly()
    for item in updates.munkiItems {
        print("munki=\(item.name)|\(item.version ?? "-")|\(item.isRemoval ? "remove" : "install")|\(item.restart)")
    }
    for item in updates.appleUpdates { print("apple=\(item.name)|\(item.version ?? "-")") }
    for name in updates.problemItems { print("problem=\(name)") }
    print("lastCheck=\(updates.lastCheck.map { String(Int($0.timeIntervalSince1970)) } ?? "-")")
    exit(0)
}
if CommandLine.arguments.contains("--print-ports") {
    for port in ListeningPorts.read() {
        print("port=\(port.port)|\(port.identity.pid)|\(port.processName)|\(port.isLoopbackOnly ? "local" : "network")")
    }
    exit(0)
}
if CommandLine.arguments.contains("--print-audio") {
    for process in AudioProcesses.list() {
        print("audio=\(process.pid)|\(process.bundleID ?? "-")|input=\(process.usesInput)|output=\(process.usesOutput)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--print-microphones") {
    for microphone in Microphones.list() {
        let control = microphone.control.map { "\($0)" } ?? "none"
        print("microphone=\(microphone.id)|\(microphone.name)|silent=\(microphone.isSilent)|control=\(control)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--print-audio-devices") {
    for (label, direction) in [("output", AudioDevices.Direction.output), ("input", .input)] {
        let current = AudioDevices.defaultDevice(direction)
        for device in AudioDevices.list(direction) {
            print("\(label)=\(device.id)|\(device.name)|default=\(device.id == current)")
        }
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--set-audio-device"), CommandLine.arguments.count > index + 2,
    let id = AudioObjectID(CommandLine.arguments[index + 2])
{
    let direction: AudioDevices.Direction = CommandLine.arguments[index + 1] == "input" ? .input : .output
    let ok = AudioDevices.setDefault(id, direction)
    print("set=\(ok)")
    exit(ok ? 0 : 1)
}

// Debug flags (`debug.*`) act only as launch arguments. Written with
// `defaults write` they would act on every launch (quit after a check, mute
// the microphones, write trace files), so persistent ones are removed here;
// the argument domain is not touched.
do {
    let defaults = UserDefaults.standard
    let stored = defaults.persistentDomain(forName: AppIdentity.bundleIdentifier) ?? [:]
    for key in stored.keys where key.hasPrefix("debug.") {
        defaults.removeObject(forKey: key)
    }
}

// Menu bar agent: no Dock icon, no main window (LSUIElement in Info.plist).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
