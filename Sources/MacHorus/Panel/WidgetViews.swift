// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import MacHorusTools
import SwiftUI

/// Names and symbols of the widgets (for the add list and arrange mode).
enum WidgetTexts {
    static func title(_ kind: WidgetKind) -> LocalizedStringKey {
        switch kind {
        case .mac: "widget.mac"
        case .rings: "widget.rings"
        case .clipboard: "clipboard.title"
        case .audio: "widget.audio"
        case .cpu: "monitor.section.cpu"
        case .memory: "monitor.section.memory"
        case .network: "monitor.section.network"
        case .disk: "monitor.section.disk"
        case .gpu: "monitor.section.gpu"
        case .battery: "monitor.section.battery"
        case .thermal: "monitor.section.thermal"
        case .processes: "monitor.section.processes"
        case .vpn: "widget.vpn"
        case .keepAwake: "tools.keepAwake.title"
        case .networkCheck: "tools.network.title"
        case .updates: "tools.updates.title"
        case .hardware: "tools.hardware.title"
        case .drives: "tools.drives.title"
        case .printers: "tools.printers.title"
        case .ports: "tools.ports.title"
        }
    }

    static func symbol(_ kind: WidgetKind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .rings: "circle.circle"
        case .clipboard: "doc.on.clipboard"
        case .audio: "speaker.wave.2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "square.3.layers.3d"
        case .battery: "battery.75"
        case .thermal: "thermometer.medium"
        case .processes: "list.bullet.rectangle"
        case .vpn: "lock.shield"
        case .keepAwake: "cup.and.saucer"
        case .networkCheck: "stethoscope"
        case .updates: "arrow.down.app"
        case .hardware: "cable.connector"
        case .drives: "externaldrive"
        case .printers: "printer"
        case .ports: "point.3.connected.trianglepath.dotted"
        }
    }

    static func group(_ group: WidgetKind.Group) -> LocalizedStringKey {
        switch group {
        case .overview: "widget.group.overview"
        case .monitor: "widget.group.monitor"
        case .tools: "widget.group.tools"
        }
    }
}

/// Whether a widget can show on this Mac with the features switched on,
/// and whether it has anything to show right now (drives and print jobs
/// stay out of sight while there are none, except while arranging).
@MainActor
enum WidgetAvailability {
    static func isAvailable(_ kind: WidgetKind, _ model: PanelModel) -> Bool {
        let metrics = model.monitor.enabledMetrics
        let tools = model.tools
        switch kind {
        case .mac, .rings: return true
        case .clipboard: return tools?.clipboard.isEnabled == true
        case .audio:
            return tools.map { $0.microphones.isEnabled || $0.mixer.isEnabled || $0.devices.isEnabled } ?? false
        case .cpu: return metrics.contains(.cpu)
        case .memory: return metrics.contains(.memory)
        case .network: return metrics.contains(.network)
        case .disk: return metrics.contains(.disk)
        case .gpu: return metrics.contains(.gpu)
        case .battery: return metrics.contains(.power)
        case .thermal: return metrics.contains(.thermal)
        case .processes: return metrics.contains(.processes)
        // Its totals come from the monitor's background readings.
        case .vpn: return model.monitor.isAnyMetricEnabled
        case .keepAwake: return tools?.keepAwake.isEnabled == true
        case .networkCheck: return tools?.network.isEnabled == true
        case .updates: return tools?.updates.isEnabled == true
        case .hardware: return tools?.hardware.isEnabled == true
        case .drives: return tools?.drives.isEnabled == true
        case .printers: return tools?.printers.isEnabled == true
        case .ports: return tools?.ports.isEnabled == true
        }
    }
}

/// The five sizes as the widget shows them. The narrow panel has two
/// columns: its 1×4 is as wide as its 1×2 and shows the same.
enum WidgetShape {
    /// 1×1: one value.
    case tile
    /// 1×2: value, caption and its history, bar or main button.
    case bar
    /// 2×2: the bar's content, then a short list below.
    case square
    /// 1×4: the bar's content and the list side by side.
    case wide
    /// 2×4: the whole card (scrolls inside when longer).
    case full

    init(_ size: WidgetSize, _ width: PanelWidth) {
        switch (size, width) {
        case (.small, _): self = .tile
        case (.medium, _), (.wide, .compact): self = .bar
        case (.square, _): self = .square
        case (.wide, .expanded): self = .wide
        case (.large, _), (.tall, _): self = .full
        }
    }
}

/// One widget in its size; it fills the grid cell it is given.
struct WidgetView: View {
    let kind: WidgetKind
    let size: WidgetSize
    let width: PanelWidth
    let model: PanelModel
    @Environment(\.panelIsShown) private var panelIsShown
    @Environment(\.panelCardFillsHeight) private var fillsHeight

    var body: some View {
        content
            // In the grid it fills its cell; opened, it is as high as its content.
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            // What some widgets read each time the panel opens (cheap, on demand).
            .task(id: panelIsShown) {
                guard panelIsShown else { return }
                switch kind {
                case .mac:
                    if model.tools?.updates.isEnabled == true { model.tools?.updates.refresh() }
                    model.peripherals.refresh()
                case .hardware: model.tools?.hardware.refresh()
                case .disk: model.tools?.drives.refresh()
                case .vpn: await model.monitor.traffic.refresh()
                default: break
                }
            }
    }

