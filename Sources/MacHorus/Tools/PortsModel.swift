// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import Observation

/// Listening TCP ports of the user's own processes, read only while the
/// card is on screen (every 5 s) and never in the background.
@MainActor
@Observable
final class PortsModel {
    static let interval: Duration = .seconds(5)

    var isEnabled = false
    private(set) var ports: [ListeningPort] = []

    func refresh() async {
        let read = await OffMain.run { ListeningPorts.read() }
        if read != ports { ports = read }
    }

    /// Opens `http://localhost:<port>` in the default browser.
    static func open(_ port: ListeningPort) {
        guard let url = URL(string: "http://localhost:\(port.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyAddress(_ port: ListeningPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("localhost:\(port.port)", forType: .string)
    }

    /// Quits the owner with the same checks as the process list.
    static func quit(_ port: ListeningPort) {
        ProcessActions.quit(
            ProcessUsage(identity: port.identity, name: port.processName, cpu: 0, memory: 0, processCount: 1))
    }
}

@MainActor
final class PortsFeature: FeatureModule {
    private let model: PortsModel

    init(model: PortsModel) {
        self.model = model
    }

    func start() { model.isEnabled = true }
    func stop() { model.isEnabled = false }

    static func register(in registry: FeatureRegistry, model: PortsModel) {
        registry.register(FeatureDescriptor(id: "tools.ports", category: .tools)) { PortsFeature(model: model) }
    }
}
