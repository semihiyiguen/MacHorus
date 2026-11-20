// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import CoreAudio
import MacHorusMonitor
import MacHorusTools

/// One app as the audio tools show it: all its audio processes together
/// (a browser's helpers belong to the browser).
struct AudioApp: Identifiable, Equatable {
    /// The app's bundle identifier, or the process name; volumes are kept by it.
    let id: String
    let name: String
    /// The app's own process, for its icon.
    let pid: pid_t
    var objects: [AudioObjectID]
    var usesInput: Bool
    var usesOutput: Bool
    /// A regular app (Dock icon); others are listed only while they play.
    let isRegularApp: Bool
}

@MainActor
enum AudioApps {
    /// Who a process belongs to; looked up once per process (by PID and
    /// object), since asking for the app every 2 s cost measurable time.
    private struct Owner {
        let id: String
        let name: String
        let pid: pid_t
        let isRegularApp: Bool
    }

    private static var owners: [AudioObjectID: (pid: pid_t, owner: Owner)] = [:]

    /// Groups audio processes by their app. MacHorus' own playback (the
    /// mixer's devices) is left out, so it never taps itself.
    static func group(_ processes: [AudioProcess], responsibility: ProcessResponsibility?) -> [AudioApp] {
        var byID: [String: AudioApp] = [:]
        var order: [String] = []
        var seen = Set<AudioObjectID>()
        for process in processes where process.pid != getpid() {
            seen.insert(process.objectID)
            let owner = owner(of: process, responsibility: responsibility)
            let id = owner.id
            if var existing = byID[id] {
                existing.objects.append(process.objectID)
                existing.usesInput = existing.usesInput || process.usesInput
                existing.usesOutput = existing.usesOutput || process.usesOutput
                byID[id] = existing
            } else {
                order.append(id)
                byID[id] = AudioApp(
                    id: id, name: owner.name, pid: owner.pid, objects: [process.objectID],
                    usesInput: process.usesInput, usesOutput: process.usesOutput, isRegularApp: owner.isRegularApp)
            }
        }
        owners = owners.filter { seen.contains($0.key) }
        return order.compactMap { byID[$0] }
    }

    private static func owner(of process: AudioProcess, responsibility: ProcessResponsibility?) -> Owner {
        if let cached = owners[process.objectID], cached.pid == process.pid { return cached.owner }
        let ownerPID = responsibility?.owner(of: process.pid) ?? process.pid
        let app =
            NSRunningApplication(processIdentifier: ownerPID) ?? NSRunningApplication(processIdentifier: process.pid)
        // Id and name come from the same owner, so a stored level always
        // belongs to the row that shows it.
        let owner = Owner(
            id: app?.bundleIdentifier ?? process.bundleID ?? ProcessInspector.name(of: ownerPID),
            name: app?.localizedName ?? ProcessInspector.name(of: ownerPID), pid: app?.processIdentifier ?? ownerPID,
            isRegularApp: app?.activationPolicy == .regular)
        owners[process.objectID] = (process.pid, owner)
        return owner
    }

    /// Names of the apps that use a microphone or play sound right now.
    static func users(of apps: [AudioApp]) -> (input: [String], output: [String]) {
        (apps.filter(\.usesInput).map(\.name).sorted(), apps.filter(\.usesOutput).map(\.name).sorted())
    }
}
