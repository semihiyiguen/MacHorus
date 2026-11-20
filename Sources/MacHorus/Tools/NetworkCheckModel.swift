// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore
import MacHorusTools
import Observation

/// The network check on the tools page: runs only on a click, the result
/// stays until the next one (or until the feature goes off).
@MainActor
@Observable
final class NetworkCheckModel {
    var isEnabled = false
    private(set) var isRunning = false
    private(set) var result: NetworkCheck?
    private(set) var checked: Date?

    func run() {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        Task {
            let result = await NetworkCheck.run()
            self.result = result
            checked = Date()
            isRunning = false
            Log.features.notice("Network check: \(String(describing: result.verdict), privacy: .public)")
        }
    }

    func forget() {
        result = nil
        checked = nil
    }
}

@MainActor
final class NetworkCheckFeature: FeatureModule {
    private let model: NetworkCheckModel

    init(model: NetworkCheckModel) {
        self.model = model
    }

    func start() { model.isEnabled = true }

    func stop() {
        model.isEnabled = false
        model.forget()
    }

    static func register(in registry: FeatureRegistry, model: NetworkCheckModel) {
        registry.register(FeatureDescriptor(id: "support.networkCheck", category: .support)) {
            NetworkCheckFeature(model: model)
        }
    }
}
