// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation
import MacHorusCore
import MacHorusTools
import Observation

/// Switches the Mac's sound output and input (headset ↔ speakers) like
/// Control Center. Listens to CoreAudio only while the audio box shows.
@MainActor
@Observable
final class AudioDeviceController {
    var isEnabled = false
    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var output: AudioObjectID?
    private(set) var input: AudioObjectID?
    /// Level of the current output (0…1); nil when it has none to set.
    private(set) var volume: Float?
    private(set) var isOutputMuted = false

    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private let refresher = SerialRefresh()
    /// A read right after the slider moved could show the old level.
    @ObservationIgnored private var lastWrite = Date.distantPast

    /// The box appeared: read now and follow changes until `stopWatching`.
    func startWatching() {
        watchers += 1
        refresh()
        guard listener == nil else { return }
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.refresh() }
        // CoreAudio calls back on the main queue.
        listener = AudioDevices.observe { MainActor.assumeIsolated { changed() } }
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0, let listener else { return }
        AudioDevices.stopObserving(listener)
        self.listener = nil
    }

    func select(_ id: AudioObjectID, _ direction: AudioDevices.Direction) {
        if !AudioDevices.setDefault(id, direction) {
            Log.features.error("Audio device \(id, privacy: .public) could not become the default")
        }
        refresh()
    }

    /// The whole Mac's level, as the volume keys set it.
    func setVolume(_ level: Float) {
        guard let output else { return }
        lastWrite = Date()
        volume = level
        if level > 0 { isOutputMuted = false }
        AudioDevices.setVolume(level, output)
    }

    func toggleOutputMute() {
        guard let output else { return }
        lastWrite = Date()
        isOutputMuted.toggle()
        AudioDevices.setMuted(isOutputMuted, output)
    }

    /// Reads the level again (volume keys change it without a notice here).
    func refreshVolume() {
        refresh()
    }

    private func refresh() {
        refresher.run { [weak self] in
            let read = await OffMain.run {
                (
                    AudioDevices.list(.output), AudioDevices.list(.input), AudioDevices.defaultDevice(.output),
                    AudioDevices.defaultDevice(.input)
                )
            }
            let level = await OffMain.run { () -> (Float?, Bool) in
                guard let device = read.2 else { return (nil, false) }
                return (AudioDevices.volume(device), AudioDevices.isMuted(device) ?? false)
            }
            guard let self else { return }
            let named = DemoMode.isOn ? DemoMode.devices(read.0, read.1) : (read.0, read.1)
            if named.0 != outputs { outputs = named.0 }
            if named.1 != inputs { inputs = named.1 }
            if read.2 != output { output = read.2 }
            if read.3 != input { input = read.3 }
            guard Date().timeIntervalSince(lastWrite) > 1 else { return }
            if level.0 != volume { volume = level.0 }
            if level.1 != isOutputMuted { isOutputMuted = level.1 }
        }
    }
}

@MainActor
final class AudioDeviceFeature: FeatureModule {
    private let controller: AudioDeviceController

    init(controller: AudioDeviceController) {
        self.controller = controller
    }

    func start() { controller.isEnabled = true }
    func stop() { controller.isEnabled = false }

    static func register(in registry: FeatureRegistry, controller: AudioDeviceController) {
        registry.register(FeatureDescriptor(id: "audio.devices", category: .audio)) {
            AudioDeviceFeature(controller: controller)
        }
    }
}
