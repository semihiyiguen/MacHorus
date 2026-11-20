// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore
import MacHorusMonitor
import Observation

/// Latest monitor readings for the UI. Samples only while a monitor feature
/// is on **and** something shows the values; otherwise nothing runs.
@MainActor
@Observable
final class SystemMonitorModel {
    static let interval: Duration = .seconds(2)
    /// Only the menu bar values are shown: every status item update costs
    /// 6–14 ms (it goes through the system's menu bar agent), so they
    /// refresh half as often (docs/MEASUREMENTS.md).
    static let backgroundInterval: Duration = .seconds(4)
    static let historyLength = 60

    private(set) var cpu: CPUSnapshot?
    private(set) var memory: MemorySnapshot?
    private(set) var disk: DiskSnapshot?
    private(set) var network: NetworkSnapshot?
    private(set) var battery: BatterySnapshot?
    private(set) var thermal: ThermalSnapshot?
    private(set) var gpu: GPUSnapshot?
    private(set) var processes: ProcessesSnapshot?
    /// Seconds since the start, refreshed with every round.
    private(set) var uptime = SystemUptime.uptime()
    private(set) var restartAdvice = RestartAdvisor.advise(uptime: SystemUptime.uptime(), memory: nil)
    /// Whether the reasons of the restart advice are shown.
    var showsRestartReasons = false
    /// Which list the process card shows.
    var processSort = ProcessOrder.cpu
    /// CPU column: load now or CPU time since each app started.
    var processCPUValue = ProcessCPUValue.now
    /// Memory column: now or the highest it reached.
    var processMemoryValue = ProcessMemoryValue.now
    /// Apps with a window, background processes or both (CPU and memory).
    var processKind = ProcessKind.all
    /// The process row whose details are open (one at a time).
    var expandedProcessRow: String?
    /// Network per app, read only while the list is sorted by network.
    @ObservationIgnored let traffic = AppTrafficModel()
    /// Filter text of the process list; empty shows the busiest rows.
    var processQuery = ""
    /// The search field is shown (it replaces its placeholder button).
    var processSearchActive = false
    private(set) var cpuHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var memoryHistory = RingBuffer<Double>(capacity: historyLength)
    /// Download + upload in bytes per second; a direction that cannot be
    /// measured counts as 0 (see NetworkSnapshot).
    private(set) var networkHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var diskHistory = RingBuffer<Double>(capacity: historyLength)
    /// Hottest CPU sensor in °C.
    private(set) var temperatureHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var gpuHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var enabledMetrics: Set<Metric> = []
    /// Metrics whose last reading was impossible (see `Plausibility`): their
    /// widgets show "?" and say why.
    private(set) var suspicious: Set<Metric> = []
    /// The last impossible readings, newest first (for the diagnosis).
    @ObservationIgnored private(set) var anomalies: [(date: Date, anomaly: Anomaly)] = []
    /// When the current sampling began: "–" right after it means "not yet".
    @ObservationIgnored private(set) var samplingSince: Date?

    @ObservationIgnored private let engine: MonitorEngine
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var unshown: Set<Metric> = []
    /// Sampled even while the panel is closed (menu bar values, alerts), per owner.
    @ObservationIgnored private var background: [ObjectIdentifier: Set<Metric>] = [:]
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var reconcile: Task<Void, Never>?
    /// Called after each delivered round, in the same main-actor turn, so
    /// other values shown with the monitor change in the same redraw.
    @ObservationIgnored private var roundHandlers: [ObjectIdentifier: @MainActor (MonitorSnapshot) -> Void] = [:]

    /// The private interfaces the policy allows, and what this Mac can
    /// measure (read once at launch): for the diagnosis.
    @ObservationIgnored let privateAPIs: Set<PrivateAPI>
    @ObservationIgnored var hardware: HardwareCapabilities?

    /// `privateAPIs`: the private interfaces the policy allows.
    init(privateAPIs: Set<PrivateAPI>) {
        self.privateAPIs = privateAPIs
        engine = MonitorEngine(privateAPIs: privateAPIs)
    }

    var isAnyMetricEnabled: Bool { !enabledMetrics.isEmpty }

    func addRoundHandler(owner: AnyObject, _ handler: @escaping @MainActor (MonitorSnapshot) -> Void) {
        roundHandlers[ObjectIdentifier(owner)] = handler
    }

    func enable(_ metric: Metric) {
        enabledMetrics.insert(metric)
        update()
    }

    func disable(_ metric: Metric) {
        enabledMetrics.remove(metric)
        clear(metric)
        update()
    }

    /// A view that shows monitor values appears or disappears.
    func addViewer() {
        viewers += 1
        update()
    }

    /// Metrics something outside the panel needs all the time.
    func setBackground(_ metrics: Set<Metric>, for owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard background[key, default: []] != metrics else { return }
        background[key] = metrics.isEmpty ? nil : metrics
        update()
    }

    /// Metrics the visible page does not show are not sampled (the overview
    /// shows neither processes nor the GPU).
    func setUnshown(_ metrics: Set<Metric>) {
        guard metrics != unshown else { return }
        // No stale values when the page that shows them comes back.
        for metric in metrics.subtracting(unshown) { clear(metric) }
        unshown = metrics
        update()
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        update()
    }

    private func clear(_ metric: Metric) {
        switch metric {
        case .cpu:
            cpu = nil
            cpuHistory.removeAll()
        case .memory:
            memory = nil
            memoryHistory.removeAll()
        case .disk:
            disk = nil
            diskHistory.removeAll()
        case .network:
            network = nil
            networkHistory.removeAll()
        case .power:
            battery = nil
        case .thermal:
            thermal = nil
            temperatureHistory.removeAll()
        case .gpu:
            gpu = nil
            gpuHistory.removeAll()
        case .processes:
            processes = nil
        }
    }