    @ViewBuilder private var content: some View {
        let pad = Theme.widgetPadding
        switch WidgetShape(size, width) {
        case .tile: WidgetTile(kind: kind, model: model)
        case .bar: PanelCard(spacing: 0, padding: pad) { WidgetSummaryBody(kind: kind, model: model) }
        case .square:
            if WidgetList.has(kind) {
                PanelCard(spacing: 8, padding: pad) {
                    // The bar's content (stacked when narrow), then the list.
                    WidgetSummaryBody(kind: kind, model: model, stacked: width == .compact)
                        .frame(height: width == .compact ? 100 : 72)
                    Divider()
                    WidgetList(kind: kind, model: model, limit: width == .compact ? 2 : 3)
                    Spacer(minLength: 0)
                }
            } else if width == .compact {
                // Half the narrow panel is too tight for whole cards.
                PanelCard(spacing: 6, padding: pad) {
                    if kind == .processes {
                        WidgetHeader(kind: .processes)
                        WidgetList(kind: .processes, model: model, limit: 6, titled: false)
                        Spacer(minLength: 0)
                    } else {
                        WidgetSummaryBody(kind: kind, model: model, stacked: true)
                    }
                }
            } else {
                full
            }
        case .wide:
            if WidgetList.has(kind) {
                WideWidget(kind: kind, model: model)
            } else {
                // One row high: the bar's content across the panel.
                PanelCard(spacing: 0, padding: pad) { WidgetSummaryBody(kind: kind, model: model) }
            }
        case .full: full
        }
    }

    // MARK: The whole card

    @ViewBuilder private var full: some View {
        let monitor = model.monitor
        switch kind {
        case .mac:
            Scrolling(header: nil) {
                MacCard(
                    monitor: monitor, alerts: model.alerts?.active ?? [],
                    updates: model.tools?.updates.isEnabled == true ? model.tools?.updates.updates : nil,
                    peripherals: model.peripherals, dismissals: model.statusDismissals,
                    culprits: model.alerts?.culprits ?? [:], alertRules: model.alerts?.rules ?? AlertRules(),
                    open: { [navigation = model.navigation] tab in navigation.tab = tab })
            }
        case .rings:
            // The rings in the middle of the card, whatever its size.
            PanelCard(spacing: 10) {
                WidgetHeader(kind: .rings)
                Spacer(minLength: 0)
                RingsCard(monitor: monitor).environment(\.panelCardIsFlat, true)
                Spacer(minLength: 0)
            }
        case .clipboard:
            if let clipboard = model.tools?.clipboard {
                Scrolling(header: nil) { ClipboardCard(controller: clipboard) }
            }
        case .audio:
            if let tools = model.tools {
                // Grows down instead of scrolling (user feedback): the board
                // gives it the rows its content needs.
                Scrolling(
                    header: nil, needs: { model.widgets.setNeededHeight($0, for: .audio) },
                    content: { AudioBox(microphones: tools.microphones, mixer: tools.mixer, devices: tools.devices) })
            }
        case .cpu:
            Scrolling(header: kind) {
                CPUCard(cpu: monitor.cpu, history: monitor.cpuHistory.elements)
                extras
            }
        case .memory:
            Scrolling(header: kind) {
                MemoryCard(memory: monitor.memory, history: monitor.memoryHistory.elements)
                extras
            }
        case .network:
            Scrolling(header: kind) {
                NetworkCard(
                    network: monitor.network, history: monitor.networkHistory.elements, peripherals: model.peripherals)
                extras
            }
        case .disk:
            Scrolling(header: kind) {
                DiskCard(disk: monitor.disk, history: monitor.diskHistory.elements, usage: model.diskUsage)
                extras
            }
        case .gpu: Scrolling(header: kind) { GPUCard(gpu: monitor.gpu, history: monitor.gpuHistory.elements) }
        case .battery: Scrolling(header: kind) { BatteryCard(battery: monitor.battery) }
        case .thermal:
            Scrolling(header: kind) {
                ThermalCard(thermal: monitor.thermal, history: monitor.temperatureHistory.elements)
            }
        case .processes:
            Scrolling(header: kind) {
                ProcessCard(
                    processes: monitor.processes, monitor: monitor, detailed: width == .expanded && size.isFull,
                    rows: size == .tall ? 18 : size == .large ? 8 : 4, showsSearch: size.isFull)
            }
        case .vpn:
            Scrolling(header: kind) { VPNWidget(model: model, rows: 10, footer: true) }
        default:
            if let tools = model.tools { Scrolling(header: nil) { toolCard(tools) } }
        }
    }

    /// Large monitor widgets: what uses it most, or the attached drives.
    private var extras: some View { WidgetExtras(kind: kind, model: model) }

    @ViewBuilder private func toolCard(_ tools: ToolsModels) -> some View {
        switch kind {
        case .keepAwake: KeepAwakeCard(controller: tools.keepAwake)
        case .networkCheck: NetworkCheckCard(model: tools.network)
        case .updates: UpdatesCard(model: tools.updates)
        case .hardware: HardwareCard(model: tools.hardware, peripherals: model.peripherals)
        case .drives: DrivesCard(model: tools.drives)
        case .printers: PrintersCard(model: tools.printers)
        case .ports: PortsCard(model: tools.ports)
        default: EmptyView()
        }
    }
}

