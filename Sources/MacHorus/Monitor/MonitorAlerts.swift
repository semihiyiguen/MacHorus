// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import Observation
import UserNotifications

/// Alerts from `AlertEvaluator`: the eye in the menu bar gets a warning
/// badge, the overview lists them, and on request a notification is sent.
/// Off by default; while on, the needed values are sampled in the background
/// (every 4 s with the panel closed), never while the screen is unavailable.
@MainActor
@Observable
final class MonitorAlerts {
    static let notificationsKey = "alertNotifications"
    static let metrics: Set<Metric> = [.cpu, .thermal, .memory, .disk, .power]

    private(set) var active: Set<AlertKind> = []
    /// When each alert comes (on/off, thresholds), set in the settings.
    private(set) var rules = AlertRules(stored: UserDefaults.standard.data(forKey: MonitorAlerts.rulesKey))
    nonisolated static let rulesKey = "alertRules"
    /// For texts outside the model (notifications are built from it too).
    nonisolated static var currentRules: AlertRules {
        AlertRules(stored: UserDefaults.standard.data(forKey: rulesKey))
    }
    /// The app behind a CPU, heat or memory alert, found when it fires.
    private(set) var culprits: [AlertKind: AlertCulpritRow] = [:]
    /// On by default (the maintainer's everyday setting); macOS asks for the
    /// permission only when the first alert actually fires.
    private(set) var sendsNotifications =
        UserDefaults.standard.object(forKey: MonitorAlerts.notificationsKey) == nil
        ? true : UserDefaults.standard.bool(forKey: MonitorAlerts.notificationsKey)

    @ObservationIgnored private let monitor: SystemMonitorModel
    @ObservationIgnored private let screen: ScreenAvailability
    @ObservationIgnored private let readouts: MenuBarReadouts
    @ObservationIgnored private var evaluator = AlertEvaluator()
    @ObservationIgnored private var isOn = false
    @ObservationIgnored private let responder = AlertNotificationResponder()

    /// Opens the panel on a page; set once the menu bar item exists.
    func setOpener(_ open: @escaping @MainActor (AlertNotificationResponder.Target) -> Void) {
        responder.open = open
    }

    init(monitor: SystemMonitorModel, screen: ScreenAvailability, readouts: MenuBarReadouts) {
        self.monitor = monitor
        self.screen = screen
        self.readouts = readouts
        monitor.addRoundHandler(owner: self) { [weak self] snapshot in self?.handle(snapshot) }
        screen.onChange { [weak self] _ in self?.updateDemand() }
        responder.install()
    }

    func setOn(_ on: Bool) {
        isOn = on
        if !on {
            evaluator = AlertEvaluator()
            active = []
            culprits = [:]
            readouts.setAlert(false)
        }
        updateDemand()
    }

    /// What macOS allows, read from macOS (not from MacHorus' own setting):
    /// the alerts page shows "allow", "switched off in System Settings" or
    /// the switch, so a ticked box never promises notifications that macOS
    /// does not show.
    enum Permission: Equatable {
        case unknown
        case notAsked
        case denied
        case allowed
    }

    private(set) var permission: Permission = .unknown

