// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusCore
import MacHorusMonitor
import MacHorusTools
import SwiftUI

/// The models behind the tools page, owned by the app delegate.
@MainActor
struct ToolsModels {
    let keepAwake: KeepAwakeController
    let microphones: MicrophoneController
    let updates: SoftwareUpdatesModel
    let ports: PortsModel
    let mixer: AudioMixerController
    let devices: AudioDeviceController
    let clipboard: ClipboardController
    let network: NetworkCheckModel
    let drives: DrivesModel
    let hardware: HardwareModel
    let printers: PrintersModel
}

struct CardHeader: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct KeepAwakeCard: View {
    let controller: KeepAwakeController

    var body: some View {
        PanelCard(spacing: 10) {
            CardHeader(
                symbol: controller.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                tint: controller.isActive ? Theme.gold : Theme.lapis,
                title: "tools.keepAwake.title", subtitle: status, tone: controller.isActive ? .accent : .neutral)
            HStack(spacing: 6) {
                ForEach(Array(KeepAwakeController.durations.enumerated()), id: \.offset) { _, duration in
                    let selected = controller.session.map { isSame($0, duration) } ?? false
                    Button {
                        selected ? controller.stop() : controller.start(duration: duration)
                    } label: {
                        Text(verbatim: KeepAwakeTexts.duration(duration))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Theme.goldText : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selected ? Theme.gold.opacity(0.18) : .primary.opacity(0.05)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            // One row: while an app runs, the display, and Stop when on.
            HStack(spacing: 8) {
                // Built when opened: the list of running apps is read only then.
                Menu {
                    ForEach(KeepAwakeController.runningApps(), id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "–") { controller.start(whileRunning: app) }
                    }
                } label: {
                    Label(
                        controller.watchedApp.map {
                            String(format: String(localized: "tools.keepAwake.whileApp %@"), $0.name)
                        } ?? String(localized: "tools.keepAwake.whileAppChoose"), systemImage: "app.badge.checkmark"
                    )
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle())
                .fixedSize()
                Spacer(minLength: 4)
                Toggle(
                    "tools.keepAwake.display",
                    isOn: Binding(get: { controller.keepsDisplayOn }, set: { controller.setKeepsDisplayOn($0) })
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
            }
            if controller.isActive {
                Button("tools.keepAwake.stop") { controller.stop() }
                    .buttonStyle(PillButtonStyle())
                    .font(.caption)
            }
        }
    }

    /// A chip is selected when the running session was started with it.
    private func isSame(_ session: KeepAwakeSession, _ duration: TimeInterval?) -> Bool {
        guard controller.watchedApp == nil else { return false }
        guard let ends = session.ends else { return duration == nil }
        guard let duration else { return false }
        return abs(ends.timeIntervalSince(session.started) - duration) < 1
    }

    private var status: String {
        guard let session = controller.session else { return String(localized: "tools.keepAwake.off") }
        if let app = controller.watchedApp {
            return String(format: String(localized: "tools.keepAwake.untilQuit %@"), app.name)
        }
        guard let ends = session.ends else { return String(localized: "tools.keepAwake.untilOff") }
        return String(localized: "tools.keepAwake.until \(ends.formatted(date: .omitted, time: .shortened))")
    }
}

enum KeepAwakeTexts {
    static func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "∞" }
        let minutes = Int(duration / 60)
        return minutes < 60
            ? String(localized: "tools.keepAwake.minutes \(String(minutes))")
            : String(localized: "tools.keepAwake.hours \(String(minutes / 60))")
    }
}

struct UpdatesCard: View {
    let model: SoftwareUpdatesModel

