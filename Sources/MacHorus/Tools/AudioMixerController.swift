// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation
import MacHorusCore
import MacHorusMonitor
import MacHorusTools
import Observation

/// Sound per app: turn single apps down or off. A process tap exists
/// only for an app that is muted or below 100 %; at 100 % the app plays
/// untouched and MacHorus does nothing at all. Off by default; macOS asks for
/// "System Audio Recording" at the first tap.
@MainActor
@Observable
final class AudioMixerController {
    static let volumesKey = "mixerVolumes"
    /// Below this a volume counts as turned down; above, as 100 %.
    static let unity: Float = 0.995
    /// At or below: silence (the tap plays nothing).
    static let silent: Float = 0.005

    var isEnabled = false
    /// Apps with an audio session: playing ones first, then by name.
    private(set) var apps: [AudioApp] = []
    /// Remembered levels below 100 %, by app id. Read as numbers of any
    /// width: a level stored as Double does not cast to Float, and every
    /// level would be lost.
    private(set) var volumes: [String: Float] = AudioMixerController.storedVolumes()
    /// Muted until unmuted or MacHorus ends; not remembered across launches.
    private(set) var muted: Set<String> = []
    /// Apps whose tap failed (no consent, or the device stopped rendering);
    /// they play unchanged until the user moves their control again.
    private(set) var failed: Set<String> = []
    /// What the last tap showed about consent (SystemAudioAccess values);
    /// nil while macOS has not been asked. Mirrors the stored value so the
    /// box updates when it changes.
    private(set) var access: String? = UserDefaults.standard.string(forKey: SystemAudioAccess.key)
    /// A consent request is running (the macOS dialog may be open).
    private(set) var isAsking = false

    @ObservationIgnored let responsibility: ProcessResponsibility?
    @ObservationIgnored private var engines: [String: AppAudioTap] = [:]
    @ObservationIgnored private let refresher = SerialRefresh()
    /// Increments per app on every request; a build that finishes late is
    /// dropped instead of adding a second tap.
    @ObservationIgnored private var tokens: [String: Int] = [:]
    @ObservationIgnored private var listListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastCycles: [String: UInt64] = [:]
    /// Rebuilds after a stalled volume tap; the sound goes back to the app
    /// only after the second one in a row (a device change usually explains
    /// the first: headset unplugged, output switched).
    @ObservationIgnored private var stallRebuilds: [String: Int] = [:]
    @ObservationIgnored private let buildQueue = DispatchQueue(label: "app.machorus.mixer.build", qos: .userInitiated)

    static func storedVolumes() -> [String: Float] {
        let stored = UserDefaults.standard.dictionary(forKey: volumesKey) ?? [:]
        return stored.compactMapValues { value in
            guard let level = (value as? NSNumber)?.floatValue, level >= 0, level < unity else { return nil }
            return level
        }
    }

    init(responsibility: ProcessResponsibility?) {
        self.responsibility = responsibility
    }

    // MARK: Lifecycle

