// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import Observation
import SystemConfiguration

/// Pending Munki and macOS updates, read from local files when the panel
/// shows them (at most once a minute; the files change only when Munki or
/// Software Update run).
@MainActor
@Observable
final class SoftwareUpdatesModel {
    var isEnabled = false
    private(set) var updates: SoftwareUpdates?
    /// Demo screenshots show the plain macOS path.
    let isMunkiInstalled = SoftwareUpdates.isMunkiInstalled && !DemoMode.isOn

    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private let refresher = SerialRefresh()

    func refresh(force: Bool = false) {
        if !force, let lastRead, Date().timeIntervalSince(lastRead) < 60 { return }
        lastRead = Date()
        refresher.run { [weak self] in
            // Without Munki, macOS updates are still worth showing.
            let read = await OffMain.run { SoftwareUpdates.read() ?? SoftwareUpdates.appleUpdatesOnly() }
            guard let self else { return }
            if read != updates { updates = read }
        }
    }

    /// Munki's own app on its updates page; macOS Software Update otherwise.
    func openUpdater() {
        let workspace = NSWorkspace.shared
        if isMunkiInstalled, let munki = URL(string: "munki://updates"),
            workspace.urlForApplication(toOpen: munki) != nil
        {
            workspace.open(munki)
        } else if let settings = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            workspace.open(settings)
        }
    }
}

@MainActor
final class SoftwareUpdatesFeature: FeatureModule {
    private let model: SoftwareUpdatesModel

    init(model: SoftwareUpdatesModel) {
        self.model = model
    }

    func start() {
        model.isEnabled = true
        model.refresh(force: true)
    }

    func stop() { model.isEnabled = false }

    static func register(in registry: FeatureRegistry, model: SoftwareUpdatesModel) {
        registry.register(FeatureDescriptor(id: "support.updates", category: .support)) {
            SoftwareUpdatesFeature(model: model)
        }
    }
}
