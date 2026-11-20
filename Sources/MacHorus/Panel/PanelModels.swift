// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore
import MacHorusMonitor
import Observation

/// Content sections first, settings last; later phases add their sections
/// (windows, input, …) between monitor and settings.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case monitor
    case tools
    case settings

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: MonitorHardware.hasBattery ? "laptopcomputer" : "desktopcomputer"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .tools: "wrench.and.screwdriver"
        case .settings: "gearshape"
        }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "panel.tab.overview")
        case .monitor: String(localized: "panel.tab.monitor")
        case .tools: String(localized: "panel.tab.tools")
        case .settings: String(localized: "panel.tab.settings")
        }
    }
}

enum SettingsSection: String, CaseIterable {
    case features
    case alerts
    case privacy
    case about
}

/// Which section the panel shows; other parts of the app can switch it,
/// e.g. ⌘, opens the features.
@MainActor
@Observable
final class PanelNavigation {
    var tab: PanelTab = .overview
    var settingsSection = SettingsSection.features
    /// The panel is on screen. Its views stay alive while it is closed, so
    /// loops in them (`.task`) check this instead of running on.
    var isShown = false
    /// The wider panel with more detail; remembered between launches.
    /// The wide panel is the default (the maintainer's everyday choice).
    var isExpanded =
        UserDefaults.standard.object(forKey: "panelExpanded") == nil
        ? true : UserDefaults.standard.bool(forKey: "panelExpanded")
    {
        didSet { UserDefaults.standard.set(isExpanded, forKey: "panelExpanded") }
    }
}

/// Feature toggles, grouped by category, backed by the FeatureController.
@MainActor
@Observable
final class FeatureSettingsModel {
    struct Row: Identifiable, Equatable {
        let id: FeatureID
        let category: FeatureCategory
        let permissions: [Permission]
        let isEnabled: Bool
        let isLocked: Bool
    }

    private(set) var rows: [Row] = []

    @ObservationIgnored private let controller: FeatureController

    init(controller: FeatureController) {
        self.controller = controller
        reload()
    }

    /// What Settings lists: the tools have no switches (they are widgets).
    var switchable: [Row] { rows.filter { $0.category != .tools } }
    var enabledCount: Int { switchable.filter(\.isEnabled).count }

    func rows(in category: FeatureCategory) -> [Row] {
        rows.filter { $0.category == category }
    }

    func setEnabled(_ enabled: Bool, for id: FeatureID) {
        controller.setEnabled(enabled, for: id)
        reload()
    }

    func reload() {
        rows = controller.registry.descriptors.map {
            Row(
                id: $0.id,
                category: $0.category,
                permissions: Permission.allCases.filter($0.permissions.contains),
                isEnabled: controller.isEnabled($0.id),
                isLocked: controller.isLocked($0.id)
            )
        }
    }
}

/// Permission rows for the privacy section. States are read only while the
/// section is visible, and only those that do not list the app.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var rows: [PermissionRow] = []
    /// Permissions some feature of this build can use; the others are never
    /// asked for and belong to "never".
    let declared: Set<Permission>

    @ObservationIgnored private let controller: FeatureController
    @ObservationIgnored private let provider = PermissionStatusProvider()

    init(controller: FeatureController) {
        self.controller = controller
        declared = Set(controller.registry.descriptors.flatMap(\.permissions))
        rows = PermissionOverview.rows(states: [:], usage: controller.permissionUsage)
    }

    func refresh() async {
        let usage = controller.permissionUsage
        let states = await provider.states(needed: Set(usage.keys))
        rows = PermissionOverview.rows(states: states, usage: usage)
    }
}

/// Everything the panel shows, owned by the status item.
@MainActor
final class PanelModel {
    let navigation = PanelNavigation()
    let widgets = WidgetLayoutsModel()
    let selfUsage = SelfUsageModel()
    let peripherals = PeripheralsModel()
    let diskUsage = DiskUsageModel()
    let statusDismissals = StatusDismissals()
    let features: FeatureSettingsModel
    let permissions: PermissionsModel
    let monitor: SystemMonitorModel
    let readouts: MenuBarReadouts?
    let alerts: MonitorAlerts?
    let tools: ToolsModels?
    let loginItem: LoginItemController?

    private var isVisible = false
    private var isWatchingMonitor = false

    init(
        featureController: FeatureController, monitor: SystemMonitorModel, readouts: MenuBarReadouts? = nil,
        alerts: MonitorAlerts? = nil, tools: ToolsModels? = nil, loginItem: LoginItemController? = nil
    ) {
        features = FeatureSettingsModel(controller: featureController)
        permissions = PermissionsModel(controller: featureController)
        self.monitor = monitor
        self.readouts = readouts
        self.alerts = alerts
        self.tools = tools
        self.loginItem = loginItem
        let selfUsage = self.selfUsage
        monitor.addRoundHandler(owner: self) { [weak selfUsage] _ in selfUsage?.roundCompleted() }
    }

    /// The panel opened or closed (popover or preview window).
    func setVisible(_ visible: Bool) {
        isVisible = visible
        navigation.isShown = visible
        visible ? selfUsage.startUpdating() : selfUsage.stopUpdating()
        updateMonitorDemand()
    }

    /// The widget page a section shows (settings has none).
    var widgetPage: WidgetPage? {
        switch navigation.tab {
        case .overview: .overview
        case .monitor: .monitor
        case .tools: .tools
        case .settings: nil
        }
    }

    var panelWidth: PanelWidth { navigation.isExpanded ? .expanded : .compact }

    /// Monitor values are sampled only while widgets that show them are on
    /// screen: the union of what the visible page's widgets need.
    func updateMonitorDemand() {
        var needed: Set<Metric> =
            widgetPage.map { page in
                widgets.layout(page, panelWidth).items.reduce(into: Set<Metric>()) { $0.formUnion($1.metrics) }
            } ?? []
        // The gallery shows every widget live.
        if widgets.isAdding { needed = Set(Metric.allCases) }
        monitor.setUnshown(monitor.enabledMetrics.subtracting(needed))
        let watching = isVisible && !needed.isEmpty
        guard watching != isWatchingMonitor else { return }
        isWatchingMonitor = watching
        selfUsage.followRounds(watching)
        watching ? monitor.addViewer() : monitor.removeViewer()
    }
}
