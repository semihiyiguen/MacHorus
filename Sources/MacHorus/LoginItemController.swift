// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore
import Observation
import ServiceManagement

/// "Open at login" through the main app as a login item: no helper, no
/// permission. System Settings → General → Login Items shows and removes it
/// too, so the state is read again whenever the settings show it.
@MainActor
@Observable
final class LoginItemController {
    enum State: String, Equatable {
        case on
        case off
        /// Registered, but not allowed in System Settings.
        case needsApproval
    }

    private(set) var state: State = .off

    init() {
        refresh()
    }

    /// An installed copy turns it on once, at its first launch (OpenAtLogin).
    func applyFirstLaunchDefault(bundleURL: URL = Bundle.main.bundleURL) {
        let decided = UserDefaults.standard.bool(forKey: OpenAtLogin.decidedKey)
        guard OpenAtLogin.turnsOnAtLaunch(alreadyDecided: decided, bundleURL: bundleURL) else { return }
        setOn(true)
        Log.app.notice("Open at login requested after the first launch")
    }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(true, forKey: OpenAtLogin.decidedKey)
        let service = SMAppService.mainApp
        do {
            switch (on, service.status) {
            case (true, .requiresApproval):
                // Only the user can allow it again, in System Settings.
                SMAppService.openSystemSettingsLoginItems()
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                break
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
        } catch {
            Log.app.error("Open at login could not be changed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// The status is an XPC round trip to launchd: read off the main thread.
    func refresh() {
        refresher.run { [weak self] in
            let status = await OffMain.run { SMAppService.mainApp.status }
            let read: State =
                switch status {
                case .enabled: .on
                case .requiresApproval: .needsApproval
                default: .off
                }
            if let self, read != state { state = read }
        }
    }

    @ObservationIgnored private let refresher = SerialRefresh()

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