/// A fixed-height card: its content scrolls inside only when it is
/// longer than the cell (short content never scrolls, so the page scrolls
/// as usual over it). Cards inside draw flat.
///
/// One instance of the content, always in the same scroll view: a
/// `ViewThatFits` with a plain and a scrolling copy kept two states, and
/// a disclosure ("Weitere Apps") that made its copy too tall switched to
/// the other copy, still closed.
private struct Scrolling<Content: View>: View {
    let header: WidgetKind?
    /// Told the height the whole card needs to show everything; the same
    /// whatever height it gets, so growing it never feeds back.
    var needs: ((CGFloat) -> Void)?
    @ViewBuilder var content: Content
    /// The content's frame in the scroll view (its top moves up while
    /// scrolling) and the visible height. Measured with onGeometryChange,
    /// which works on macOS 14 (onScrollGeometryChange needs 15).
    @State private var contentFrame = CGRect.zero
    @State private var visibleHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0

    private var overflows: Bool { contentFrame.height > visibleHeight + 1 }
    private var moreBelow: Bool { overflows && contentFrame.maxY > visibleHeight + 2 }

    var body: some View {
        PanelCard(spacing: 10) {
            if let header { WidgetHeader(kind: header) }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) { content }
                    .environment(\.panelCardIsFlat, true)
                    // scrollDisabled travels down the environment: lists
                    // inside (the clipboard's) keep scrolling.
                    .scrollDisabled(false)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(ScrollingSpace.name))
                    } action: {
                        contentFrame = $0
                    }
            }
            .coordinateSpace(.named(ScrollingSpace.name))
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                visibleHeight = $0
            }
            // No bar (as on widgets): the lower edge fades while more follows.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollDisabled(!overflows)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, moreBelow ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            cardHeight = $0
            report()
        }
        .onChange(of: contentFrame.height) { report() }
        .onChange(of: visibleHeight) { report() }
    }

    /// Content plus the card's own chrome (padding, header).
    private func report() {
        guard let needs, visibleHeight > 0, contentFrame.height > 0 else { return }
        needs(contentFrame.height + max(cardHeight - visibleHeight, 0))
    }
}

/// The coordinate space of a scrolling card (a generic type has no static
/// stored constants).
private enum ScrollingSpace {
    static let name = "scrollingCard"
}

/// The 1×2 content (72 pt high): for monitor values the value on the
/// left and its history or gauge on the right; for the others their state
/// and the one action that matters.
private struct WidgetSummaryBody: View {
    let kind: WidgetKind
    let model: PanelModel
    /// Narrow 2×2: the history below the value instead of beside it.
    var stacked = false

    var body: some View {
        switch kind {
        case .cpu, .memory, .network, .gpu, .thermal, .disk, .battery:
            MetricSummaryBody(kind: kind, model: model, stacked: stacked)
        case .clipboard:
            if let clipboard = model.tools?.clipboard { ClipboardSummary(controller: clipboard) }
        case .rings: RingsSummary(monitor: model.monitor)
        case .processes:
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(kind: .processes)
                WidgetList(kind: .processes, model: model, limit: 2, titled: false)
                Spacer(minLength: 0)
            }
        case .audio:
            if let tools = model.tools { AudioSummary(microphones: tools.microphones, devices: tools.devices) }
        default:
            FactsSummary(kind: kind, model: model)
        }
    }
}

/// Header with an optional action, the value and its caption.
private struct FactsSummary: View {
    let kind: WidgetKind
    let model: PanelModel

    var body: some View {
        let facts = WidgetFacts(kind: kind, model: model, summary: true)
        VStack(alignment: .leading, spacing: 0) {
            // The action beside the name; below it when that is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    WidgetHeader(kind: kind, tint: facts.tint).fixedSize()
                    Spacer(minLength: 4)
                    action
                }
                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeader(kind: kind, tint: facts.tint)
                    action
                }
            }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: facts.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(facts.valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                if let caption = facts.caption {
                    Text(verbatim: caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // "1 Hinweis" alone said nothing: the most pressing point in
            // words; a click opens the card with all of them.
            if kind == .mac, let first = MacStatus.items(model).max(by: { $0.severity < $1.severity }) {
                HStack(spacing: 4) {
                    Image(systemName: first.severity == .info ? "info.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(facts.valueColor == .primary ? Theme.lapis : facts.valueColor)
                    Text(verbatim: StatusTexts.title(first)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if let tools = model.tools {
            switch kind {
            case .keepAwake:
                Button(tools.keepAwake.isActive ? "tools.keepAwake.stop" : "widget.keepAwake.start") {
                    tools.keepAwake.isActive ? tools.keepAwake.stop() : tools.keepAwake.start(duration: nil)
                }
                .buttonStyle(PillButtonStyle())
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
            case .networkCheck:
                Button("tools.network.run") { tools.network.run() }
                    .buttonStyle(PillButtonStyle())
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(tools.network.isRunning)
            case .mac: RestartChip(level: model.monitor.restartAdvice.level)
            case .updates where (tools.updates.updates?.count ?? 0) > 0:
                // Says where it leads: "Installieren" read as "downloads now".
                Button(tools.updates.isMunkiInstalled ? "widget.updates.openMunki" : "widget.updates.openSettings") {
                    tools.updates.openUpdater()
                }
                .buttonStyle(PillButtonStyle())
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
            default: EmptyView()
            }
        }
    }
}

private struct RingsSummary: View {
    let monitor: SystemMonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(kind: .rings)
            Spacer(minLength: 2)
            HStack(spacing: 6) {
                ring("overview.ring.cpu", monitor.cpu?.total.total, color: LoadColor.cpu(monitor.cpu?.total.total))
                ring(
                    "overview.ring.memory", monitor.memory?.usedFraction,
                    color: LoadColor.memory(monitor.memory?.pressure))
                ring(
                    "overview.ring.disk", monitor.disk?.usedFraction, color: LoadColor.disk(monitor.disk?.usedFraction))
                if let battery = monitor.battery {
                    // Charge is good when high: its own colours, not a load's.
                    ring("overview.ring.battery", Double(battery.charge) / 100, color: battery.color)
                }
            }
        }
    }

    /// A small ring with the percentage inside and the name below it; the
    /// colour says whether the value is fine (user feedback 1.0.30).
    private func ring(_ title: LocalizedStringKey, _ value: Double?, color: Color) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value ?? 0)))
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: MonitorFormat.percent(value))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 30, height: 30)
            .animation(.smooth(duration: 0.6), value: value)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: MonitorFormat.percent(value)))
    }
}