    private func update() {
        let metrics = (viewers > 0 ? enabledMetrics.subtracting(unshown) : [])
            .union(background.values.reduce(into: Set<Metric>()) { $0.formUnion($1) })
        let interval = viewers > 0 ? Self.interval : Self.backgroundInterval
        let previous = reconcile
        let deliver: @MainActor @Sendable (MonitorSnapshot) -> Void = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        // Changes are applied in order, so a quick open/close never races.
        reconcile = Task { [engine] in
            await previous?.value
            if metrics.isEmpty {
                await engine.stop()
            } else {
                await engine.start(metrics: metrics, interval: interval, deliver: deliver)
            }
        }
        if metrics.isEmpty {
            samplingSince = nil
        } else if samplingSince == nil {
            samplingSince = Date()
        }
        isSampling = !metrics.isEmpty
        if !isSampling {
            // Charts show one continuous stretch of time, never a hidden gap.
            cpuHistory.removeAll()
            memoryHistory.removeAll()
            networkHistory.removeAll()
            diskHistory.removeAll()
            temperatureHistory.removeAll()
            gpuHistory.removeAll()
        }
    }

    private func receive(_ snapshot: MonitorSnapshot) {
        // A round already in flight when sampling stopped is dropped.
        guard isSampling else { return }
        if let value = snapshot.cpu {
            cpu = value
            cpuHistory.append(value.total.total)
        }
        if let value = snapshot.memory {
            memory = value
            memoryHistory.append(value.usedFraction)
        }
        if let value = snapshot.disk {
            disk = value
            diskHistory.append(value.readBytesPerSecond + value.writeBytesPerSecond)
        }
        if let value = snapshot.network {
            network = value
            if value.downloadBytesPerSecond != nil || value.uploadBytesPerSecond != nil {
                networkHistory.append((value.downloadBytesPerSecond ?? 0) + (value.uploadBytesPerSecond ?? 0))
            }
        }
        if let value = snapshot.battery {
            battery = value
        }
        if let value = snapshot.thermal {
            thermal = value
            if let cpu = value.cpu { temperatureHistory.append(cpu) }
        }
        if let value = snapshot.gpu {
            gpu = value
            gpuHistory.append(value.utilization)
        }
        if let value = snapshot.processes {
            processes = DemoMode.isOn ? DemoMode.processes() : value
        }
        // `-debug.uptimeOffsetDays <n>` shows the restart advice of a longer uptime.
        uptime = SystemUptime.uptime(at: snapshot.date).map {
            $0 + UserDefaults.standard.double(forKey: "debug.uptimeOffsetDays") * 86_400
        }
        let advice = RestartAdvisor.advise(uptime: uptime, memory: memory)
        if advice != restartAdvice { restartAdvice = advice }
        check(snapshot)
        for handler in roundHandlers.values { handler(snapshot) }
    }

    /// Range checks of the round: impossible values are logged (once per
    /// metric and hour, so a stuck sensor does not flood the log) and kept.
    private func check(_ snapshot: MonitorSnapshot) {
        let found = Plausibility.check(snapshot)
        let metrics = Set(found.map(\.metric))
        if metrics != suspicious { suspicious = metrics }
        for anomaly in found {
            let recent = anomalies.first { $0.anomaly.metric == anomaly.metric }
            guard recent.map({ snapshot.date.timeIntervalSince($0.date) > 3600 }) ?? true else { continue }
            Log.monitor.error(
                "Implausible \(anomaly.metric.rawValue, privacy: .public): \(anomaly.text, privacy: .public)")
            anomalies.insert((snapshot.date, anomaly), at: 0)
            if anomalies.count > 20 { anomalies.removeLast() }
        }
    }
}

/// The monitor as one feature: on, every value this Mac can measure is
/// available; which ones show (and so are measured while the page is
/// open) is the layout on the monitor page. Sampling still waits for a viewer.
@MainActor
final class MonitorSystemFeature: FeatureModule {
    private let metrics: Set<Metric>
    private let monitor: SystemMonitorModel

    init(metrics: Set<Metric>, monitor: SystemMonitorModel) {
        self.metrics = metrics
        self.monitor = monitor
    }

    func start() {
        for metric in metrics { monitor.enable(metric) }
        monitor.traffic.startBackground()
    }

    func stop() {
        for metric in metrics { monitor.disable(metric) }
        monitor.traffic.stopBackground()
    }

    /// What this Mac cannot measure is never enabled (`hardware`, read at
    /// launch): no GPU statistics, no sensors or no battery leave their card out.
    static func register(in registry: FeatureRegistry, monitor: SystemMonitorModel, hardware: HardwareCapabilities) {
        var metrics: Set<Metric> = [.cpu, .memory, .network, .disk, .processes]
        if hardware.hasGPUStatistics { metrics.insert(.gpu) }
        if hardware.hasThermalReadings { metrics.insert(.thermal) }
        if hardware.hasBattery { metrics.insert(.power) }
        registry.register(FeatureDescriptor(id: "monitor.system", category: .monitor)) {
            MonitorSystemFeature(metrics: metrics, monitor: monitor)
        }
        // Menu bar values and alerts (category menuBar) are registered by
        // AppDelegate: they need the status item and the screen state.
    }
}

/// What the process list's CPU column shows (chosen in its title menu).
enum ProcessCPUValue: String, CaseIterable {
    case now
    case total
}

/// What the process list's memory column shows.
enum ProcessMemoryValue: String, CaseIterable {
    case now
    case peak
}

/// Which rows the CPU and memory lists show.
enum ProcessKind: String, CaseIterable {
    case all
    case apps
    case background
}
