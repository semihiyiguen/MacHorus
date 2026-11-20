// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation
import MacHorusCore
import MacHorusMonitor
import MacHorusTools
import Observation

/// "Mute all microphones": every input device, also ones plugged in while
/// muted (headsets, webcams). Switching off, quitting MacHorus or switching
/// the feature off restores the devices exactly as they were, so a
/// forgotten mute never outlives the app.
///
/// What MacHorus silenced is kept by device UID (stable across unplugging
/// and restarts) and saved, so a device unplugged while muted, or a crash,
/// is restored as soon as the device is back.
@MainActor
@Observable
final class MicrophoneController {
    /// Device UID → input volume to restore, or -1: unmute.
    static let recoveryKey = "microphonesSilencedByMacHorus"

    var isEnabled = false
    private(set) var isMuted = false
    /// Input devices as last read (refreshed when the panel shows them).
    private(set) var microphones: [Microphone] = []
    /// Apps that use a microphone / play sound right now (no permission needed).
    private(set) var inputUsers: [String] = []
    private(set) var outputUsers: [String] = []
    @ObservationIgnored var responsibility: ProcessResponsibility?

    @ObservationIgnored private var owned: [String: Double] = [:] {
        didSet {
            if owned.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            } else {
                UserDefaults.standard.set(owned, forKey: Self.recoveryKey)
            }
        }
    }
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var changeHandlers: [@MainActor () -> Void] = []
    @ObservationIgnored private let refresher = SerialRefresh()

    init() {
        owned = UserDefaults.standard.dictionary(forKey: Self.recoveryKey) as? [String: Double] ?? [:]
        if !owned.isEmpty {
            Log.features.notice("Microphones to restore after an unexpected end: \(self.owned.count, privacy: .public)")
            restorePresent()
        }
    }

    func onChange(_ handler: @escaping @MainActor () -> Void) {
        changeHandlers.append(handler)
    }

    /// Re-reads the input devices: on appearing, on device changes and
    /// after a mute (their state changes only then).
    func refresh() {
        refresher.run { [weak self] in
            let (read, processes) = await OffMain.run { (Microphones.list(), AudioProcesses.list()) }
            guard let self else { return }
            if read != microphones { microphones = read }
            updateUsers(AudioApps.group(processes, responsibility: responsibility))
        }
    }

    /// Who uses a microphone or plays sound, from apps grouped once per tick.
    func updateUsers(_ apps: [AudioApp]) {
        let users = AudioApps.users(of: apps)
        if users.input != inputUsers { inputUsers = users.input }
        if users.output != outputUsers { outputUsers = users.output }
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted {
            silenceAll()
            Log.features.notice("Microphones muted: \(self.owned.count, privacy: .public) devices")
        } else {
            restorePresent()
            Log.features.notice("Microphones restored")
        }
        notify()
    }

    /// While muted, devices that come back or come new are muted too; while
    /// not muted, devices MacHorus still owes a restore are restored.
    private func devicesChanged() {
        isMuted ? silenceAll() : restorePresent()
    }

    private func silenceAll() {
        for microphone in Microphones.list() {
            guard let uid = microphone.uid else { continue }
            if owned[uid] != nil {
                // Ours from before (unplugged and back): make sure it is silent.
                if !microphone.isSilent { silence(microphone, uid: uid) }
                continue
            }
            // Already silent by the user's choice: not ours to restore.
            guard !microphone.isSilent else { continue }
            silence(microphone, uid: uid)
        }
        refresh()
        updateListener()
    }

    private func silence(_ microphone: Microphone, uid: String) {
        var volumes: [AudioObjectID: Float32] = [:]
        guard Microphones.silence(microphone.id, saving: &volumes) else {
            Log.features.error("Microphone \(microphone.name, privacy: .public) could not be muted")
            return
        }
        if owned[uid] == nil { owned[uid] = volumes[microphone.id].map { Double($0) } ?? -1 }
    }

    /// Restores every owned device that is present; absent ones stay owed.
    private func restorePresent() {
        for microphone in Microphones.list() {
            guard let uid = microphone.uid, let volume = owned[uid] else { continue }
            Microphones.restore(microphone.id, volumes: volume >= 0 ? [microphone.id: Float32(volume)] : [:])
            owned[uid] = nil
        }
        refresh()
        updateListener()
    }

    /// Listens for device changes only while muted or while a restore is owed.
    private func updateListener() {
        let needed = isMuted || !owned.isEmpty
        if needed, deviceListener == nil {
            let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.devicesChanged() }
            // CoreAudio calls back on the main queue.
            deviceListener = Microphones.observeDevices { MainActor.assumeIsolated { changed() } }
        } else if !needed, let deviceListener {
            Microphones.stopObserving(deviceListener)
            self.deviceListener = nil
        }
    }

    /// Microphones that are still live while the mute is on (no control).
    var unmutable: [Microphone] { isMuted ? microphones.filter { !$0.isSilent } : [] }

    private func notify() {
        for handler in changeHandlers { handler() }
    }
}

@MainActor
final class MicrophoneFeature: FeatureModule {
    private let controller: MicrophoneController

    init(controller: MicrophoneController) {
        self.controller = controller
    }

    func start() { controller.isEnabled = true }

    func stop() {
        controller.setMuted(false)
        controller.isEnabled = false
    }

    static func register(in registry: FeatureRegistry, controller: MicrophoneController) {
        registry.register(FeatureDescriptor(id: "audio.micMute", category: .audio)) {
            MicrophoneFeature(controller: controller)
        }
    }
}