/// Ring and bar colours for a load: lapis while fine, orange when high,
/// red when critical.
enum LoadColor {
    static func cpu(_ value: Double?) -> Color {
        switch value ?? 0 {
        case 0.9...: Theme.critical
        case 0.7...: Theme.attention
        default: Theme.lapis
        }
    }

    /// Memory by pressure, not by fraction: macOS keeps memory full on purpose.
    static func memory(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .critical: Theme.critical
        case .warning: Theme.attention
        default: Theme.lapis
        }
    }

    static func disk(_ value: Double?) -> Color {
        switch value ?? 0 {
        case 0.95...: Theme.critical
        case 0.85...: Theme.attention
        default: Theme.lapis
        }
    }
}

/// The last copies, each with what it is (a picture shows itself) and
/// when; the current clipboard is marked. A click puts one back.
private struct ClipboardSummary: View {
    let controller: ClipboardController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(kind: .clipboard, trailing: controller.shortcut.combo?.display)
                .padding(.bottom, 2)
            let entries = controller.history.search("").prefix(2)
            if entries.isEmpty {
                Text("widget.list.empty").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                Button {
                    controller.pick(entry.id)
                    PanelFocus.close()
                } label: {
                    row(entry, isCurrent: entry.id == controller.history.entries.first?.id)
                }
                .buttonStyle(.plain)
                .help(Text("clipboard.pick.help"))
            }
            // The copies right under the title, the room left below them.
            Spacer(minLength: 0)
        }
    }

    private func row(_ entry: ClipboardHistory.Entry, isCurrent: Bool) -> some View {
        HStack(spacing: 7) {
            Group {
                if let thumbnail = controller.thumbnails[entry.id] {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: ClipLabel.symbol(entry.kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isCurrent ? Theme.goldText : Color.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
            Text(verbatim: ClipLabel.title(entry, pixelSize: controller.pixelSizes[entry.id]))
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: ClipLabel.age(entry))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isCurrent ? Theme.gold.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
    }
}

/// Output device and the microphone switch.
private struct AudioSummary: View {
    let microphones: MicrophoneController
    let devices: AudioDeviceController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WidgetHeader(kind: .audio, tint: microphones.isMuted ? Theme.gold : Theme.lapis)
                if microphones.isEnabled {
                    Button {
                        microphones.setMuted(!microphones.isMuted)
                    } label: {
                        Image(systemName: microphones.isMuted ? "mic.slash.fill" : "mic")
                            .foregroundStyle(microphones.isMuted ? Theme.goldText : Color.primary)
                    }
                    .buttonStyle(PillButtonStyle())
                    .help(Text(microphones.isMuted ? "widget.audio.unmute" : "widget.audio.mute"))
                    .accessibilityLabel(Text(microphones.isMuted ? "widget.audio.unmute" : "widget.audio.mute"))
                }
            }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: devices.outputs.first { $0.id == devices.output }?.name ?? "–")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Text(microphones.isMuted ? "widget.audio.muted" : "widget.audio.output")
                    .font(.caption)
                    .foregroundStyle(microphones.isMuted ? Theme.goldText : .secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { if devices.isEnabled { devices.startWatching() } }
        .onDisappear { devices.stopWatching() }
    }
}

/// Which VPN is up (system service, or the client recognised by its
/// process), its tunnel and address, and the apps that went through it
/// since the Mac started (home office: what was used over the VPN).
private struct VPNWidget: View {
    let model: PanelModel
    /// Apps listed (by data through the tunnel).
    let rows: Int
    let footer: Bool

    private var traffic: AppTrafficModel { model.monitor.traffic }

    var name: String {
        if let service = traffic.vpn.services.first { return service }
        if let client = traffic.vpnClientName { return client }
        return traffic.vpn.isUp ? String(localized: "widget.vpn.unknown") : String(localized: "widget.vpn.off")
    }