    func refreshPermission() {
        Task { @MainActor [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            let read: Permission =
                switch status {
                case .notDetermined: .notAsked
                case .denied: .denied
                default: .allowed
                }
            if self?.permission != read { self?.permission = read }
        }
    }

    /// The macOS question, on the user's click ("Mitteilungen erlauben").
    func requestPermission() {
        Task { @MainActor [weak self] in
            let granted =
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
            Log.app.notice("Notification permission \(granted ? "granted" : "not granted", privacy: .public)")
            if granted { self?.setSendsNotifications(true) }
            self?.refreshPermission()
        }
    }

    /// A notification right away, to see that they arrive (and to let macOS
    /// ask for the permission when it never did).
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "alerts.test.title")
        content.body = String(localized: "alerts.test.body")
        content.sound = .default
        // A click opens the alert settings, where the test was sent from.
        content.userInfo = [
            AlertNotificationResponder.openKey: AlertNotificationResponder.Target.alertSettings.rawValue
        ]
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    self?.setSendsNotifications(false)
                    return
                }
            case .denied:
                self?.setSendsNotifications(false)
                return
            default: break
            }
            self?.refreshPermission()
            try? await center.add(UNNotificationRequest(identifier: "alert.test", content: content, trigger: nil))
        }
    }

    func setRules(_ rules: AlertRules) {
        guard rules != self.rules else { return }
        self.rules = rules
        UserDefaults.standard.set(rules.stored, forKey: Self.rulesKey)
        // Switched-off kinds disappear at once, not only with the next round.
        active = active.filter(rules.isEnabled)
        culprits = culprits.filter { rules.isEnabled($0.key) }
        readouts.setAlert(!active.isEmpty)
    }

    /// Asks macOS for permission the first time; nothing is asked before.
    func setSendsNotifications(_ on: Bool) {
        sendsNotifications = on
        UserDefaults.standard.set(on, forKey: Self.notificationsKey)
        guard on else { return }
        // Denied now or earlier in System Settings: the box must not promise
        // notifications that never arrive.
        let revert: @MainActor @Sendable () -> Void = { [weak self] in self?.setSendsNotifications(false) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.app.notice("Notification permission \(granted ? "granted" : "not granted", privacy: .public)")
            guard !granted else { return }
            Task { @MainActor in revert() }
        }
    }

    private func updateDemand() {
        monitor.setBackground(isOn && screen.isAvailable ? Self.metrics : [], for: self)
    }

    private func handle(_ snapshot: MonitorSnapshot) {
        guard isOn else { return }
        let fired = evaluator.evaluate(snapshot, rules: rules)
        if evaluator.active != active {
            let names = evaluator.active.map(\.rawValue).sorted().joined(separator: ",")
            Log.monitor.notice("Alerts active: [\(names, privacy: .public)]")
            active = evaluator.active
            culprits = culprits.filter { active.contains($0.key) }
        }
        readouts.setAlert(!active.isEmpty)
        let notifies = sendsNotifications
        for kind in fired {
            guard let order = Self.culpritOrder(kind) else {
                if notifies { notify(kind, culprit: nil) }
                continue
            }
            // Who causes it: two process readings a second apart, off main.
            Task { [weak self] in
                let row = await OffMain.run { AlertCulprit.find(by: order) }
                guard let self, active.contains(kind) else { return }
                let culprit = row.map { AlertCulpritRow(row: $0, name: ProcessActions.name(for: $0), order: order) }
                culprits[kind] = culprit
                if notifies { notify(kind, culprit: culprit) }
            }
        }
    }

    static func culpritOrder(_ kind: AlertKind) -> ProcessOrder? {
        switch kind {
        case .cpuBusy, .hot: .cpu
        case .memoryPressure: .memory
        case .diskFull, .batteryLow: nil
        }
    }

    private func notify(_ kind: AlertKind, culprit: AlertCulpritRow?) {
        let content = UNMutableNotificationContent()
        content.title = AlertTexts.title(kind)
        content.body = AlertTexts.detail(kind)
        content.sound = .default
        // A click opens the monitor (the value and who causes it).
        content.userInfo = [AlertNotificationResponder.openKey: AlertNotificationResponder.Target.monitor.rawValue]
        if let culprit {
            content.body += "\n" + culprit.text
            // "Quit …" right in the notification; checked again before acting.
            if ProcessActions.canAct(on: culprit.row.identity) {
                content.categoryIdentifier = AlertNotificationResponder.culpritCategory
                content.userInfo["pid"] = Int(culprit.row.identity.pid)
                content.userInfo["started"] = NSNumber(value: culprit.row.identity.started)
            }
        }
        // One notification per kind: a newer one replaces the older.
        let identifier = "alert." + kind.rawValue
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    self?.setSendsNotifications(false)
                    return
                }
            case .denied:
                // Denied, now or later in System Settings: stop promising notifications.
                self?.setSendsNotifications(false)
                return
            default:
                break
            }
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}

/// The app found behind an alert, named for display.
struct AlertCulpritRow: Equatable {
    let row: ProcessUsage
    let name: String
    let order: ProcessOrder

