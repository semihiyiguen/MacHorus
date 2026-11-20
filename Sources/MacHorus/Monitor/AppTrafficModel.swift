// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusMonitor
import Observation

/// Upload and download per app, split into VPN and the own connection:
/// now (every 3 s while the network list is on screen) and in total since
/// the Mac started (one reading a minute in the background while the
/// monitor is on, about 30 ms CPU each). Totals include what connections
/// open at MacHorus' start had carried; connections that opened and closed
/// within a minute while the list was closed can be missing.
@MainActor
@Observable
final class AppTrafficModel {
    static let interval: Duration = .seconds(3)

    struct Row: Identifiable, Equatable {
        let id: String
        /// The process row it belongs to, when this user's process.
        let identity: ProcessIdentity?
        let name: String
        let use: NetworkUse
        let processCount: Int
    }

    enum Span: String {
        case now
        case sinceStart
    }

    static let backgroundInterval: Duration = .seconds(60)

    private(set) var uses: [AppTraffic.Use] = []
    /// Bytes per process since the Mac started (see above).
    private(set) var totals: [pid_t: (name: String, bytes: NetworkUse)] = [:]
    var span = Span.now
    /// Tunnels in use right now (empty: no VPN).
    private(set) var vpnInterfaces: Set<String> = []
    /// The VPN that is up: tunnel addresses and connected system services.
    private(set) var vpn = VPNStatus(tunnels: [], services: [])
    /// False when `nettop` could not be run.
    private(set) var isAvailable = true
    var route = TrafficRoute.all

    @ObservationIgnored private var traffic = AppTraffic()
    @ObservationIgnored private var background: Task<Void, Never>?
    /// One reading at a time: an older reading arriving after a newer one
    /// would look like new connections and count twice.
    @ObservationIgnored private var isReading = false

    /// The monitor is on: keep the totals going.
    func startBackground() {
        guard background == nil else { return }
        background = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.backgroundInterval)
            }
        }
    }

    func stopBackground() {
        background?.cancel()
        background = nil
    }

    func refresh() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        if DemoMode.isOn {
            uses = DemoMode.trafficNow()
            totals = DemoMode.trafficTotals()
            isAvailable = true
            return
        }
        let (flows, tunnels, status) = await OffMain.run {
            (AppTraffic.read(), AppTraffic.vpnInterfaces(), VPNStatus.read())
        }
        if status != vpn { vpn = status }
        guard let flows else {
            isAvailable = false
            return
        }
        isAvailable = true
        if tunnels != vpnInterfaces { vpnInterfaces = tunnels }
        if tunnels.isEmpty, route != .all { route = .all }
        let rates = traffic.rates(flows, vpnInterfaces: tunnels, at: Date())
        if rates != uses { uses = rates }
        for use in rates where use.bytes.total(.all) > 0 {
            let entry = totals[use.pid] ?? (name: use.name, bytes: NetworkUse())
            totals[use.pid] = (name: entry.name, bytes: entry.bytes + use.bytes)
        }
    }

    /// The list left the screen: rates are stale; totals stay.
    func reset() {
        uses = []
    }

    /// One row per app: helpers add to their app as in the CPU list;
    /// processes MacHorus cannot read (system services) stand alone.
    func rows(processes: ProcessesSnapshot?, span: Span? = nil, name: (ProcessUsage) -> String) -> [Row] {
        let span = span ?? self.span
        var grouped: [String: (identity: ProcessIdentity?, name: String, use: NetworkUse, count: Int)] = [:]
        let byIdentity = Dictionary(
            (processes?.rows ?? []).map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let source: [(pid: pid_t, name: String, use: NetworkUse)] =
            span == .now
            ? uses.map { ($0.pid, $0.name, $0.use) } : totals.map { ($0.key, $0.value.name, $0.value.bytes) }
        for use in source {
            if let owner = processes?.owners[use.pid] {
                let key = "\(owner.pid).\(owner.started)"
                let title = byIdentity[owner].map(name) ?? use.name
                var entry = grouped[key] ?? (identity: owner, name: title, use: NetworkUse(), count: 0)
                entry.use = entry.use + use.use
                entry.count += 1
                grouped[key] = entry
            } else {
                // Ended or not readable: by name, so restarts add up.
                let key = "name.\(use.name)"
                var entry = grouped[key] ?? (identity: nil, name: use.name, use: NetworkUse(), count: 0)
                entry.use = entry.use + use.use
                entry.count += 1
                grouped[key] = entry
            }
        }
        return grouped.map {
            Row(
                id: $0.key, identity: $0.value.identity, name: $0.value.name, use: $0.value.use,
                processCount: $0.value.count)
        }
    }

    /// Totals since the Mac started for one row of the CPU or memory list.
    func total(for identity: ProcessIdentity, processes: ProcessesSnapshot?) -> NetworkUse? {
        rows(processes: processes, span: .sinceStart) { _ in "" }.first { $0.identity == identity }?.use
    }

    /// The VPN client among the processes with traffic (for clients that
    /// open their tunnel without a system service, e.g. OpenVPN Connect).
    var vpnClientName: String? {
        uses.first { VPNStatus.isClient($0.name) }?.name
            ?? totals.values.first { VPNStatus.isClient($0.name) }?.name
    }

    /// The busiest rows for the chosen route; rows without traffic left out.
    func top(_ rows: [Row], limit: Int) -> [Row] {
        Array(
            rows.filter { $0.use.total(route) > 0 }
                .sorted {
                    $0.use.total(route) != $1.use.total(route)
                        ? $0.use.total(route) > $1.use.total(route) : $0.id < $1.id
                }
                .prefix(limit))
    }
}
