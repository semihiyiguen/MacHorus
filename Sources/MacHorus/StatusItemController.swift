// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import ObjectiveC
import SwiftUI

/// Owns the menu bar item: left click toggles the panel, right click opens
/// the context menu. Everything, settings included, lives in the panel.
///
/// From macOS 27 on, the panel is the item's "expanded interface": the menu
/// bar opens and closes it and knows when it is shown. Toggled by
/// target/action instead, macOS 27 keeps the menu bar of a full-screen app
/// shown after the panel closed.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var item: NSStatusItem { statusItem }
    /// For the interaction benchmark (`-debug.interactionBench`).
    var panelModel: PanelModel { model }
    var panelView: NSView? { popover.contentViewController?.view }
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private let model: PanelModel
    /// The menu bar runs the panel as an expanded interface session (macOS 27).
    private var usesExpandedInterface = false
    /// Clicks in other apps while the panel shows: macOS 27 leaves closing
    /// the panel on such clicks to the app.
    private var outsideClickMonitor: Any?
    /// Esc, ⌘1–4 and ⌘, while the panel is shown (its own keys, no permission).
    private var keyMonitor: Any?
    private var isShowingMenu = false
    /// A menu item asked for the panel; it opens once the menu has closed.
    private var pendingMenuOpen = false
    /// The status bar window's last right mouse down (see the session start).
    private var lastRightMouseDown: ContinuousClock.Instant?
    private var rightClickWatcher: Any?
    private let quickClipboard = QuickClipboardWindow()
    private var menuClosed: ContinuousClock.Instant?
    /// When the panel last began to close. The click on the eye that closes
    /// it can start a new session right after; that one is not a reopen.
    private var closeStarted: ContinuousClock.Instant?
    /// Drops pointer moves aimed at the status bar windows (see init).
    private var mouseMoveFilter: Any?
    /// `-debug.panelSessionTrace <file>`: how the panel opens and closes.
    private let trace = PanelSessionTrace(path: UserDefaults.standard.string(forKey: "debug.panelSessionTrace"))

    init(model: PanelModel) {
        self.model = model
        super.init()
        PanelFocus.makeKey = { [weak self] in self?.popover.contentViewController?.view.window?.makeKey() }
        PanelFocus.close = { [weak self] in self?.closePanel() }
        model.tools?.clipboard.shortcut.action = { [weak self] in self?.toggleClipboard() }
        configureButton()
        configurePopover()
        configureContextMenu()
        usesExpandedInterface = ExpandedInterface.adopt(statusItem, delegate: self)
        trace.note("expanded interface: \(usesExpandedInterface)")
        // macOS 27 hands every pointer move on screen to the app, routed to
        // a status bar window; AppKit then sets the cursor each time, and with
        // a customized pointer macOS redraws its image (measured: 15 % CPU
        // with the panel closed, 60 % with it open, while the mouse moves).
        // A move is kept only while the pointer is inside one of MacHorus'
        // own windows (the panel's hover effects need it); with the panel
        // open the event names the panel's window even when the pointer is
        // elsewhere, so the position decides, not the window.
        // Enter and exit events for the status bar windows go too; the
        // panel's own ones stay, its hover effects need them.
        // Right clicks on the eye: remembered, because the session callback
        // carries no event on macOS 27.
        rightClickWatcher = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            if event.window?.className.hasPrefix("NSStatusBar") == true {
                MainActor.assumeIsolated { self?.lastRightMouseDown = .now }
            }
            return event
        }
        mouseMoveFilter = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) {
            event in
            guard let window = event.window, !window.className.hasPrefix("NSStatusBar") else { return nil }
            guard event.type == .mouseMoved else { return event }
            guard let content = window.contentView,
                content.bounds.contains(content.convert(event.locationInWindow, from: nil))
            else { return nil }
            return event
        }
    }

    /// Opens the panel, optionally on a given section (e.g. ⌘, → features).
    func showPanel(tab: PanelTab? = nil) {
        if let tab { model.navigation.tab = tab }
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePanel() {
        popover.performClose(nil)
    }

    /// The clipboard shortcut: a small window with only the history, at
    /// the mouse pointer; pressed again, it closes. It never touches the
    /// menu bar panel (its interface session made the panel flicker).
    func toggleClipboard() {
        guard let clipboard = model.tools?.clipboard else { return }
        if popover.isShown { closePanel() }
        quickClipboard.toggle(controller: clipboard)
    }

    var isPanelShown: Bool { popover.isShown }

    func popoverWillShow(_ notification: Notification) {
        trace.note("panel shown, session open: \(ExpandedInterface.hasSession(statusItem))")
        model.setVisible(true)
    }

    func popoverDidShow(_ notification: Notification) {
        // Clicks on buttons do not make the panel key (a key panel makes
        // AppKit set the pointer on every refresh, and with a customized
        // pointer macOS rebuilds its image each time, docs/MEASUREMENTS.md);
        // it is key once on opening, so the keyboard works right away.
        let window = popover.contentViewController?.view.window
        (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true
        window?.makeKey()
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let key = PanelKey(
                    code: event.keyCode, flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                    characters: event.charactersIgnoringModifiers, windowNumber: event.windowNumber)
                let handled = MainActor.assumeIsolated { self?.handleKey(key) ?? false }
                return handled ? nil : event
            }
        }
        if usesExpandedInterface, outsideClickMonitor == nil {
            // Mouse events need no permission (key events would).
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.trace.note("click outside")
                    self?.popover.performClose(nil)
                }
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        closeStarted = .now
    }

    func popoverDidClose(_ notification: Notification) {
        model.setVisible(false)
        model.monitor.processSearchActive = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        // Closed by a click elsewhere, Esc or a button: the menu bar must
        // learn it, otherwise it stays as if the panel were open.
        let open = ExpandedInterface.hasSession(statusItem)
        trace.note("panel closed, session open: \(open)")
        if open { ExpandedInterface.cancelSession(statusItem) }
    }

    /// Esc closes (a search field with text clears first), ⌘1–4 switch the
    /// sections, ⌘, opens the settings. Everything else goes on as usual.
    private func handleKey(_ key: PanelKey) -> Bool {
        guard popover.isShown, let window = popover.contentViewController?.view.window,
            key.windowNumber == window.windowNumber
        else { return false }
        if let recorder = PanelFocus.recorder { return recorder(key.code, key.flags) }
        if key.code == 53, key.flags.isEmpty {  // Esc
            if let editor = window.firstResponder as? NSTextView, !editor.string.isEmpty { return false }
            closePanel()
            return true
        }
        guard key.flags == .command, let characters = key.characters else { return false }
        if let number = Int(characters), (1...PanelTab.allCases.count).contains(number) {
            model.navigation.tab = PanelTab.allCases[number - 1]
            return true
        }
        if characters == "," {
            model.navigation.settingsSection = .features
            model.navigation.tab = .settings
            return true
        }
        return false
    }

    // MARK: Expanded interface (macOS 27, NSStatusItemExpandedInterfaceDelegate)

    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItem(_ item: NSStatusItem, didBeginExpandedInterfaceSession session: NSObject) {
        let event = NSApp.currentEvent
        // macOS 27 begins the session without a current event (seen in the
        // trace: "event: none"), so a right click is told by the buttons
        // held now, a right click the status bar window just received, or ⌃.
        let rightHeld = NSEvent.pressedMouseButtons & 0b10 != 0
        let recentRight = lastRightMouseDown.map { ContinuousClock.now - $0 < .milliseconds(600) } ?? false
        let control = NSEvent.modifierFlags.contains(.control)
        trace.note(
            "session began, event: \(event.map { String(describing: $0.type) } ?? "none"), right held: \(rightHeld), recent right: \(recentRight), control: \(control)"
        )
        if rightHeld || recentRight || control || event?.type == .rightMouseDown || event?.type == .rightMouseUp {
            lastRightMouseDown = nil
            ExpandedInterface.cancelSession(statusItem)
            // After the session callback returns, so the system has finished
            // with this click before the menu tracks the mouse.
            DispatchQueue.main.async { [weak self] in self?.showContextMenu() }
            return
        }
        if pendingMenuOpen {
            // The menu asked for the panel (settings): this session shows it.
            pendingMenuOpen = false
            trace.note("session after the menu: opens the requested panel")
            showPanel()
            return
        }
        if isShowingMenu || menuClosed.map({ ContinuousClock.now - $0 < .milliseconds(400) }) == true {
            // A click that only closed the menu.
            trace.note("session right after the menu: cancelled")
            ExpandedInterface.cancelSession(statusItem)
            return
        }
        if let closeStarted, ContinuousClock.now - closeStarted < .milliseconds(800) {
            // The same click that closed the panel; reopening would look as
            // if the eye did not close it.
            trace.note("session right after closing: cancelled")
            ExpandedInterface.cancelSession(statusItem)
            return
        }
        showPanel()
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ item: NSStatusItem, animated: Bool) {
        trace.note("session ended, panel shown: \(popover.isShown)")
        if popover.isShown { popover.performClose(nil) }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "eye",
            accessibilityDescription: String(localized: "statusItem.accessibilityLabel")
        )
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PanelRootView(model: model))
        // The popover follows the panel's size when it is expanded or reduced.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// Rebuilt for every right click, so the tool items show their state.
    private func configureContextMenu() {
        contextMenu.removeAllItems()
        if let tools = model.tools {
            if tools.microphones.isEnabled {
                let item = NSMenuItem(
                    title: String(localized: "menu.muteMicrophones"), action: #selector(toggleMicrophones),
                    keyEquivalent: "")
                item.target = self
                item.state = tools.microphones.isMuted ? .on : .off
                contextMenu.addItem(item)
            }
            if contextMenu.numberOfItems > 0 { contextMenu.addItem(.separator()) }
        }
        let settings = NSMenuItem(
            title: String(localized: "menu.settings"),
            action: #selector(openFeatures),
            keyEquivalent: ","
        )
        settings.target = self
        contextMenu.addItem(settings)
        contextMenu.addItem(.separator())
        contextMenu.addItem(
            NSMenuItem(
                title: String(localized: "menu.quit"),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ))
    }

    @objc private func toggleMicrophones() {
        guard let microphones = model.tools?.microphones else { return }
        microphones.setMuted(!microphones.isMuted)
    }

    /// From the menu: the panel opens once the menu has closed. On macOS 27
    /// closing the menu starts an interface session; that session opens the
    /// panel (cancelling it, as before, closed the panel after 0.5 s). Where
    /// no session comes, the panel opens by itself shortly after.
    @objc private func openFeatures() {
        model.navigation.settingsSection = .features
        model.navigation.tab = .settings
        pendingMenuOpen = true
        trace.note("settings from the menu: waiting for the menu to close")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, pendingMenuOpen else { return }
            pendingMenuOpen = false
            trace.note("settings from the menu: opened without a session")
            showPanel()
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        trace.note("button action: \(NSApp.currentEvent.map { String(describing: $0.type) } ?? "none")")
        // The release of the right click that already opened the menu.
        if let menuClosed, ContinuousClock.now - menuClosed < .milliseconds(400) { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if usesExpandedInterface {
            // The session opens and closes the panel.
            return
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// The menu pops up under the eye by itself. Attaching it to the item
    /// and simulating a click (as before) started a second interface session
    /// on macOS 27: the menu vanished at once or the panel opened instead.
    private func showContextMenu() {
        guard !isShowingMenu, let button = statusItem.button else { return }
        isShowingMenu = true
        defer {
            isShowingMenu = false
            menuClosed = .now
        }
        if popover.isShown { popover.performClose(nil) }
        configureContextMenu()
        trace.note("context menu opens")
        contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        trace.note("context menu closed")
    }
}

/// NSStatusItem's expanded interface API (macOS 27), called through the
/// Objective-C runtime because the build SDK is 26. On older systems
/// nothing changes and the button's target/action toggles the panel.
@MainActor
private enum ExpandedInterface {
    private static let setDelegate = NSSelectorFromString("setExpandedInterfaceDelegate:")
    private static let session = NSSelectorFromString("expandedInterfaceSession")
    private static let cancel = NSSelectorFromString("cancel")

    /// Makes `delegate` the item's expanded interface delegate; false where
    /// the system has no such API.
    static func adopt(_ item: NSStatusItem, delegate: NSObject) -> Bool {
        guard #available(macOS 27, *), item.responds(to: setDelegate), item.responds(to: session),
            let delegateProtocol = objc_getProtocol("NSStatusItemExpandedInterfaceDelegate")
        else { return false }
        class_addProtocol(type(of: delegate), delegateProtocol)
        _ = item.perform(setDelegate, with: delegate)
        return true
    }

    static func hasSession(_ item: NSStatusItem) -> Bool {
        currentSession(of: item) != nil
    }

    static func cancelSession(_ item: NSStatusItem) {
        guard let session = currentSession(of: item), session.responds(to: cancel) else { return }
        _ = session.perform(cancel)
    }

    private static func currentSession(of item: NSStatusItem) -> NSObject? {
        guard #available(macOS 27, *), item.responds(to: session) else { return nil }
        return item.perform(session)?.takeUnretainedValue() as? NSObject
    }
}

/// `-debug.panelSessionTrace <file>` writes how the panel opens and closes,
/// with seconds since launch, to check the menu bar's session by hand.
@MainActor
private final class PanelSessionTrace {
    private let handle: FileHandle?
    private let start = Date()

    init(path: String?) {
        guard let path, FileManager.default.createFile(atPath: path, contents: nil) else {
            handle = nil
            return
        }
        handle = FileHandle(forWritingAtPath: path)
    }

    func note(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data(String(format: "%7.2f %@\n", Date().timeIntervalSince(start), line()).utf8))
    }
}

/// The parts of a key press the panel needs (NSEvent is not Sendable).
private struct PanelKey: Sendable {
    let code: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String?
    let windowNumber: Int
}

/// Makes the panel key for typing. The panel is key only when needed (a key
/// panel costs CPU on every refresh, see popoverDidShow).
@MainActor
enum PanelFocus {
    static var makeKey: () -> Void = {}
    /// Closes the panel, e.g. after picking from the clipboard history.
    static var close: () -> Void = {}
    /// While a shortcut is being recorded, it gets every key press first.
    static var recorder: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
}