    /// "Mainly Google Chrome (180 % CPU)".
    var text: String {
        let value =
            order == .memory
            ? MonitorFormat.bytes(row.memory) : MonitorFormat.percent(row.cpu) + " CPU"
        return String(format: String(localized: "alerts.culprit %@ %@"), name, value)
    }
}

/// Shows alert notifications also while MacHorus is in front, and runs
/// "Quit …" from a notification (with the same checks and confirmation as
/// the process list).
final class AlertNotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let culpritCategory = "alert.culprit"
    static let quitAction = "quit"
    static let openKey = "open"

    /// Where a click on the notification leads.
    enum Target: String {
        case monitor
        case alertSettings
    }

    /// Set on the main actor at launch, read there only.
    @MainActor var open: (@MainActor (Target) -> Void)?

    @MainActor func install() {
        let center = UNUserNotificationCenter.current()
        let quit = UNNotificationAction(
            identifier: Self.quitAction, title: String(localized: "alerts.culprit.quit"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.culpritCategory, actions: [quit], intentIdentifiers: [])
        ])
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // A click on the notification itself: open MacHorus where it belongs.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let target =
                (response.notification.request.content.userInfo[Self.openKey] as? String)
                .flatMap(Target.init(rawValue:)) ?? .monitor
            await MainActor.run { open?(target) }
            return
        }
        guard response.actionIdentifier == Self.quitAction,
            let pid = response.notification.request.content.userInfo["pid"] as? Int,
            let started = (response.notification.request.content.userInfo["started"] as? NSNumber)?.uint64Value
        else { return }
        await MainActor.run {
            let identity = ProcessIdentity(pid: pid_t(pid), started: started)
            // Still the same process (same start time) and this user's.
            guard ProcessActions.canAct(on: identity) else { return }
            ProcessActions.quit(
                ProcessUsage(
                    identity: identity, name: ProcessInspector.name(of: identity.pid), cpu: 0, memory: 0,
                    processCount: 1))
        }
    }
}

enum AlertTexts {
    static func title(_ kind: AlertKind) -> String {
        localized("alerts.\(kind.rawValue).title")
    }

    /// The rule in words, with the user's thresholds.
    static func detail(_ kind: AlertKind, rules: AlertRules = MonitorAlerts.currentRules) -> String {
        switch kind {
        case .cpuBusy:
            String(
                format: localized("alerts.cpuBusy.detail %@ %@"), MonitorFormat.percent(rules.cpuPercent),
                minutes(rules.cpuMinutes))
        case .hot: localized("alerts.hot.detail %@").replacingOccurrences(of: "%@", with: "\(rules.hotCelsius) °C")
        case .memoryPressure: localized("alerts.memoryPressure.detail")
        case .diskFull:
            localized("alerts.diskFull.detail %@").replacingOccurrences(of: "%@", with: diskLimit(rules))
        case .batteryLow:
            localized("alerts.batteryLow.detail %@").replacingOccurrences(
                of: "%@", with: MonitorFormat.percent(rules.batteryPercent))
        }
    }

    static func minutes(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))
    }

    static func diskLimit(_ rules: AlertRules) -> String {
        rules.diskMode == .percent ? MonitorFormat.percent(rules.diskPercent) : "\(rules.diskGigabytes) GB"
    }

    static func symbol(_ kind: AlertKind) -> String {
        switch kind {
        case .cpuBusy: "cpu"
        case .hot: "thermometer.high"
        case .memoryPressure: "memorychip"
        case .diskFull: "internaldrive"
        case .batteryLow: "battery.25"
        }
    }

    // Runtime keys: ask the bundle (String(localized:) needs literal keys).
    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

@MainActor
final class AlertsFeature: FeatureModule {
    private let alerts: MonitorAlerts

    init(alerts: MonitorAlerts) {
        self.alerts = alerts
    }

    func start() { alerts.setOn(true) }
    func stop() { alerts.setOn(false) }

    static func register(in registry: FeatureRegistry, alerts: MonitorAlerts) {
        registry.register(FeatureDescriptor(id: "monitor.alerts", category: .menuBar, permissions: [.notifications])) {
            AlertsFeature(alerts: alerts)
        }
    }
}