    var body: some View {
        PanelCard(spacing: 10) {
            CardHeader(
                symbol: "arrow.down.app",
                tint: (model.updates?.count ?? 0) > 0 ? Theme.gold : Theme.lapis,
                title: "tools.updates.title", subtitle: status,
                tone: (model.updates?.count ?? 0) > 0 ? .accent : .neutral)
            if let updates = model.updates {
                ForEach(Array((updates.munkiItems + updates.appleUpdates).prefix(6).enumerated()), id: \.offset) {
                    _, item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isRemoval ? "trash" : "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(verbatim: item.name).font(.caption).lineLimit(1)
                        if let version = item.version {
                            Text(verbatim: version).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.restart >= .recommended {
                            StatusChip(
                                text: String(localized: "tools.updates.restart"), symbol: "arrow.clockwise",
                                tone: .attention)
                        }
                    }
                }
                if !updates.problemItems.isEmpty {
                    Label(
                        String(localized: "tools.updates.problems \(updates.problemItems.joined(separator: ", "))"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(model.isMunkiInstalled ? "tools.updates.openMunki" : "tools.updates.openSystem") {
                model.openUpdater()
            }
            .buttonStyle(PillButtonStyle())
            .font(.caption)
        }
        .onAppear { model.refresh() }
    }

    private var status: String {
        guard let updates = model.updates else { return String(localized: "tools.updates.unknown") }
        let count =
            updates.count == 0
            ? String(localized: "tools.updates.none")
            : String(localized: "tools.updates.count \(String(updates.count))")
        guard let check = updates.lastCheck else { return count }
        return count + " · "
            + String(localized: "tools.updates.checked \(check.formatted(.relative(presentation: .named)))")
    }
}

/// Small by default (one line with the count); the list opens on a click.
/// Mostly for developers, so it never takes much room.
struct PortsCard: View {
    let model: PortsModel
    @Environment(\.panelIsShown) private var panelIsShown
    @State private var isOpen = false

    var body: some View {
        PanelCard(spacing: 6) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.lapisSymbol)
                        .frame(width: 18)
                    Text("tools.ports.title").font(.callout.weight(.semibold))
                    Text(verbatim: "\(model.ports.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(model.ports.prefix(10), id: \.self) { port in
                    HStack(spacing: 8) {
                        Text(verbatim: ":\(port.port)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 46, alignment: .leading)
                        Text(verbatim: port.processName).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: port.isLoopbackOnly ? "lock" : "network")
                            .font(.caption2)
                            .foregroundStyle(port.isLoopbackOnly ? Color.secondary : Theme.attention)
                            .help(Text(port.isLoopbackOnly ? "tools.ports.local" : "tools.ports.network"))
                        Menu {
                            Button("tools.ports.open") { PortsModel.open(port) }
                            Button("tools.ports.copy") { PortsModel.copyAddress(port) }
                            Divider()
                            Button("monitor.processes.quit") { PortsModel.quit(port) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                if model.ports.isEmpty {
                    Text("tools.ports.none").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: panelIsShown) {
            while panelIsShown, !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: PortsModel.interval)
            }
        }
    }
}

/// "Is it me or the internet?": four steps on a click, each with its
/// result, and one sentence what it means.
struct NetworkCheckCard: View {
    let model: NetworkCheckModel

    var body: some View {
        PanelCard(spacing: 10) {
            CardHeader(
                symbol: "stethoscope", tint: tintColor, title: "tools.network.title", subtitle: subtitle,
                tone: tone)
            if let result = model.result {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(NetworkCheck.Step.allCases, id: \.self) { step in
                        StepRow(step: step, result: result)
                    }
                    if !result.vpnInterfaces.isEmpty {
                        Label {
                            Text(
                                verbatim: String(
                                    format: String(localized: "tools.network.vpn %@"),
                                    result.vpnInterfaces.joined(separator: ", ")))
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                model.run()
            } label: {
                HStack(spacing: 6) {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                        Text("tools.network.running")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text(model.result == nil ? "tools.network.run" : "tools.network.again")
                    }
                }
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(Theme.lapisDeep)
                .background(Capsule().fill(Theme.goldGradient))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            InfoNote(short: "tools.network.privacyShort", full: "tools.network.privacy")
        }
    }

    private var subtitle: String {
        guard let result = model.result else { return String(localized: "tools.network.subtitle") }
        return Self.verdict(result.verdict)
    }

    static func verdict(_ verdict: NetworkCheck.Verdict) -> String {
        switch verdict {
        case .allGood: return String(localized: "tools.network.verdict.allGood")
        case .routerSilent: return String(localized: "tools.network.verdict.routerSilent")
        case .noConnection: return String(localized: "tools.network.verdict.noConnection")
        case .noRouter: return String(localized: "tools.network.verdict.noRouter")
        case .noDNS: return String(localized: "tools.network.verdict.noDNS")
        case .noInternet: return String(localized: "tools.network.verdict.noInternet")
        case .loginPage: return String(localized: "tools.network.verdict.loginPage")
        }
    }

    private var tone: Tone {
        switch model.result?.verdict {
        case nil: .neutral
        case .allGood, .routerSilent: .positive
        case .loginPage: .attention
        default: .critical
        }
    }

    private var tintColor: Color {
        switch model.result?.verdict {
        case .allGood, .routerSilent: Theme.positive
        default: Theme.lapis
        }
    }

    private struct StepRow: View {
        let step: NetworkCheck.Step
        let result: NetworkCheck

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tone.color)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(title).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(verbatim: detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
        }

        private var outcome: NetworkCheck.Outcome { result.outcomes[step] ?? .skipped }

        /// A silent router while the internet works is normal, not an error.
        private var routerOnlySilent: Bool {
            step == .router && result.verdict == .routerSilent
        }

        private var symbol: String {
            switch outcome {
            case .passed: "checkmark.circle.fill"
            case .failed: routerOnlySilent ? "minus.circle.fill" : "xmark.octagon.fill"
            case .skipped: "minus.circle"
            }
        }

        private var tone: Tone {
            switch outcome {
            case .passed: .positive
            case .failed: routerOnlySilent ? .neutral : .critical
            case .skipped: .neutral
            }
        }

        private var title: LocalizedStringKey {
            switch step {
            case .connection: "tools.network.step.connection"
            case .router: "tools.network.step.router"
            case .dns: "tools.network.step.dns"
            case .internet: "tools.network.step.internet"
            }
        }

        private var detail: String {
            let time: String? =
                if case .passed(let milliseconds?) = outcome { "\(milliseconds) ms" } else { nil }
            switch (step, outcome) {
            case (.connection, .passed):
                return [result.interface, result.address].compactMap { $0 }.joined(separator: " · ")
            case (.router, .failed) where routerOnlySilent:
                return String(localized: "tools.network.router.silent")
            case (.router, _):
                return [result.router, time].compactMap { $0 }.joined(separator: " · ")
            case (_, .failed): return String(localized: "tools.network.failed")
            case (_, .skipped): return "–"
            default: return time ?? ""
            }
        }
    }
}

/// External drives with an eject button; the Mac's own disk is not listed.
struct DrivesCard: View {
    let model: DrivesModel
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        PanelCard(spacing: 8) {
            CardHeader(
                symbol: "externaldrive", tint: Theme.lapis, title: "tools.drives.title",
                subtitle: model.drives.isEmpty
                    ? String(localized: "tools.drives.none")
                    : String(localized: "tools.drives.hint"))
            ForEach(model.drives) { drive in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: drive.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let free = drive.freeBytes, let total = drive.totalBytes {
                            Text(
                                verbatim: String(
                                    format: String(localized: "tools.drives.free %@ %@"),
                                    MonitorFormat.storage(UInt64(max(free, 0))),
                                    MonitorFormat.storage(UInt64(max(total, 0))))
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if model.ejecting.contains(drive.url) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            model.eject(drive)
                        } label: {
                            Image(systemName: "eject.fill")
                                .foregroundStyle(Theme.goldText)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("tools.drives.eject"))
                        .accessibilityLabel(Text(verbatim: String(localized: "tools.drives.eject") + " " + drive.name))
                    }
                }
                if model.failed == drive.url {
                    Label("tools.drives.busy", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Displays, power adapter, USB devices (docks show as hubs) and the
/// batteries of keyboard, mouse and trackpad.
struct HardwareCard: View {
    let model: HardwareModel
    var peripherals: PeripheralsModel?
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        let devices = model.usb.filter { !$0.isHub }
        let hubs = model.usb.filter(\.isHub).count
        PanelCard(spacing: 7) {
            CardHeader(
                symbol: "cable.connector", tint: Theme.lapis, title: "tools.hardware.title",
                subtitle: String(localized: "tools.hardware.subtitle"))
            ForEach(model.displays) { display in
                line(
                    display.isBuiltIn ? "laptopcomputer" : "display", display.name,
                    [display.pixels, display.hertz.map { "\($0) Hz" }].compactMap { $0 }.joined(separator: " · "))
            }
            if let adapter = model.adapter {
                line(
                    "powerplug", adapter.name ?? String(localized: "tools.hardware.adapter"),
                    adapter.watts.map { "\($0) W" } ?? "")
            }
            // How each thing is connected, so a Bluetooth keyboard is never
            // taken for a USB one (and a second, wired keyboard stays apart).
            ForEach(Array((peripherals?.accessories ?? []).enumerated()), id: \.offset) { _, accessory in
                line(
                    accessory.isBluetooth ? "" : "battery.75", PeripheralTexts.name(accessory.kind),
                    [
                        accessory.isBluetooth ? "Bluetooth" : accessory.transport,
                        MonitorFormat.percent(accessory.percent),
                    ]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            ForEach(Array(devices.prefix(8).enumerated()), id: \.offset) { _, device in
                line(
                    "cable.connector.horizontal", device.name,
                    ["USB", device.vendor].compactMap { $0 }.joined(separator: " · "))
            }
            if hubs > 0 {
                Text(verbatim: String(format: String(localized: "tools.hardware.hubs %@"), String(hubs)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Plugging and unplugging shows within 2 s: the USB list is one
        // IORegistry walk (< 1 ms), the accessories at most every 10 s.
        .task(id: panelIsShown) {
            while panelIsShown, !Task.isCancelled {
                model.refresh()
                peripherals?.refreshAccessories(maxAge: 10)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in model.refresh()
        }
    }

    /// An empty symbol name draws the Bluetooth rune.
    private func line(_ symbol: String, _ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if symbol.isEmpty { BluetoothGlyph() } else { Image(systemName: symbol).font(.caption) }
            }
            .foregroundStyle(.secondary)
            .frame(width: 18)
            Text(verbatim: name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The user's print jobs, stuck ones marked, each with a cancel button;
/// stopped printers with their reason. Hidden when no printer is set up.
struct PrintersCard: View {
    let model: PrintersModel
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        Group {
            if !model.printers.isEmpty || !model.jobs.isEmpty {
                PanelCard(spacing: 8) {
                    let stuck = model.jobs.filter(model.isStuck).count
                    CardHeader(
                        symbol: "printer", tint: stuck > 0 ? Theme.gold : Theme.lapis,
                        title: "tools.printers.title", subtitle: subtitle(stuck: stuck),
                        tone: stuck > 0 ? .attention : .neutral)
                    ForEach(model.printers.filter(\.isStopped)) { printer in
                        Label {
                            Text(
                                verbatim: String(
                                    format: String(localized: "tools.printers.stopped %@"), printer.displayName))
                        } icon: {
                            Image(systemName: "pause.circle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                    }
                    ForEach(model.jobs) { job in
                        HStack(spacing: 8) {
                            Image(systemName: model.isStuck(job) ? "exclamationmark.triangle.fill" : "doc.text")
                                .font(.caption)
                                .foregroundStyle(model.isStuck(job) ? Theme.attention : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: job.title.isEmpty ? "#\(job.id)" : job.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: "\(printerName(job.printer)) · \(state(job))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button("tools.printers.cancel") { model.cancel(job) }
                                .buttonStyle(PillButtonStyle())
                                .font(.caption)
                        }
                        if model.cancelFailed == job.id {
                            Text("tools.printers.cancelFailed").font(.caption).foregroundStyle(Theme.attention)
                        }
                    }
                }
            }
        }
    }

    private func subtitle(stuck: Int) -> String {
        if model.jobs.isEmpty { return String(localized: "tools.printers.none") }
        if stuck > 0 { return String(format: String(localized: "tools.printers.stuck %@"), String(stuck)) }
        return String(format: String(localized: "tools.printers.count %@"), String(model.jobs.count))
    }

    private func printerName(_ name: String) -> String {
        model.printers.first { $0.name == name }?.displayName ?? name
    }

    private func state(_ job: PrintQueue.Job) -> String {
        switch job.state {
        case .pending: String(localized: "tools.printers.state.pending")
        case .held: String(localized: "tools.printers.state.held")
        case .printing: String(localized: "tools.printers.state.printing")
        case .stopped: String(localized: "tools.printers.state.stopped")
        }
    }
}

/// A short note with the whole explanation behind ⓘ (tooltip and VoiceOver).
struct InfoNote: View {
    let short: LocalizedStringKey
    let full: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield").font(.caption2)
            Text(short).font(.caption2)
            Image(systemName: "info.circle").font(.caption2)
        }
        .foregroundStyle(.secondary)
        .help(Text(full))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(full))
    }
}
