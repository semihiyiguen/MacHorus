// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var featureController: FeatureController?
    private var menuBarReadouts: MenuBarReadouts?
    private var monitorAlerts: MonitorAlerts?
    private var tools: ToolsModels?
    private var loginItem: LoginItemController?
    private var previewWindow: NSWindow?
    private var interactionBenchmark: InteractionBenchmark?

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Launching \(AppIdentity.currentVersion().description, privacy: .public)")
        // `kill` (e.g. an installer replacing the app) quits like ⌘Q, so
        // features undo what they changed (microphones, keep awake).
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination

        let policy = PolicyLoader.load()
        let registry = FeatureRegistry()
        var privateAPIs = Set(PrivateAPI.allCases).filter(policy.allows)
        // `-debug.interfaceCounters YES` shows the network fallback without a
        // policy file; it can only switch the private interface off, never on.
        if UserDefaults.standard.bool(forKey: "debug.interfaceCounters") { privateAPIs.remove(.networkStatistics) }
        let monitor = SystemMonitorModel(privateAPIs: privateAPIs)
        // What this Mac can measure decides which features exist at all.
        let hardware = HardwareCapabilities.probe(
            allowHIDSensors: privateAPIs.contains(.hidSensors), allowSMC: privateAPIs.contains(.smc))
        Log.app.notice(
            "Hardware: temperatures \(hardware.temperatureGroups.count, privacy: .public) groups, fans \(hardware.fanCount, privacy: .public), GPU statistics \(hardware.hasGPUStatistics, privacy: .public), battery \(hardware.hasBattery, privacy: .public)"
        )
        monitor.hardware = hardware
        MonitorSystemFeature.register(in: registry, monitor: monitor, hardware: hardware)
        let screen = ScreenAvailability()
        let readouts = MenuBarReadouts(monitor: monitor, screen: screen, hardware: hardware)
        MenuBarFeature.register(in: registry, readouts: readouts)
        let alerts = MonitorAlerts(monitor: monitor, screen: screen, readouts: readouts)
        AlertsFeature.register(in: registry, alerts: alerts)
        menuBarReadouts = readouts
        monitorAlerts = alerts
        // Grouping helpers under their app follows the policy's kill switch.
        let responsibility = privateAPIs.contains(.processResponsibility) ? ProcessResponsibility() : nil
        let microphones = MicrophoneController()
        microphones.responsibility = responsibility
        let tools = ToolsModels(
            keepAwake: KeepAwakeController(), microphones: microphones, updates: SoftwareUpdatesModel(),
            ports: PortsModel(), mixer: AudioMixerController(responsibility: responsibility),
            devices: AudioDeviceController(),
            clipboard: ClipboardController(
                screen: screen,
                pasteboard: UserDefaults.standard.string(forKey: "debug.clipboardName").map {
                    NSPasteboard(name: NSPasteboard.Name($0))
                } ?? .general),
            network: NetworkCheckModel(), drives: DrivesModel(), hardware: HardwareModel(), printers: PrintersModel())
        KeepAwakeFeature.register(in: registry, controller: tools.keepAwake)
        MicrophoneFeature.register(in: registry, controller: tools.microphones)
        SoftwareUpdatesFeature.register(in: registry, model: tools.updates)
        PortsFeature.register(in: registry, model: tools.ports)
        AudioMixerFeature.register(in: registry, controller: tools.mixer)
        AudioDeviceFeature.register(in: registry, controller: tools.devices)
        ClipboardFeature.register(in: registry, controller: tools.clipboard)
        NetworkCheckFeature.register(in: registry, model: tools.network)
        SimpleToolFeature.register(
            in: registry, drives: tools.drives, hardware: tools.hardware, printers: tools.printers)
        self.tools = tools
        // Keep awake and muted microphones are visible next to the eye.
        let showIndicators: @MainActor () -> Void = { [weak readouts] in
            var indicators: [MenuBarIndicator] = []
            if tools.keepAwake.isActive {
                indicators.append(
                    MenuBarIndicator(symbol: "cup.and.saucer.fill", label: String(localized: "tools.keepAwake.title")))
            }
            if tools.microphones.isMuted {
                indicators.append(
                    MenuBarIndicator(symbol: "mic.slash.fill", label: String(localized: "tools.mic.allMuted")))
            }
            readouts?.setIndicators(indicators)
        }
        tools.keepAwake.onChange(showIndicators)
        tools.microphones.onChange(showIndicators)
        let controller = FeatureController(registry: registry, settings: SettingsStore(), policy: policy)
        controller.apply()
        featureController = controller

        let loginItem = LoginItemController()
        loginItem.applyFirstLaunchDefault()
        self.loginItem = loginItem

        let model = PanelModel(
            featureController: controller, monitor: monitor, readouts: readouts, alerts: alerts, tools: tools,
            loginItem: loginItem)
        let statusItem = StatusItemController(model: model)
        statusItemController = statusItem
        readouts.attach(statusItem.item)
        // A click on an alert notification opens the panel on its page.
        alerts.setOpener { [weak statusItem, weak model] target in
            guard let statusItem, let model else { return }
            switch target {
            case .monitor:
                statusItem.showPanel(tab: .monitor)
            case .alertSettings:
                model.navigation.settingsSection = .alerts
                statusItem.showPanel(tab: .settings)
            }
        }

        runDevelopmentAids(statusItem: statusItem, featureController: controller, monitor: monitor)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stopping restores muted microphones and ends keep awake.
        featureController?.registry.stopAll()
    }

    /// Launch arguments for checking the UI without clicking:
    /// - `-debug.appearance dark|light` forces an appearance,
    /// - `-debug.panelWindow <tab>` shows the panel in a regular window (for
    ///   screenshots when the menu bar is hidden), `-debug.pageHeight <pt>`
    ///   makes its page taller,
    /// - `-debug.renderPanel <file.png>` (with `-debug.panelWindow`) saves
    ///   that window's content after 4 s (`-debug.renderDelay <s>`) and
    ///   quits; drawn in-process, so it also works with a locked screen,
    /// - `-debug.showPanel <tab>` opens the real popover (after
    ///   `-debug.showPanelDelay <s>`, default 1); `-debug.panelCycle <s>`
    ///   then closes and reopens it every `<s>` seconds (`-debug.panelToggles
    ///   <n>` stops after n changes), to measure opening and idle costs;
    ///   `-debug.interactionBench all|<scenario,…>` instead measures each
    ///   interaction (tab, expand, sort, search, scroll …) and quits.
    private func runDevelopmentAids(
        statusItem: StatusItemController, featureController: FeatureController, monitor: SystemMonitorModel
    ) {
        let defaults = UserDefaults.standard
        // The user's choice in the settings; `-debug.appearance` overrides it.
        AppearanceChoice.stored.apply()
        switch defaults.string(forKey: "debug.appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // `-debug.processSort memory` opens the process list sorted by memory.
        if let sort = defaults.string(forKey: "debug.processSort").flatMap(ProcessOrder.init(rawValue:)) {
            monitor.processSort = sort
        }
        // `-debug.processCPUValue total`, `-debug.processMemoryValue peak`,
        // `-debug.processKind apps|background`: the title menus' choices (renders).
        if let value = defaults.string(forKey: "debug.processCPUValue").flatMap(ProcessCPUValue.init(rawValue:)) {
            monitor.processCPUValue = value
        }
        if let value = defaults.string(forKey: "debug.processMemoryValue").flatMap(ProcessMemoryValue.init(rawValue:)) {
            monitor.processMemoryValue = value
        }
        if let kind = defaults.string(forKey: "debug.processKind").flatMap(ProcessKind.init(rawValue:)) {
            monitor.processKind = kind
        }
        // `-debug.trafficSpan sinceStart` shows network totals; `-debug.openDetails YES`
        // opens the details of the busiest CPU row after 3 s.
        if defaults.string(forKey: "debug.trafficSpan") == "sinceStart" { monitor.traffic.span = .sinceStart }
        if defaults.bool(forKey: "debug.openDetails") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if let row = monitor.processes?.top(.cpu, limit: 1).first {
                    monitor.expandedProcessRow = "\(row.identity.pid).\(row.identity.started)"
                }
            }
        }
        // `-debug.keepAwake <minutes>` (0: unlimited) and `-debug.muteMicrophones YES`
        // take the same path as the buttons, for checks with pmset and CoreAudio.
        if let tools, defaults.object(forKey: "debug.keepAwake") != nil {
            let minutes = defaults.double(forKey: "debug.keepAwake")
            tools.keepAwake.start(duration: minutes > 0 ? minutes * 60 : nil)
        }
        if let tools, defaults.bool(forKey: "debug.muteMicrophones") { tools.microphones.setMuted(true) }
        // `-debug.quickClipboard <file.png>` opens the shortcut's window at
        // the pointer, saves it after 3 s and quits.
        if let path = defaults.string(forKey: "debug.quickClipboard") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.statusItemController?.toggleClipboard()
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }) {
                    Self.render(window, to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        // `-debug.clipboardPick <n> -debug.clipboardPickAfter <s>` puts the
        // n-th history entry back like a click (for checks with the trace).
        if let tools, defaults.object(forKey: "debug.clipboardPick") != nil {
            let index = defaults.integer(forKey: "debug.clipboardPick")
            let delay = max(defaults.double(forKey: "debug.clipboardPickAfter"), 1)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let entries = tools.clipboard.history.entries
                if entries.indices.contains(index) { tools.clipboard.pick(entries[index].id) }
            }
        }
        // `-debug.mixerMute <app id>` mutes one app through the mixer (feature on).
        if let tools, let id = defaults.string(forKey: "debug.mixerMute") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                tools.mixer.toggleMute(id)
            }
        }
        // `-debug.renderStatusImage <file.png>` saves the menu bar image after
        // 3 s on a light and a dark strip (also with a locked screen) and quits.
        if let path = defaults.string(forKey: "debug.renderStatusImage") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if let image = statusItem.item.button?.image {
                    Self.renderStatusImage(image, to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        // `-debug.mixerSelfTest <log> -debug.mixerSelfTestPID <pid>` taps a playing
        // process at 25 % and 0 %, then mutes it, logs the peaks and quits.
        // Launched with `open`, so the consent dialog is MacHorus' own.
        if let log = defaults.string(forKey: "debug.mixerSelfTest") {
            let pid = pid_t(defaults.integer(forKey: "debug.mixerSelfTestPID"))
            Task { @MainActor in
                await MixerSelfTest.run(pid: pid, log: URL(fileURLWithPath: log))
                NSApp.terminate(nil)
            }
        }
        // `-debug.openAtLogin on|off|first -debug.openAtLoginReport <file>` switches
        // "Open at login" like the settings ("first": as an installed copy's first
        // launch), writes the state read back and quits.
        if let loginItem, let action = defaults.string(forKey: "debug.openAtLogin") {
            switch action {
            case "on": loginItem.setOn(true)
            case "off": loginItem.setOn(false)
            case "first":
                loginItem.applyFirstLaunchDefault(bundleURL: URL(fileURLWithPath: "/Applications/MacHorus.app"))
            default: break
            }
            let report = "state=\(loginItem.state.rawValue) decided=\(defaults.bool(forKey: OpenAtLogin.decidedKey))\n"
            if let path = defaults.string(forKey: "debug.openAtLoginReport") {
                try? Data(report.utf8).write(to: URL(fileURLWithPath: path))
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
        // `-debug.restartReasons YES` opens the reasons of the restart advice.
        monitor.showsRestartReasons = defaults.bool(forKey: "debug.restartReasons")
        // `-debug.processQuery <text>` opens the process list filtered.
        if let query = defaults.string(forKey: "debug.processQuery") { monitor.processQuery = query }
        if let tab = defaults.string(forKey: "debug.panelWindow").flatMap(PanelTab.init(rawValue:)) {
            let model = PanelModel(
                featureController: featureController, monitor: monitor, readouts: menuBarReadouts,
                alerts: monitorAlerts,
                tools: tools, loginItem: loginItem)
            model.navigation.tab = tab
            // `-debug.arrangeMonitor YES` opens the shown page in arrange mode
            // (`-debug.addWidget YES` with the add list open).
            if defaults.bool(forKey: "debug.arrangeMonitor") {
                model.widgets.editing = model.widgetPage
                model.widgets.isAdding = defaults.bool(forKey: "debug.addWidget")
            }
            // `-debug.dragDemo <widget>` (with arrange mode) holds that widget
            // after 2 s and moves it slowly to the end of the page, as a
            // pointer would; each new order is printed, it stays held for
            // the render.
            if let kind = defaults.string(forKey: "debug.dragDemo").flatMap(WidgetKind.init(rawValue:)) {
                model.widgets.persists = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    Self.dragDemo(kind, model: model)
                }
            }
            // `-debug.openWidget <widget>` opens that widget in place after 2 s (renders).
            if let kind = defaults.string(forKey: "debug.openWidget").flatMap(WidgetKind.init(rawValue:)) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { model.widgets.peeking = kind }
                }
            }
            // `-debug.settingsSection features|privacy|about`
            if let section = defaults.string(forKey: "debug.settingsSection").flatMap(SettingsSection.init(rawValue:)) {
                model.navigation.settingsSection = section
            }
            model.setVisible(true)
            let height = defaults.double(forKey: "debug.pageHeight")
            let root = PanelRootView(model: model, pageHeight: height > 0 ? height : nil)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacHorus Panel Preview"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            if let path = defaults.string(forKey: "debug.renderPanel") {
                // Long enough for the monitor's first rounds.
                let delay = defaults.double(forKey: "debug.renderDelay")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay > 0 ? delay : 4))
                    Self.render(window, to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
        // `-debug.printSelfUsage YES` prints the panel's self-usage values every
        // 2 s so they can be compared with `footprint` and `top`.
        if defaults.bool(forKey: "debug.printSelfUsage") {
            var sampler = SelfUsageSampler()
            let timer = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let usage = sampler.sample() else { return }
                    let cpu = usage.cpuPercent.map { String(format: "%.1f", $0) } ?? "-"
                    print("selfUsage cpu=\(cpu)% footprint=\(usage.footprintBytes / 1_048_576)MB", terminator: "\n")
                    fflush(stdout)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        if let tab = defaults.string(forKey: "debug.showPanel").flatMap(PanelTab.init(rawValue:)) {
            // `-debug.showPanelDelay <s>` measures opening apart from launching.
            let delay = max(defaults.double(forKey: "debug.showPanelDelay"), 1)
            Task { @MainActor in
                // The status item needs a moment to get its place in the menu bar.
                try? await Task.sleep(for: .seconds(delay))
                statusItem.showPanel(tab: tab)
                if let selection = defaults.string(forKey: "debug.interactionBench") {
                    // The status item lives as long as the app.
                    let benchmark = InteractionBenchmark(model: statusItem.panelModel) { statusItem.panelView }
                    self.interactionBenchmark = benchmark
                    await benchmark.run(selection)
                    return
                }
                let cycle = defaults.double(forKey: "debug.panelCycle")
                // `-debug.panelToggles <n>` stops after n changes (1: close once and stay closed).
                var toggles = defaults.integer(forKey: "debug.panelToggles")
                while cycle > 0, toggles != 0 || defaults.object(forKey: "debug.panelToggles") == nil {
                    try? await Task.sleep(for: .seconds(cycle))
                    statusItem.isPanelShown ? statusItem.closePanel() : statusItem.showPanel(tab: tab)
                    toggles -= 1
                }
            }
        }
    }

    private static func renderStatusImage(_ image: NSImage, to url: URL) {
        let scale: CGFloat = 4
        let size = NSSize(width: image.size.width + 8, height: image.size.height)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = NSSize(width: size.width, height: size.height * 2)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A template image is drawn in the menu bar's colour: black on light, white on dark.
        for (index, colors) in [(NSColor.white, NSColor.black), (NSColor(white: 0.12, alpha: 1), NSColor.white)]
            .enumerated()
        {
            let strip = NSRect(x: 0, y: CGFloat(index) * size.height, width: size.width, height: size.height)
            colors.0.setFill()
            strip.fill()
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                colors.1.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 4, y: strip.minY, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// See `-debug.dragDemo`: the same calls a real drag makes, with the
    /// frames of the fixed grid; prints each new landing place and, at the
    /// end, the order the page would get. It stays held for the render.
    private static func dragDemo(_ kind: WidgetKind, model: PanelModel) {
        let widgets = model.widgets
        guard let page = model.widgetPage else { return }
        let width: PanelWidth = model.navigation.isExpanded ? .expanded : .compact
        let items = widgets.layout(page, width).items
        let metrics = WidgetGridMetrics(
            width: (width == .expanded ? Theme.expandedPanelWidth : Theme.panelWidth) - 32,
            columns: WidgetLayout.columns(width))
        let frames = WidgetLayout.place(items, width: width).mapValues(metrics.rect)
        guard let frame = frames[kind], let bottom = frames.values.map(\.maxY).max() else { return }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        widgets.beginDragging(
            kind, grab: CGSize(width: frame.width / 2, height: frame.height / 2), frames: frames, items: items,
            width: width, toGrid: metrics.gridPoint)
        print("dragDemo start \(items.map(\.kind.rawValue))")
        Task { @MainActor in
            var last = widgets.drop
            var changes = 0
            let steps = 150
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: start.x + 40 * sin(CGFloat(step) / 6), y: start.y + (bottom - 40 - start.y) * t)
                widgets.dragMoved(to: point)
                if widgets.drop != last {
                    print("dragDemo drop \(String(describing: widgets.drop))")
                    last = widgets.drop
                }
                if widgets.layout(page, width).items != items { changes += 1 }
                try? await Task.sleep(for: .milliseconds(16))
            }
            var landed = widgets.layout(page, width)
            if let drop = widgets.drop { landed.apply(drop, moving: kind) }
            print("dragDemo pageChangesWhileDragging=\(changes)")
            print("dragDemo end \(landed.kinds.map(\.rawValue))")
            fflush(stdout)
        }
    }

    private static func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("Could not render the panel\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // The window's background is not part of the view: draw it below,
        // otherwise light text ends up on a transparent image.
        let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)
        output?.size = bitmap.size
        if let output, let context = NSGraphicsContext(bitmapImageRep: output) {
            var background = NSColor.windowBackgroundColor
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? background
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            background.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill()
            // Plain `draw(in:)` copies, which would replace the background.
            bitmap.draw(
                in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        do {
            guard let png = (output ?? bitmap).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write \(url.path): \(error)\n".utf8))
        }
    }
}
