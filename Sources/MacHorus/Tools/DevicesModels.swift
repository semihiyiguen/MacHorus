// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusTools
import Observation

/// External drives with an eject button. Read when the card appears and
/// when macOS reports a volume coming or going; nothing in the background.
@MainActor
@Observable
final class DrivesModel {
    var isEnabled = false
    private(set) var drives: [ConnectedDevices.Drive] = []
    private(set) var ejecting: Set<URL> = []
    /// The drive that could not be ejected, and why (usually: in use).
    private(set) var failed: URL?

    @ObservationIgnored private let refresher = SerialRefresh()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func refresh() {
        refresher.run { [weak self] in
            let read = await OffMain.run { ConnectedDevices.externalDrives() }
            guard let self else { return }
            if read != drives { drives = read }
        }
    }

    /// While the card shows: follow mounts and unmounts.
    func startWatching() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        refresh()
    }

    func stopWatching() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    /// Unmounts and ejects like Finder; a drive in use stays mounted and
    /// the card says so (nothing is forced: forcing can lose data).
    func eject(_ drive: ConnectedDevices.Drive) {
        guard !ejecting.contains(drive.url) else { return }
        ejecting.insert(drive.url)
        failed = nil
        let url = drive.url
        Task {
            let ok = await OffMain.run { () -> Bool in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return true
                } catch {
                    return false
                }
            }
            ejecting.remove(url)
            if !ok {
                failed = url
                Log.features.notice("A drive could not be ejected (in use)")
            }
            refresh()
        }
    }
}

/// Displays, power adapter, USB devices and docks. Read when the card
/// appears and when displays change.
@MainActor
@Observable
final class HardwareModel {
    struct Display: Equatable, Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let pixels: String
        let hertz: Int?
        let isBuiltIn: Bool
    }

    var isEnabled = false
    private(set) var displays: [Display] = []
    private(set) var usb: [ConnectedDevices.USBDevice] = []
    private(set) var adapter: ConnectedDevices.PowerAdapter?

    @ObservationIgnored private let refresher = SerialRefresh()

    func refresh() {
        let screens = NSScreen.screens.compactMap(Self.display)
        if screens != displays { displays = screens }
        refresher.run { [weak self] in
            let (usb, adapter) = await OffMain.run { (ConnectedDevices.usbDevices(), ConnectedDevices.powerAdapter()) }
            guard let self else { return }
            if usb != self.usb { self.usb = usb }
            if adapter != self.adapter { self.adapter = adapter }
        }
    }

    private static func display(_ screen: NSScreen) -> Display? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        let mode = CGDisplayCopyDisplayMode(id)
        let width = mode.map { $0.pixelWidth } ?? Int(screen.frame.width * screen.backingScaleFactor)
        let height = mode.map { $0.pixelHeight } ?? Int(screen.frame.height * screen.backingScaleFactor)
        let hertz = screen.maximumFramesPerSecond
        return Display(
            id: id, name: screen.localizedName, pixels: "\(width) × \(height)", hertz: hertz > 0 ? hertz : nil,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }
}

/// Printers and the user's print jobs; read every 5 s while the card shows.
@MainActor
@Observable
final class PrintersModel {
    static let interval: Duration = .seconds(5)

    var isEnabled = false
    private(set) var printers: [PrintQueue.Printer] = []
    private(set) var jobs: [PrintQueue.Job] = []
    private(set) var cancelFailed: Int32?

    func refresh() async {
        let (printers, jobs) = await OffMain.run { (PrintQueue.printers(), PrintQueue.jobs()) }
        if printers != self.printers { self.printers = printers }
        if jobs != self.jobs { self.jobs = jobs }
    }

    func cancel(_ job: PrintQueue.Job) {
        cancelFailed = nil
        Task {
            let ok = await OffMain.run { PrintQueue.cancel(job) }
            if !ok { cancelFailed = job.id }
            await refresh()
        }
    }

    func isStuck(_ job: PrintQueue.Job) -> Bool { PrintQueue.isStuck(job, printers: printers) }
}

@MainActor
final class SimpleToolFeature: FeatureModule {
    private let setEnabled: @MainActor (Bool) -> Void

    init(_ setEnabled: @escaping @MainActor (Bool) -> Void) {
        self.setEnabled = setEnabled
    }

    func start() { setEnabled(true) }
    func stop() { setEnabled(false) }

    static func register(
        in registry: FeatureRegistry, drives: DrivesModel, hardware: HardwareModel, printers: PrintersModel
    ) {
        registry.register(FeatureDescriptor(id: "tools.drives", category: .tools)) {
            SimpleToolFeature { drives.isEnabled = $0 }
        }
        registry.register(FeatureDescriptor(id: "tools.hardware", category: .tools)) {
            SimpleToolFeature { hardware.isEnabled = $0 }
        }
        registry.register(FeatureDescriptor(id: "tools.printers", category: .tools)) {
            SimpleToolFeature { printers.isEnabled = $0 }
        }
    }
}