    func start() {
        isEnabled = true
        if listListener == nil {
            let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.refresh() }
            listListener = AudioProcesses.observeList { MainActor.assumeIsolated { changed() } }
            let deviceChanged: @MainActor @Sendable () -> Void = { [weak self] in self?.outputDeviceChanged() }
            deviceListener = Self.observeDefaultOutput { MainActor.assumeIsolated { deviceChanged() } }
        }
        refresh()
    }

    /// Gives every app its sound back and stops listening.
    func stop() {
        isEnabled = false
        if let listListener { AudioProcesses.stopObservingList(listListener) }
        if let deviceListener { Self.stopObservingDefaultOutput(deviceListener) }
        listListener = nil
        deviceListener = nil
        for engine in engines.values { engine.stop() }
        engines = [:]
        tokens = [:]
        muted = []
        failed = []
        updateWatchdog()
    }

    /// Re-reads the apps; called on audio session changes and while the card shows.
    func refresh() {
        guard isEnabled else { return }
        refresher.run { [weak self] in
            let processes = await OffMain.run { AudioProcesses.list() }
            guard let self else { return }
            refresh(with: AudioApps.group(processes, responsibility: responsibility))
        }
    }

    /// With apps another reader already grouped this tick.
    func refresh(with grouped: [AudioApp]) {
        guard isEnabled else { return }
        let shown = grouped.filter { $0.isRegularApp || $0.usesOutput || engines[$0.id] != nil }
            .sorted { ($0.usesOutput ? 0 : 1, $0.name.lowercased()) < ($1.usesOutput ? 0 : 1, $1.name.lowercased()) }
        if shown != apps { apps = shown }
        for app in grouped { reconcile(app) }
        // Apps that are gone need no tap.
        for id in engines.keys where !grouped.contains(where: { $0.id == id }) { discard(id) }
    }

    // MARK: Controls

    func volume(of id: String) -> Float { volumes[id] ?? 1 }

    func setVolume(_ value: Float, for id: String) {
        let clamped = min(max(value, 0), 1)
        volumes[id] = clamped < Self.unity ? clamped : nil
        UserDefaults.standard.set(volumes, forKey: Self.volumesKey)
        failed.remove(id)
        if let app = apps.first(where: { $0.id == id }) { reconcile(app) }
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        failed.remove(id)
        if let app = apps.first(where: { $0.id == id }) { reconcile(app) }
    }

    // MARK: Engines

    /// A mute is a level of 0: only a tap that is being read keeps the app's
    /// sound from the speakers. A tap that only mutes and is never read did
    /// nothing audible (ear test 2026-11-11: a 0-gain read tap went silent,
    /// the idle mute tap did not; YouTube at 0 % and Moonlight muted played on).
    private enum Desired: Equatable {
        case none
        case volume(Float)
    }

    private func desired(for id: String) -> Desired {
        if failed.contains(id) { return .none }
        if muted.contains(id) { return .volume(0) }
        let level = volume(of: id)
        if level <= Self.silent { return .volume(0) }
        return level < Self.unity ? .volume(level) : .none
    }

    private func reconcile(_ app: AudioApp) {
        let want = desired(for: app.id)
        let engine = engines[app.id]
        switch want {
        case .none:
            if engine != nil { discard(app.id) }
            return
        case .volume(let level):
            if let engine, engine.outputDeviceUID != nil, Set(engine.objects) == Set(app.objects),
                engine.outputDeviceUID == AppAudioTap.defaultOutputDeviceUID()
            {
                if engine.gain != level { trace("gain \(level) for \(app.id)") }
                engine.gain = level
                return
            }
        }
        build(app, want)
    }

    /// Builds off the main thread: the first tap can wait on the consent dialog.
    private func build(_ app: AudioApp, _ want: Desired) {
        let token = (tokens[app.id] ?? 0) + 1
        tokens[app.id] = token
        let objects = app.objects
        let id = app.id
        let output = AppAudioTap.defaultOutputDeviceUID()
        let finished: @MainActor @Sendable (Result<AppAudioTap, AppAudioTap.Failure>) -> Void = { [weak self] result in
            self?.install(result, for: id, token: token, want: want)
        }
        buildQueue.async {
            let result: Result<AppAudioTap, AppAudioTap.Failure>
            do throws(AppAudioTap.Failure) {
                switch want {
                case .volume(let level):
                    guard let output else { throw AppAudioTap.Failure.setupFailed(kAudioHardwareBadDeviceError) }
                    result = .success(try AppAudioTap(objects: objects, gain: level, outputDeviceUID: output))
                case .none: return
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { finished(result) } }
        }
    }

    private func install(_ result: Result<AppAudioTap, AppAudioTap.Failure>, for id: String, token: Int, want: Desired)
    {
        // A newer request, a stop or a changed wish makes this build stale.
        guard isEnabled, tokens[id] == token, desired(for: id) == want || isSameKind(desired(for: id), want) else {
            if case .success(let engine) = result { engine.stop() }
            return
        }
        switch result {
        case .success(let engine):
            record(SystemAudioAccess.granted)
            if case .volume = desired(for: id), case .volume(let level) = desired(for: id) { engine.gain = level }
            engines.updateValue(engine, forKey: id)?.stop()
            lastCycles[id] = nil
            Log.features.notice("Mixer tap for \(id, privacy: .public) installed")
            trace(
                "installed tap at \(engine.gain) for \(id) objects=\(engine.objects)"
            )
        case .failure(let failure):
            if case .tapRefused = failure {
                record(SystemAudioAccess.denied)
            }
            Log.features.error(
                "Mixer tap for \(id, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            trace("tap for \(id) failed: \(failure)")
            discard(id)
            failed.insert(id)
        }
        updateWatchdog()
    }

    private func record(_ value: String) {
        UserDefaults.standard.set(value, forKey: SystemAudioAccess.key)
        if access != value { access = value }
    }

    /// Asks macOS now (button in the box) instead of on the first drag; also
    /// used after a refusal and when MacHorus becomes active again (the user
    /// may have switched it on in System Settings). Apps that failed get
    /// another chance once it is granted.
    func requestAccess() {
        guard isEnabled, !isAsking else { return }
        isAsking = true
        let finished: @MainActor @Sendable (Bool) -> Void = { [weak self] granted in
            guard let self else { return }
            isAsking = false
            record(granted ? SystemAudioAccess.granted : SystemAudioAccess.denied)
            Log.features.notice("System audio access \(granted ? "granted" : "refused", privacy: .public)")
            guard granted else { return }
            failed.removeAll()
            for app in apps where desired(for: app.id) != .none { reconcile(app) }
        }
        buildQueue.async {
            let granted = AppAudioTap.requestAccess()
            DispatchQueue.main.async { MainActor.assumeIsolated { finished(granted) } }
        }
    }

    /// A volume change during the build keeps the build (the gain follows).
    private func isSameKind(_ lhs: Desired, _ rhs: Desired) -> Bool {
        switch (lhs, rhs) {
        case (.volume, .volume), (.none, .none): true
        default: false
        }
    }

    private func discard(_ id: String) {
        if engines[id] != nil { trace("removed tap for \(id)") }
        engines.removeValue(forKey: id)?.stop()
        tokens[id] = (tokens[id] ?? 0) + 1
        lastCycles[id] = nil
        updateWatchdog()
    }

    private func outputDeviceChanged() {
        // Volume taps play on the old device; rebuild them on the new one.
        // Apps whose tap failed on the old device get another chance.
        failed.subtract(apps.map(\.id).filter { volume(of: $0) < Self.unity })
        stallRebuilds = [:]
        // reconcile rebuilds a volume tap whose device is no longer the default.
        for app in apps where desired(for: app.id) != .none { reconcile(app) }
    }

    /// While volume taps run: a tap whose device stopped rendering while its
    /// app plays would keep the app silent, so it is removed (Vorssaint #341).
    private func updateWatchdog() {
        let needed = engines.values.contains { $0.outputDeviceUID != nil }
        if needed, watchdog == nil {
            let check: @MainActor @Sendable () -> Void = { [weak self] in self?.checkRendering() }
            let timer = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { check() } }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !needed {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    private func checkRendering() {
        // Reading render cycles is an atomic load; the process list (a
        // CoreAudio round trip, ~1 % CPU every 3 s) only when a tap stood still.
        var stalled: [String] = []
        for (id, engine) in engines where engine.outputDeviceUID != nil {
            let cycles = engine.renderCycles
            if lastCycles[id] == cycles { stalled.append(id) } else if lastCycles[id] != nil { stallRebuilds[id] = nil }
            lastCycles[id] = cycles
        }
        guard !stalled.isEmpty else { return }
        let playing = Set(
            AudioApps.group(AudioProcesses.list(), responsibility: responsibility).filter(\.usesOutput).map(\.id))
        for id in stalled {
            guard playing.contains(id), let app = apps.first(where: { $0.id == id }) else { continue }
            let rebuilds = stallRebuilds[id, default: 0]
            if rebuilds < 2 {
                // First try the current output device again.
                stallRebuilds[id] = rebuilds + 1
                trace("tap for \(id) stalled; rebuilding (\(rebuilds + 1))")
                build(app, desired(for: id))
                continue
            }
            Log.features.error("Mixer tap for \(id, privacy: .public) stopped rendering; sound handed back")
            trace("tap for \(id) stalled again; sound handed back")
            discard(id)
            failed.insert(id)
        }
    }

    // MARK: Default output device

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func observeDefaultOutput(_ handler: @escaping @Sendable () -> Void)
        -> AudioObjectPropertyListenerBlock
    {
        var address = defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    private static func stopObservingDefaultOutput(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}

@MainActor
final class AudioMixerFeature: FeatureModule {
    private let controller: AudioMixerController

    init(controller: AudioMixerController) {
        self.controller = controller
    }

    func start() { controller.start() }
    func stop() { controller.stop() }

    static func register(in registry: FeatureRegistry, controller: AudioMixerController) {
        registry.register(FeatureDescriptor(id: "audio.mixer", category: .audio, permissions: [.systemAudio])) {
            AudioMixerFeature(controller: controller)
        }
    }
}

/// `-debug.mixerTrace <file>` appends what the mixer does, for checks
/// without the system log (which needs administrator rights here).
@MainActor
private func trace(_ line: String) {
    guard let path = UserDefaults.standard.string(forKey: "debug.mixerTrace"),
        let data = (Date().formatted(.iso8601.time(includingFractionalSeconds: true)) + " " + line + "\n").data(
            using: .utf8)
    else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
