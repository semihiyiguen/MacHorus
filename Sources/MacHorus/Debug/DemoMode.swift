// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusMonitor
import MacHorusTools

/// Fixed, neutral sample data for screenshots and demos (`-debug.demo YES`,
/// launch argument only): the process list, per-app network, audio device
/// names and the computer name come from here instead of this Mac, so a
/// screenshot shows no personal apps, names or addresses. Every other value
/// (CPU, memory, disk, temperatures …) is still measured live.
enum DemoMode {
    static let isOn = UserDefaults.standard.bool(forKey: "debug.demo")
    static let computerName = "MacBook Pro"

    private struct App {
        let name: String
        /// Where its icon comes from (apps that ship with macOS); nil: a tool.
        let bundle: String?
        let cpu: Double
        let memoryMB: Double
        let processes: Int
        let cpuMinutes: Double
        let downKBs: Double
        let upKBs: Double
        let downTotalMB: Double
    }

    private static let apps: [App] = [
        App(
            name: "Safari", bundle: "/Applications/Safari.app", cpu: 0.21, memoryMB: 1_840, processes: 9,
            cpuMinutes: 96, downKBs: 412, upKBs: 38, downTotalMB: 2_310),
        App(
            name: "Photos", bundle: "/System/Applications/Photos.app", cpu: 0.14, memoryMB: 690, processes: 3,
            cpuMinutes: 41, downKBs: 0, upKBs: 0, downTotalMB: 12),
        App(
            name: "Music", bundle: "/System/Applications/Music.app", cpu: 0.07, memoryMB: 320, processes: 2,
            cpuMinutes: 18, downKBs: 96, upKBs: 2, downTotalMB: 840),
        App(
            name: "Mail", bundle: "/System/Applications/Mail.app", cpu: 0.03, memoryMB: 455, processes: 4,
            cpuMinutes: 12, downKBs: 6, upKBs: 1, downTotalMB: 186),
        App(
            name: "Messages", bundle: "/System/Applications/Messages.app", cpu: 0.02, memoryMB: 268, processes: 2,
            cpuMinutes: 6, downKBs: 3, upKBs: 1, downTotalMB: 64),
        App(
            name: "Notes", bundle: "/System/Applications/Notes.app", cpu: 0.01, memoryMB: 184, processes: 2,
            cpuMinutes: 3, downKBs: 0, upKBs: 0, downTotalMB: 9),
        App(
            name: "Finder", bundle: "/System/Library/CoreServices/Finder.app", cpu: 0.01, memoryMB: 152,
            processes: 1, cpuMinutes: 9, downKBs: 0, upKBs: 0, downTotalMB: 2),
        App(
            name: "Preview", bundle: "/System/Applications/Preview.app", cpu: 0.005, memoryMB: 121, processes: 1,
            cpuMinutes: 1, downKBs: 0, upKBs: 0, downTotalMB: 0),
        App(
            name: "mds_stores", bundle: nil, cpu: 0.04, memoryMB: 88, processes: 1, cpuMinutes: 22, downKBs: 0,
            upKBs: 0, downTotalMB: 0),
        App(
            name: "softwareupdated", bundle: nil, cpu: 0.01, memoryMB: 46, processes: 1, cpuMinutes: 2,
            downKBs: 54, upKBs: 1, downTotalMB: 1_120),
    ]

    private static func pid(_ index: Int) -> pid_t { pid_t(90_001 + index) }
    private static func identity(_ index: Int) -> ProcessIdentity { ProcessIdentity(pid: pid(index), started: 1) }

    static func processes() -> ProcessesSnapshot {
        let rows = apps.enumerated().map { index, app in
            ProcessUsage(
                identity: identity(index), name: app.name, cpu: app.cpu,
                memory: UInt64(app.memoryMB * 1_000_000), processCount: app.processes, cpuSeconds: app.cpuMinutes * 60,
                peakMemory: UInt64(app.memoryMB * 1_350_000))
        }
        let owners = Dictionary(uniqueKeysWithValues: apps.indices.map { (pid($0), identity($0)) })
        return ProcessesSnapshot(rows: rows, visibleCount: 412, hiddenCount: 0, owners: owners)
    }

    static func icon(for pid: pid_t) -> NSImage? {
        guard isOn else { return nil }
        let index = Int(pid) - 90_001
        guard apps.indices.contains(index), let bundle = apps[index].bundle else { return nil }
        return NSWorkspace.shared.icon(forFile: bundle)
    }

    static func trafficNow() -> [AppTraffic.Use] {
        apps.enumerated().compactMap { index, app in
            guard app.downKBs > 0 || app.upKBs > 0 else { return nil }
            let rate = NetworkUse(directIn: app.downKBs * 1_000, directOut: app.upKBs * 1_000)
            return AppTraffic.Use(pid: pid(index), name: app.name, use: rate, bytes: rate)
        }
    }

    static func trafficTotals() -> [pid_t: (name: String, bytes: NetworkUse)] {
        var totals: [pid_t: (name: String, bytes: NetworkUse)] = [:]
        for (index, app) in apps.enumerated() where app.downTotalMB > 0 {
            totals[pid(index)] = (
                app.name, NetworkUse(directIn: app.downTotalMB * 1_000_000, directOut: app.downTotalMB * 40_000)
            )
        }
        return totals
    }

    /// Neutral device names in place of this Mac's (which may carry a
    /// person's name, e.g. "…'s AirPods").
    static func devices(_ outputs: [AudioDevice], _ inputs: [AudioDevice]) -> ([AudioDevice], [AudioDevice]) {
        let outputNames = ["MacBook Pro Speakers", "AirPods Pro", "Studio Display Speakers"]
        let inputNames = ["MacBook Pro Microphone", "AirPods Pro", "Studio Display Microphone"]
        func rename(_ devices: [AudioDevice], _ names: [String]) -> [AudioDevice] {
            devices.enumerated().map { index, device in
                AudioDevice(id: device.id, name: index < names.count ? names[index] : "USB Audio \(index)")
            }
        }
        return (rename(outputs, outputNames), rename(inputs, inputNames))
    }
}