    var body: some View {
        let apps = traffic.rows(processes: model.monitor.processes, span: .sinceStart) { ProcessActions.name(for: $0) }
            .filter { $0.use.total(.vpn) > 0 }
            .sorted { $0.use.total(.vpn) > $1.use.total(.vpn) }
        Group {
            if true {
                PanelCard(spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: name)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(traffic.vpn.isUp ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(
                                verbatim: traffic.vpn.tunnels.map { "\($0.interface) · \($0.address)" }
                                    .joined(separator: ", ")
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if !apps.isEmpty {
                        Text("widget.vpn.apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(apps.prefix(rows)) { app in
                            HStack(spacing: 8) {
                                Group {
                                    if let identity = app.identity {
                                        Image(nsImage: ProcessActions.icon(for: identity))
                                    } else {
                                        Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 16, height: 16)
                                Text(verbatim: app.name).font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(
                                    verbatim:
                                        "↓ \(ProcessDetails.bytes(app.use.download(.vpn)))  ↑ \(ProcessDetails.bytes(app.use.upload(.vpn)))"
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                    } else if traffic.vpn.isUp {
                        Text("widget.vpn.noApps").font(.caption).foregroundStyle(.secondary)
                    }
                    if footer {
                        Text("widget.vpn.footer")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: Small and large details

/// Symbol and name, the value and its caption on the left; on the right
/// its history (filled curve) or, for free space and charge, a gauge.
private struct MetricSummaryBody: View {
    let kind: WidgetKind
    let model: PanelModel
    var stacked = false

    var body: some View {
        let monitor = model.monitor
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                facts(monitor)
                accessory(monitor)
            }
        } else {
            HStack(alignment: .bottom, spacing: 12) {
                // Value and history share the width half and half.
                facts(monitor)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                accessory(monitor)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    private func facts(_ monitor: SystemMonitorModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let facts = WidgetFacts(kind: kind, model: model)
            WidgetHeader(kind: kind, tint: facts.tint, symbol: facts.symbol)
            Spacer(minLength: 4)
            Text(verbatim: value(monitor))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(facts.valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: value(monitor))
            if let caption = caption(monitor) {
                Text(verbatim: caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder private func accessory(_ monitor: SystemMonitorModel) -> some View {
        if let history = history(monitor) {
            Sparkline(values: history, capacity: SystemMonitorModel.historyLength)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: stacked ? 30 : 46)
        } else if let (fraction, color) = bar(monitor) {
            MiniRing(value: fraction, color: color)
                .frame(width: 50, height: 50)
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
        }
    }

    private func bar(_ monitor: SystemMonitorModel) -> (Double, Color)? {
        switch kind {
        case .disk: return monitor.disk.map { ($0.usedFraction, Theme.lapis) }
        case .battery:
            return monitor.battery.map { (Double($0.charge) / 100, $0.color) }
        default: return nil
        }
    }

    private func value(_ monitor: SystemMonitorModel) -> String {
        let raw = rawValue(monitor)
        return WidgetReason.override(kind, monitor, value: raw)?.value ?? raw
    }

    private func caption(_ monitor: SystemMonitorModel) -> String? {
        WidgetReason.override(kind, monitor, value: rawValue(monitor))?.caption ?? rawCaption(monitor)
    }

    private func rawValue(_ monitor: SystemMonitorModel) -> String {
        switch kind {
        case .cpu: MonitorFormat.percent(monitor.cpu?.total.total)
        case .memory: MonitorFormat.bytes(monitor.memory?.used)
        case .network:
            "↓ \(MonitorFormat.rate(monitor.network?.downloadBytesPerSecond))"
        case .disk: MonitorFormat.storage(monitor.disk?.availableBytes)
        case .gpu: MonitorFormat.percent(monitor.gpu?.utilization)
        case .battery: monitor.battery.map { MonitorFormat.percent($0.charge) } ?? "–"
        case .thermal: MonitorFormat.celsius(monitor.thermal?.cpu)
        default: "–"
        }
    }

    private func rawCaption(_ monitor: SystemMonitorModel) -> String? {
        switch kind {
        case .memory:
            monitor.memory.map {
                String(localized: "widget.summary.memoryOf \(MonitorFormat.bytes($0.physical))")
            }
        case .network: "↑ \(MonitorFormat.rate(monitor.network?.uploadBytesPerSecond))"
        case .disk: String(localized: "widget.summary.free")
        case .battery:
            monitor.battery.map {
                String(
                    localized: $0.isCharging
                        ? "monitor.battery.charging"
                        : $0.isOnExternalPower ? "monitor.battery.onPower" : "monitor.battery.discharging")
            }
        case .thermal:
            monitor.thermal.map {
                String(localized: $0.pressure == .nominal ? "widget.summary.thermalOK" : "widget.summary.thermalHigh")
            }
        default: nil
        }
    }

    private func history(_ monitor: SystemMonitorModel) -> [Double]? {
        switch kind {
        case .cpu: monitor.cpuHistory.elements
        case .memory: monitor.memoryHistory.elements
        case .network: MonitorFormat.normalized(monitor.networkHistory.elements)
        case .gpu: monitor.gpuHistory.elements
        case .thermal: monitor.temperatureHistory.elements.map { $0 / 110 }
        default: nil
        }
    }
}

/// The extra part of a large monitor widget: the three apps that use it
/// most (CPU, memory, network since Mac start) or the attached drives.
private struct WidgetExtras: View {
    let kind: WidgetKind
    let model: PanelModel

    var body: some View {
        // The GPU card already shows its memory.
        if WidgetList.has(kind), !WidgetList(kind: kind, model: model, limit: 3).rows.isEmpty {
            PanelCard(spacing: 6) { WidgetList(kind: kind, model: model, limit: 3) }
        }
    }
}

/// The short list of a 2×2, 1×4 or large widget: the apps that use it
/// most, attached drives, sensors, battery facts, apps through the VPN,
/// this Mac's facts.
private struct WidgetList: View {
    let kind: WidgetKind
    let model: PanelModel
    let limit: Int
    var titled = true

    /// Widgets that have such a list (the others show their card instead).
    static func has(_ kind: WidgetKind) -> Bool {
        switch kind {
        case .cpu, .memory, .network, .disk, .gpu, .battery, .thermal, .vpn: true
        default: false
        }
    }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 3) {
            if titled { Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            if rows.isEmpty {
                Text(kind == .vpn ? "widget.vpn.noApps" : "widget.list.empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Group {
                        if let identity = row.identity {
                            Image(nsImage: ProcessActions.icon(for: identity))
                        } else {
                            Image(systemName: row.symbol).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(verbatim: row.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: row.value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
    }

    struct Row {
        let identity: ProcessIdentity?
        let symbol: String
        let name: String
        let value: String
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .disk: "widget.extras.drives"
        case .network: "widget.extras.networkApps"
        case .thermal: "widget.extras.sensors"
        case .battery: "widget.extras.battery"
        case .gpu: "widget.extras.gpu"
        case .vpn: "widget.vpn.apps"
        default: "widget.extras.topApps"
        }
    }

    var rows: [Row] { Array(allRows.prefix(limit)) }

    private var allRows: [Row] {
        let monitor = model.monitor
        switch kind {
        case .cpu, .memory, .processes:
            let order: ProcessOrder = kind == .memory ? .memory : .cpu
            return (monitor.processes?.top(order, limit: limit) ?? []).map {
                Row(
                    identity: $0.identity, symbol: "app", name: ProcessActions.name(for: $0),
                    value: order == .cpu ? MonitorFormat.percent($0.cpu) : MonitorFormat.bytes($0.memory))
            }
        case .network:
            let traffic = monitor.traffic
            let rows = traffic.rows(processes: monitor.processes, span: .sinceStart) { ProcessActions.name(for: $0) }
            return rows.sorted { $0.use.total(.all) > $1.use.total(.all) }.prefix(3).map {
                Row(
                    identity: $0.identity, symbol: "gearshape.2", name: $0.name,
                    value: "↓ \(ProcessDetails.bytes($0.use.download(.all)))")
            }
        case .disk:
            return (model.tools?.drives.drives ?? []).prefix(3).map {
                Row(
                    identity: nil, symbol: "externaldrive", name: $0.name,
                    value: $0.freeBytes.map { MonitorFormat.storage(UInt64(max($0, 0))) } ?? "")
            }
        case .thermal:
            guard let thermal = monitor.thermal else { return [] }
            let sensors: [(String, Double?)] = [
                (String(localized: "monitor.thermal.performance"), thermal.performanceCores),
                (String(localized: "monitor.thermal.efficiency"), thermal.efficiencyCores),
                (String(localized: "monitor.thermal.gpu"), thermal.gpu),
                (String(localized: "monitor.thermal.ssd"), thermal.ssd),
            ]
            return sensors.compactMap { name, value in
                value.map {
                    Row(identity: nil, symbol: "thermometer.medium", name: name, value: MonitorFormat.celsius($0))
                }
            }
        case .battery:
            guard let battery = monitor.battery else { return [] }
            return [
                Row(
                    identity: nil, symbol: "clock",
                    name: String(
                        localized: battery.isCharging ? "monitor.battery.untilFull" : "monitor.battery.remaining"),
                    value: battery.isOnExternalPower && !battery.isCharging
                        ? "–" : MonitorFormat.duration(minutes: battery.minutesRemaining)),
                Row(
                    identity: nil, symbol: "heart", name: String(localized: "monitor.battery.health"),
                    value: battery.healthPercent.map { MonitorFormat.percent($0) } ?? "–"),
                Row(
                    identity: nil, symbol: "arrow.triangle.2.circlepath",
                    name: String(localized: "monitor.battery.cycles"),
                    value: battery.cycleCount.map(String.init) ?? "–"),
            ]
        case .gpu:
            guard let gpu = monitor.gpu else { return [] }
            var rows: [Row] = []
            if let model = gpu.model, let cores = gpu.coreCount {
                rows.append(
                    Row(
                        identity: nil, symbol: "cpu",
                        name: String(localized: "monitor.gpu.model \(model) \(String(cores))"),
                        value: ""))
            }
            rows.append(
                Row(
                    identity: nil, symbol: "memorychip", name: String(localized: "monitor.gpu.memory"),
                    value: MonitorFormat.bytes(gpu.memoryInUse)))
            return rows
        case .vpn:
            let traffic = monitor.traffic
            return traffic.rows(processes: monitor.processes, span: .sinceStart) { ProcessActions.name(for: $0) }
                .filter { $0.use.total(.vpn) > 0 }
                .sorted { $0.use.total(.vpn) > $1.use.total(.vpn) }
                .prefix(limit)
                .map {
                    Row(
                        identity: $0.identity, symbol: "gearshape.2", name: $0.name,
                        value: "↓ \(ProcessDetails.bytes($0.use.download(.vpn)))")
                }
        default:
            return []
        }
    }
}

/// The small size: a square with the one value that matters (or the one
/// action), like a small phone widget. A click on it shows the rest.
private struct WidgetTile: View {
    let kind: WidgetKind
    let model: PanelModel

    var body: some View {
        let facts = WidgetFacts(kind: kind, model: model)
        PanelCard(spacing: 0, padding: Theme.widgetPadding) {
            HStack(spacing: 6) {
                IconTile(symbol: facts.symbol, tint: facts.tint, size: 20)
                Text(WidgetTexts.title(kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 2)
            Text(verbatim: facts.value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(facts.valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
                .animation(.snappy, value: facts.value)
            if let caption = facts.caption {
                Text(verbatim: caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

/// A widget's value, its caption and the tint of its symbol (1×1, 1×2).
@MainActor
struct WidgetFacts {
    let kind: WidgetKind
    let model: PanelModel
    /// 1×2: more room, so the Mac and the VPN say more.
    var summary = false

    /// This Mac: alerts, updates, restart advice, … (as on its large card).
    private var status: [StatusItem] { MacStatus.items(model) }

    /// Red or orange when the value itself is the problem.
    var valueColor: Color {
        switch kind {
        case .mac:
            switch status.map(\.severity).max() {
            case .critical?: Theme.critical
            case .warning?: Theme.attention
            default: .primary
            }
        case .thermal: model.monitor.thermal.map { $0.pressure == .nominal ? .primary : Theme.attention } ?? .primary
        case .battery:
            model.monitor.battery.map { BatteryTone.valueColor(charge: $0.charge, onPower: $0.isOnExternalPower) }
                ?? .primary
        default: .primary
        }
    }

    /// The kind's symbol; the battery's shows its level and charging.
    var symbol: String {
        guard kind == .battery, let battery = model.monitor.battery else { return WidgetTexts.symbol(kind) }
        if battery.isCharging { return "battery.100percent.bolt" }
        return switch battery.charge {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }

    var tint: Color {
        switch kind {
        case .vpn: model.monitor.traffic.vpn.isUp ? Theme.positive : Theme.lapis
        case .mac: status.isEmpty ? Theme.positive : Theme.lapis
        case .keepAwake: model.tools?.keepAwake.isActive == true ? Theme.gold : Theme.lapis
        case .battery: model.monitor.battery?.color ?? Theme.lapis
        default: Theme.lapis
        }
    }

    /// The value, or "?"/"–" with the reason as caption (`WidgetReason`).
    var value: String { WidgetReason.override(kind, model.monitor, value: rawValue)?.value ?? rawValue }
    var caption: String? { WidgetReason.override(kind, model.monitor, value: rawValue)?.caption ?? rawCaption }

    private var rawValue: String {
        let monitor = model.monitor
        let tools = model.tools
        if kind == .mac {
            let count = status.count
            return count == 0
                ? String(localized: "widget.mac.ok")
                : count == 1
                    ? String(localized: "widget.mac.oneIssue") : String(localized: "widget.mac.issues \(count)")
        }
        if summary, kind == .vpn, monitor.traffic.vpn.isUp {
            return monitor.traffic.vpn.services.first ?? monitor.traffic.vpnClientName
                ?? String(localized: "widget.vpn.unknown")
        }
        switch kind {
        case .cpu: return MonitorFormat.percent(monitor.cpu?.total.total)
        case .memory: return MonitorFormat.percent(monitor.memory?.usedFraction)
        case .network: return "↓ " + MonitorFormat.rate(monitor.network?.downloadBytesPerSecond)
        case .disk: return MonitorFormat.storage(monitor.disk?.availableBytes)
        case .gpu: return MonitorFormat.percent(monitor.gpu?.utilization)
        case .battery: return monitor.battery.map { MonitorFormat.percent($0.charge) } ?? "–"
        case .thermal: return MonitorFormat.celsius(monitor.thermal?.cpu)
        case .processes:
            return monitor.processes?.top(.cpu, limit: 1).first.map { MonitorFormat.percent($0.cpu) } ?? "–"
        case .vpn: return String(localized: monitor.traffic.vpn.isUp ? "widget.on" : "widget.off")
        case .mac: return ""
        case .rings: return MonitorFormat.percent(monitor.cpu?.total.total)
        case .clipboard: return "\(tools?.clipboard.history.entries.count ?? 0)"
        case .audio: return String(localized: tools?.microphones.isMuted == true ? "widget.audio.muted" : "widget.on")
        case .keepAwake: return String(localized: tools?.keepAwake.isActive == true ? "widget.on" : "widget.off")
        case .networkCheck:
            return tools?.network.result.map { NetworkCheckCard.verdict($0.verdict) }
                ?? String(localized: "widget.tile.notChecked")
        case .updates: return tools?.updates.updates.map { "\($0.count)" } ?? "–"
        case .hardware: return "\(tools?.hardware.displays.count ?? 0)"
        case .drives: return "\(tools?.drives.drives.count ?? 0)"
        case .printers: return "\(tools?.printers.jobs.count ?? 0)"
        case .ports: return "\(tools?.ports.ports.count ?? 0)"
        }
    }

    private var rawCaption: String? {
        let monitor = model.monitor
        let tools = model.tools
        if kind == .mac {
            return summary
                ? "macOS \(MacIdentity.current.systemVersion) · \(RestartTexts.duration(monitor.uptime))"
                : RestartTexts.duration(monitor.uptime)
        }
        if summary, kind == .vpn {
            return monitor.traffic.vpn.isUp
                ? monitor.traffic.vpn.tunnels.map { "\($0.interface) · \($0.address)" }.joined(separator: ", ")
                : String(localized: "widget.vpn.off")
        }
        switch kind {
        case .cpu:
            return monitor.cpu.map {
                String(
                    localized:
                        "monitor.cpu.split \(MonitorFormat.percent($0.total.user)) \(MonitorFormat.percent($0.total.system))"
                )
            }
        case .gpu:
            return monitor.gpu.map { String(localized: "widget.tile.gpuMemory \(MonitorFormat.bytes($0.memoryInUse))") }
        case .thermal:
            return monitor.thermal.map {
                String(localized: $0.pressure == .nominal ? "widget.summary.thermalOK" : "widget.summary.thermalHigh")
            }
        case .battery:
            return monitor.battery.map {
                String(
                    localized: $0.isCharging
                        ? "monitor.battery.charging"
                        : $0.isOnExternalPower ? "monitor.battery.onPower" : "monitor.battery.discharging")
            }
        case .memory: return monitor.memory.map { MonitorFormat.bytes($0.used) }
        case .network: return "↑ " + MonitorFormat.rate(monitor.network?.uploadBytesPerSecond)
        case .disk: return String(localized: "widget.summary.free")
        case .processes:
            return monitor.processes?.top(.cpu, limit: 1).first.map { ProcessActions.name(for: $0) }
        case .vpn: return model.monitor.traffic.vpn.services.first ?? model.monitor.traffic.vpnClientName
        case .mac: return String(localized: "widget.tile.uptime")
        case .rings: return String(localized: "monitor.section.cpu")
        case .hardware: return String(localized: "widget.tile.displays")
        case .keepAwake:
            return String(
                localized: tools?.keepAwake.isActive == true ? "widget.tile.awake" : "widget.tile.sleepsNormally")
        case .networkCheck: return String(localized: "widget.tile.clickToCheck")
        case .updates: return String(localized: "widget.tile.available")
        case .drives: return String(localized: "widget.tile.connected")
        case .printers: return String(localized: "widget.tile.jobs")
        case .ports: return String(localized: "widget.tile.open")
        case .clipboard: return String(localized: "widget.tile.copies")
        case .audio:
            return tools.flatMap { devices in devices.devices.outputs.first { $0.id == devices.devices.output }?.name }
        }
    }
}

/// Why a monitor value shows "?" or "–": an
/// impossible reading, no network, a network filter, no sensors, not
/// measured yet, or no value at all (then the diagnosis has details).
@MainActor
enum WidgetReason {
    static func metric(_ kind: WidgetKind) -> Metric? {
        switch kind {
        case .cpu: .cpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .gpu: .gpu
        case .battery: .power
        case .thermal: .thermal
        case .processes: .processes
        default: nil
        }
    }

    /// nil when the value can be shown as it is.
    static func override(_ kind: WidgetKind, _ monitor: SystemMonitorModel, value: String)
        -> (value: String, caption: String)?
    {
        guard let metric = metric(kind) else { return nil }
        if monitor.suspicious.contains(metric) { return ("?", String(localized: "widget.reason.implausible")) }
        guard value.hasSuffix("–") else { return nil }
        if kind == .network, let network = monitor.network {
            if network.primaryInterface == nil { return (value, String(localized: "widget.reason.offline")) }
            if network.measurement == .interfacesInboundBlind {
                return (value, String(localized: "widget.reason.networkFilter"))
            }
        }
        if kind == .thermal, monitor.thermal != nil { return (value, String(localized: "widget.reason.noSensors")) }
        if let since = monitor.samplingSince, Date().timeIntervalSince(since) < 10 {
            return (value, String(localized: "widget.reason.measuring"))
        }
        return (value, String(localized: "widget.reason.noValue"))
    }
}

/// The wide size of a monitor value: one row across the panel with the
/// value and its caption, the history, and what uses it most.
private struct WideWidget: View {
    let kind: WidgetKind
    let model: PanelModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.pageSpacing) {
            WidgetSummaryBody(kind: kind, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            WidgetList(kind: kind, model: model, limit: 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Theme.widgetPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// The top of every widget bigger than a tile: its symbol and name, and
/// on the right an optional short state.
struct WidgetHeader: View {
    let kind: WidgetKind
    var tint: Color = Theme.lapis
    /// A symbol that shows the state (the battery's level); else the kind's.
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol ?? WidgetTexts.symbol(kind), tint: tint, size: 24)
            Text(WidgetTexts.title(kind)).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let trailing {
                Text(verbatim: trailing).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// What the Mac widget reports: the same points as its large card.
@MainActor
enum MacStatus {
    static func items(_ model: PanelModel) -> [StatusItem] {
        let monitor = model.monitor
        let wifi = model.peripherals.wifi
        return StatusSummary.items(
            restart: monitor.restartAdvice, disk: monitor.disk, battery: monitor.battery, thermal: monitor.thermal,
            alerts: model.alerts?.active ?? [],
            updates: model.tools?.updates.isEnabled == true ? model.tools?.updates.updates : nil,
            accessories: model.peripherals.accessories, wifi: wifi,
            wifiIsPrimary: wifi != nil && wifi?.interface == monitor.network?.primaryInterface,
            dismissed: model.statusDismissals.set, rules: model.alerts?.rules ?? AlertRules())
    }
}

/// A small ring with its percentage inside (free space, charge).
private struct MiniRing: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: MonitorFormat.percent(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        }
        .accessibilityHidden(true)
    }
}
