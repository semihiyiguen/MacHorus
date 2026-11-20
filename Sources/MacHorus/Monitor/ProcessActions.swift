// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusMonitor

/// Names, icons and actions for process rows. Every action first checks
/// (`ProcessInspector.canSignal`) that the PID still belongs to the same
/// process and to this user; other users' processes are never touched.
@MainActor
enum ProcessActions {
    private static var icons: [ProcessIdentity: NSImage] = [:]
    private static var names: [ProcessIdentity: String] = [:]

    static func app(for identity: ProcessIdentity) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: identity.pid).flatMap { $0.isTerminated ? nil : $0 }
    }

    static func name(for row: ProcessUsage) -> String {
        if let name = names[row.identity] { return name }
        let name = app(for: row.identity)?.localizedName ?? row.name
        // Searching names every row (about 150), so keep more than the list shows.
        if names.count > 512 { names.removeAll() }
        names[row.identity] = name
        return name
    }

    /// The app icon as a small bitmap, drawn once: scaling the full icon on
    /// every refresh cost measurable CPU.
    static func icon(for identity: ProcessIdentity) -> NSImage {
        if let icon = icons[identity] { return icon }
        let source =
            DemoMode.icon(for: identity.pid) ?? app(for: identity)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let icon = ImageThumbnail.make(source, points: 18)
        // Rows change slowly; a small cache is enough.
        if icons.count > 64 { icons.removeAll() }
        icons[identity] = icon
        return icon
    }

    /// Builds the row menu only when it is opened; SwiftUI `Menu`s in every
    /// row were rebuilt on each refresh.
    static func showMenu(for row: ProcessUsage) {
        let menu = NSMenu()
        let target = MenuTarget()
        func add(_ key: String, _ action: @escaping @MainActor () -> Void) {
            let item = NSMenuItem(title: localized(key), action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = MenuTarget.Action(run: action)
            menu.addItem(item)
        }
        if canActivate(row.identity) { add("monitor.processes.activate") { activate(row.identity) } }
        add("monitor.processes.quit") { quit(row) }
        add("monitor.processes.forceQuit") { forceQuit(row) }
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func canAct(on identity: ProcessIdentity) -> Bool {
        ProcessInspector.canSignal(identity)
    }

    static func canActivate(_ identity: ProcessIdentity) -> Bool {
        app(for: identity)?.activationPolicy == .regular
    }

    /// Brings the app to the front. Since macOS 14 an app in the background
    /// may not activate another one directly (`activate()` was ignored, so
    /// the button did nothing); opening the app through the workspace
    /// always activates it. The panel closes so the app is visible.
    static func activate(_ identity: ProcessIdentity) {
        guard canActivate(identity), let app = app(for: identity) else { return }
        PanelFocus.close()
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    /// Apps are asked to quit like ⌘Q (they may ask to save). Other processes
    /// get SIGTERM after a confirmation, because an app may depend on them.
    static func quit(_ row: ProcessUsage) {
        guard canAct(on: row.identity) else { return }
        if let app = app(for: row.identity), app.activationPolicy == .regular {
            app.terminate()
            return
        }
        guard
            confirm(
                title: format("monitor.processes.confirm.quit %@", name(for: row)),
                message: "monitor.processes.confirm.quit.message", action: "monitor.processes.quit"),
            canAct(on: row.identity)
        else { return }
        ProcessInspector.send(SIGTERM, to: row.identity)
    }

    static func forceQuit(_ row: ProcessUsage) {
        guard canAct(on: row.identity),
            confirm(
                title: format("monitor.processes.confirm.forceQuit %@", name(for: row)),
                message: "monitor.processes.confirm.forceQuit.message", action: "monitor.processes.forceQuit.button"),
            // The dialog took time: check the identity again right before.
            canAct(on: row.identity)
        else { return }
        if let app = app(for: row.identity) {
            app.forceTerminate()
        } else {
            ProcessInspector.send(SIGKILL, to: row.identity)
        }
    }

    private static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = localized(message)
        alert.addButton(withTitle: localized(action)).hasDestructiveAction = true
        alert.addButton(withTitle: localized("monitor.processes.cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func format(_ key: String, _ value: String) -> String {
        localized(key).replacingOccurrences(of: "%@", with: value)
    }
}

/// Runs the closure stored in a menu item.
@MainActor
private final class MenuTarget: NSObject {
    final class Action {
        let run: @MainActor () -> Void
        init(run: @escaping @MainActor () -> Void) { self.run = run }
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }
}
