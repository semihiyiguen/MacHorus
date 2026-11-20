// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import Foundation
import MacHorusCore
import MacHorusTools
import Observation

/// Keeps the Mac awake for a while or until switched off. Nothing runs while
/// it is off; while on, one power assertion and one timer for the end.
/// Never restored after a restart of the app: a forgotten session must not
/// keep a Mac awake for days.
@MainActor
@Observable
final class KeepAwakeController {
    static let durations: [TimeInterval?] = [30 * 60, 60 * 60, 2 * 60 * 60, nil]
    static let displayKey = "keepAwakeDisplay"

    /// The feature is switched on (the card shows).
    var isEnabled = false
    private(set) var session: KeepAwakeSession?
    /// The display stays on too (default: presentations, video calls).
    private(set) var keepsDisplayOn = UserDefaults.standard.object(forKey: displayKey) as? Bool ?? true

    /// Set when the session lasts as long as an app runs.
    private(set) var watchedApp: WatchedApp?

    struct WatchedApp: Equatable {
        let pid: pid_t
        let name: String
    }

    @ObservationIgnored private var assertion: PowerAssertion?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var changeHandlers: [@MainActor () -> Void] = []

    var isActive: Bool { session != nil }

    func onChange(_ handler: @escaping @MainActor () -> Void) {
        changeHandlers.append(handler)
    }

    /// `duration` nil: until switched off.
    func start(duration: TimeInterval?) {
        stop()
        guard let assertion = PowerAssertion(display: keepsDisplayOn) else {
            Log.features.error("Keep awake: the power assertion was refused")
            return
        }
        self.assertion = assertion
        let session = KeepAwakeSession(started: Date(), duration: duration, keepsDisplayOn: keepsDisplayOn)
        self.session = session
        if let ends = session.ends {
            let timer = Timer(fire: ends, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        }
        Log.features.notice(
            "Keep awake on for \(duration.map { "\(Int($0 / 60)) min" } ?? "unlimited", privacy: .public)")
        notify()
    }

    /// Awake until `app` quits (a long render, a download, a call); the
    /// app's end is a notification from macOS, nothing is polled.
    func start(whileRunning app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        start(duration: nil)
        guard session != nil else { return }
        let watched = WatchedApp(pid: app.processIdentifier, name: app.localizedName ?? "–")
        watchedApp = watched
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid == self.watchedApp?.pid else { return }
                Log.features.notice("Keep awake: the watched app quit")
                self.stop()
            }
        }
        Log.features.notice("Keep awake while an app runs")
        notify()
    }

    /// Apps to choose from: regular apps (with a Dock icon), MacHorus left out.
    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func stop() {
        guard session != nil || assertion != nil else { return }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        watchedApp = nil
        endTimer?.invalidate()
        endTimer = nil
        assertion = nil
        session = nil
        Log.features.notice("Keep awake off")
        notify()
    }

    func setKeepsDisplayOn(_ on: Bool) {
        keepsDisplayOn = on
        UserDefaults.standard.set(on, forKey: Self.displayKey)
        // A running session switches its kind; its end time stays.
        guard let session else { return }
        if let watchedApp, let app = NSRunningApplication(processIdentifier: watchedApp.pid) {
            start(whileRunning: app)
            return
        }
        let remaining = session.remaining(at: Date())
        start(duration: remaining)
    }

    private func notify() {
        for handler in changeHandlers { handler() }
    }
}

@MainActor
final class KeepAwakeFeature: FeatureModule {
    private let controller: KeepAwakeController

    init(controller: KeepAwakeController) {
        self.controller = controller
    }

    func start() { controller.isEnabled = true }

    /// Switching the feature off ends a running session.
    func stop() {
        controller.stop()
        controller.isEnabled = false
    }

    static func register(in registry: FeatureRegistry, controller: KeepAwakeController) {
        registry.register(FeatureDescriptor(id: "display.keepAwake", category: .display)) {
            KeepAwakeFeature(controller: controller)
        }
    }
}
