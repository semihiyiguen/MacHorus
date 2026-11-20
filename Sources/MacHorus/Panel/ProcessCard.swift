// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import SwiftUI

/// The apps using the most CPU, memory or network; helpers count towards
/// their app. CPU and memory: only this user's processes (macOS hides the
/// others); network: every process, split into VPN and own connection.
struct ProcessCard: View {
    let processes: ProcessesSnapshot?
    @Bindable var monitor: SystemMonitorModel
    /// Expanded panel: more rows, CPU and memory side by side.
    var detailed = false
    /// Rows when not detailed (a small widget shows fewer).
    var rows = ProcessSampler.limit
    /// A small widget shows the top rows only, without the search.
    var showsSearch = true
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        PanelCard(spacing: 10) {
            // A text field in the panel cost 5.7 ms per refresh (an AppKit view
            // laid out again each time); until searching starts, a button
            // that looks the same stands in for it.
            if !showsSearch {
                EmptyView()
            } else if monitor.processSearchActive || !monitor.processQuery.isEmpty {
                SearchField(text: $monitor.processQuery, active: $monitor.processSearchActive)
            } else {
                SearchPlaceholder {
                    PanelFocus.makeKey()
                    monitor.processSearchActive = true
                }
            }
            // One centred pill control: a click sorts, a click on the sorted
            // one opens its own choices (user's design, 1.0.30).
            ColumnHeader(monitor: monitor, traffic: monitor.traffic, columns: columns)
            if monitor.processSort == .network {
                NetworkRows(
                    monitor: monitor, traffic: monitor.traffic, processes: processes,
                    query: monitor.processQuery.trimmingCharacters(in: .whitespaces),
                    limit: detailed ? max(12, rows) : rows, columns: columns)
            } else if let processes {
                let query = monitor.processQuery.trimmingCharacters(in: .whitespaces)
                // Searching covers every process, not only the busiest.
                let rows = sortedRows(processes, query: query, limit: detailed ? max(12, self.rows) : self.rows)
                if rows.isEmpty {
                    Group {
                        if query.isEmpty {
                            Text("monitor.processes.empty")
                        } else {
                            Text("monitor.processes.noMatch \(query)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                let totals = networkTotals(processes)
                ForEach(rows) { row in
                    ProcessRow(
                        row: row, sort: monitor.processSort, columns: columns, network: totals[row.identity],
                        monitor: monitor)
                }
                Group {
                    // macOS 27 hides other users' processes; older systems
                    // show them, and only quitting is limited to your own.
                    if processes.hiddenCount > 0 {
                        Text(
                            "monitor.processes.footer \(String(processes.visibleCount)) \(String(processes.hiddenCount))"
                        )
                    } else {
                        Text("monitor.processes.footer.all \(String(processes.visibleCount))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // nettop only while the network list is on screen.
        .task(id: panelIsShown && monitor.processSort == .network) {
            guard panelIsShown, monitor.processSort == .network else {
                monitor.traffic.reset()
                return
            }
            while !Task.isCancelled {
                await monitor.traffic.refresh()
                try? await Task.sleep(for: AppTrafficModel.interval)
            }
        }
    }

    private var columns: ProcessColumns { ProcessColumns(detailed: detailed) }

    /// The busiest rows by the sorted column's chosen value, of the chosen
    /// kind; searching covers every process.
    private func sortedRows(_ processes: ProcessesSnapshot, query: String, limit: Int) -> [ProcessUsage] {
        let value: (ProcessUsage) -> Double
        switch (monitor.processSort, monitor.processCPUValue, monitor.processMemoryValue) {
        case (.cpu, .now, _): value = { $0.cpu }
        case (.cpu, .total, _): value = { $0.cpuSeconds }
        case (_, _, .peak): value = { Double($0.peakMemory) }
        default: value = { Double($0.memory) }
        }
        let kind = monitor.processKind
        return processes.rows.filter { row in
            guard value(row) > 0 else { return false }
            switch kind {
            case .all: break
            case .apps: guard ProcessActions.canActivate(row.identity) else { return false }
            case .background: guard !ProcessActions.canActivate(row.identity) else { return false }
            }
            return query.isEmpty || ProcessActions.name(for: row).localizedStandardContains(query)
                || row.name.localizedStandardContains(query)
        }
        .sorted { value($0) != value($1) ? value($0) > value($1) : $0.identity.pid < $1.identity.pid }
        .prefix(limit)
        .map { $0 }
    }

    /// Network since the Mac started per app, for the third column.
    private func networkTotals(_ processes: ProcessesSnapshot?) -> [ProcessIdentity: NetworkUse] {
        let rows = monitor.traffic.rows(processes: processes, span: .sinceStart) { _ in "" }
        return Dictionary(rows.compactMap { row in row.identity.map { ($0, row.use) } }, uniquingKeysWith: +)
    }
}

/// Widths of the value columns, shared by the titles and the rows.
struct ProcessColumns {
    let detailed: Bool
    var cpu: CGFloat { detailed ? 56 : 42 }
    var memory: CGFloat { detailed ? 80 : 62 }
    var network: CGFloat { detailed ? 92 : 68 }
    var font: Font { detailed ? .callout : .caption }
}

/// "CPU | Speicher | Netzwerk" as one centred pill control above the
/// list. A click sorts by that column; the sorted one is filled gold with
/// an arrow and its current choice under the title, and a click on it
/// opens its own choices: what the value means and which rows show.
private struct ColumnHeader: View {
    @Bindable var monitor: SystemMonitorModel
    @Bindable var traffic: AppTrafficModel
    let columns: ProcessColumns

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                segment(.cpu, "monitor.processes.cpu", symbol: "cpu") { cpuChoices }
                segment(.memory, "monitor.processes.memory", symbol: "memorychip") { memoryChoices }
                segment(.network, "monitor.processes.network", symbol: "arrow.up.arrow.down") { networkChoices }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            .frame(maxWidth: columns.detailed ? 420 : .infinity)
            if let filter {
                FilterChip(title: filter.title, symbol: filter.symbol, clear: filter.clear)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: monitor.processSort)
        .animation(.snappy(duration: 0.2), value: filter?.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("monitor.processes.sort"))
    }

    /// Which rows are hidden, in words, with a way back to all of them;
    /// nil when nothing is hidden.
    private var filter: (title: String, symbol: String, clear: () -> Void)? {
        if monitor.processSort == .network {
            switch traffic.route {
            case .all: return nil
            case .vpn:
                return (String(localized: "monitor.processes.filter.vpn"), "lock.shield", { traffic.route = .all })
            case .direct:
                return (String(localized: "monitor.processes.filter.direct"), "globe", { traffic.route = .all })
            }
        }
        switch monitor.processKind {
        case .all: return nil
        case .apps:
            return (String(localized: "monitor.processes.filter.apps"), "macwindow", { monitor.processKind = .all })
        case .background:
            return (
                String(localized: "monitor.processes.filter.background"), "gearshape.2",
                { monitor.processKind = .all }
            )
        }
    }

    @ViewBuilder
    private func segment<Choices: View>(
        _ order: ProcessOrder, _ title: LocalizedStringKey, symbol: String, @ViewBuilder choices: () -> Choices
    ) -> some View {
        let selected = monitor.processSort == order
        Group {
            if selected {
                Menu {
                    choices()
                } label: {
                    label(title, symbol: symbol, selected: true, caption: caption(order))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(Text("monitor.processes.choices"))
            } else {
                Button {
                    monitor.processSort = order
                } label: {
                    label(title, symbol: symbol, selected: false, caption: caption(order))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ title: LocalizedStringKey, symbol: String, selected: Bool, caption: String) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(title).lineLimit(1)
            }
            // One size for all three (no shrinking one of them); the small
            // card has less room.
            .font((columns.detailed ? Font.callout : .subheadline).weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Theme.goldText : .secondary)
            // Every segment says its current choice, so they read as
            // switches with settings; the sorted one's arrow sits on it.
            HStack(spacing: 2) {
                Text(verbatim: caption).lineLimit(1).minimumScaleFactor(0.75)
                if selected { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.caption2)
            .foregroundStyle(selected ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.gold.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.gold.opacity(0.45), lineWidth: 1))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// What the segment's number means, in plain words; which rows show
    /// is the chip's job.
    private func caption(_ order: ProcessOrder) -> String {
        switch order {
        case .cpu:
            String(
                localized: monitor.processCPUValue == .total
                    ? "monitor.processes.caption.cpuTime" : "monitor.processes.caption.cpuNow")
        case .memory:
            String(
                localized: monitor.processMemoryValue == .peak
                    ? "monitor.processes.caption.peak" : "monitor.processes.caption.inUse")
        case .network:
            String(
                localized: traffic.span == .now
                    ? "monitor.processes.caption.perSecond" : "monitor.processes.caption.sinceStart")
        }
    }

    @ViewBuilder private var cpuChoices: some View {
        Picker("monitor.processes.value", selection: $monitor.processCPUValue) {
            Label("monitor.processes.cpu.now", systemImage: "gauge.with.dots.needle.33percent").tag(ProcessCPUValue.now)
            Label("monitor.processes.cpu.total", systemImage: "clock").tag(ProcessCPUValue.total)
        }
        .pickerStyle(.inline)
        kindChoices
    }

    @ViewBuilder private var memoryChoices: some View {
        Picker("monitor.processes.value", selection: $monitor.processMemoryValue) {
            Label("monitor.processes.memory.now", systemImage: "memorychip").tag(ProcessMemoryValue.now)
            Label("monitor.processes.memory.peak", systemImage: "chart.line.uptrend.xyaxis").tag(
                ProcessMemoryValue.peak)
        }
        .pickerStyle(.inline)
        kindChoices
    }

    @ViewBuilder private var kindChoices: some View {
        Picker("monitor.processes.show", selection: $monitor.processKind) {
            Label("monitor.processes.kind.all", systemImage: "square.stack.3d.up").tag(ProcessKind.all)
            Label("monitor.processes.kind.apps", systemImage: "macwindow").tag(ProcessKind.apps)
            Label("monitor.processes.kind.background", systemImage: "gearshape.2").tag(ProcessKind.background)
        }
        .pickerStyle(.inline)
    }

    @ViewBuilder private var networkChoices: some View {
        Picker("monitor.traffic.span", selection: $traffic.span) {
            Label("monitor.traffic.now", systemImage: "speedometer").tag(AppTrafficModel.Span.now)
            Label("monitor.traffic.sinceStartShort", systemImage: "clock.arrow.circlepath").tag(
                AppTrafficModel.Span.sinceStart)
        }
        .pickerStyle(.inline)
        // Only while a VPN is up: by route.
        if !traffic.vpnInterfaces.isEmpty {
            Picker("monitor.traffic.route", selection: $traffic.route) {
                Label("monitor.traffic.all", systemImage: "network").tag(TrafficRoute.all)
                Label("monitor.traffic.vpn", systemImage: "lock.shield").tag(TrafficRoute.vpn)
                Label("monitor.traffic.direct", systemImage: "globe").tag(TrafficRoute.direct)
            }
            .pickerStyle(.inline)
        }
    }
}

/// "Nur Hintergrund-Prozesse ✕" under the sort control while rows are
/// hidden; the cross shows all of them again.
private struct FilterChip: View {
    let title: String
    let symbol: String
    let clear: () -> Void

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(verbatim: title).lineLimit(1)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.goldText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.gold.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("monitor.processes.filter.clear"))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text("monitor.processes.filter.clear"))
    }
}

/// The apps with the most traffic, download and upload per second.
private struct NetworkRows: View {
    @Bindable var monitor: SystemMonitorModel
    let traffic: AppTrafficModel
    let processes: ProcessesSnapshot?
    let query: String
    let limit: Int
    let columns: ProcessColumns

    var body: some View {
        let all = traffic.rows(processes: processes) { ProcessActions.name(for: $0) }
        let rows = traffic.top(all.filter { query.isEmpty || $0.name.localizedStandardContains(query) }, limit: limit)
        if !traffic.isAvailable {
            Text("monitor.traffic.unavailable").font(.caption).foregroundStyle(.secondary)
        } else if rows.isEmpty {
            Text(traffic.uses.isEmpty && query.isEmpty ? "monitor.traffic.measuring" : "monitor.traffic.none")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        let now =
            traffic.span == .sinceStart
            ? Dictionary(
                traffic.rows(processes: processes, span: .now) { ProcessActions.name(for: $0) }.map { ($0.id, $0.use) },
                uniquingKeysWith: { first, _ in first }) : [:]
        let totals =
            traffic.span == .now
            ? Dictionary(
                traffic.rows(processes: processes, span: .sinceStart) { ProcessActions.name(for: $0) }.map {
                    ($0.id, $0.use)
                }, uniquingKeysWith: { first, _ in first }) : [:]
        ForEach(rows) { row in
            let isOpen = monitor.expandedProcessRow == "net." + row.id
            HStack(spacing: 8) {
                Group {
                    if let identity = row.identity {
                        Image(nsImage: ProcessActions.icon(for: identity))
                    } else {
                        Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: row.name).font(.callout).lineLimit(1).truncationMode(.tail)
                    if traffic.route == .all, !traffic.vpnInterfaces.isEmpty {
                        Text(verbatim: routeText(row.use))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                let usage = row.identity.flatMap { identity in processes?.rows.first { $0.identity == identity } }
                Text(usage.map { MonitorFormat.percent($0.cpu) } ?? "–")
                    .font(columns.font).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: columns.cpu, alignment: .trailing)
                Text(usage.map { MonitorFormat.bytes($0.memory) } ?? "–")
                    .font(columns.font).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: columns.memory, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 0) {
                    rate("arrow.down", row.use.download(traffic.route)).foregroundStyle(Theme.goldText)
                    rate("arrow.up", row.use.upload(traffic.route)).foregroundStyle(.secondary)
                }
                .frame(width: columns.network, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { monitor.expandedProcessRow = isOpen ? nil : "net." + row.id }
            .accessibilityAddTraits(.isButton)
            if isOpen {
                let usage = row.identity.flatMap { identity in processes?.rows.first { $0.identity == identity } }
                ProcessDetails(
                    identity: row.identity, processCount: usage?.processCount ?? row.processCount,
                    cpuSeconds: usage?.cpuSeconds, memory: usage?.memory, peakMemory: usage?.peakMemory,
                    network: traffic.span == .sinceStart ? row.use : totals[row.id],
                    networkNow: traffic.span == .now ? row.use : now[row.id], actionsRow: usage)
            }
        }
        Text(
            traffic.span == .sinceStart
                ? "monitor.traffic.footer.total"
                : traffic.vpnInterfaces.isEmpty ? "monitor.traffic.footer" : "monitor.traffic.footer.vpn"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rate(_ symbol: String, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(
                verbatim: traffic.span == .now
                    ? MonitorFormat.rate(value)
                    : ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file)
            )
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    /// "VPN 80 % · direkt 20 %" for apps that use both.
    private func routeText(_ use: NetworkUse) -> String {
        let total = use.total(.all)
        guard total > 0 else { return "" }
        let vpn = use.total(.vpn) / total
        if vpn > 0.99 { return String(localized: "monitor.traffic.onlyVPN") }
        if vpn < 0.01 { return String(localized: "monitor.traffic.onlyDirect") }
        return String(
            format: String(localized: "monitor.traffic.mixed %@ %@"),
            vpn.formatted(.percent.precision(.fractionLength(0))),
            (1 - vpn).formatted(.percent.precision(.fractionLength(0))))
    }
}

private struct SearchPlaceholder: View {
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("monitor.processes.search").font(.callout)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @Binding var active: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("monitor.processes.search", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .onAppear { focused = true }
                // Back to the button when the field is left empty.
                .onChange(of: focused) { _, focused in
                    if !focused, text.isEmpty { active = false }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("monitor.processes.search.clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }
}

private struct ProcessRow: View {
    let row: ProcessUsage
    let sort: ProcessOrder
    let columns: ProcessColumns
    let network: NetworkUse?
    @Bindable var monitor: SystemMonitorModel

    private var key: String { "\(row.identity.pid).\(row.identity.started)" }
    private var isOpen: Bool { monitor.expandedProcessRow == key }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: ProcessActions.icon(for: row.identity))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: ProcessActions.name(for: row))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.processCount > 1 {
                        Text("monitor.processes.count \(String(row.processCount))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                // All three values; the sorted one stands out.
                value(
                    monitor.processCPUValue == .total ? Self.cpuTime(row.cpuSeconds) : MonitorFormat.percent(row.cpu),
                    active: sort == .cpu
                )
                .frame(width: columns.cpu, alignment: .trailing)
                value(
                    MonitorFormat.bytes(monitor.processMemoryValue == .peak ? row.peakMemory : row.memory),
                    active: sort == .memory
                )
                .frame(width: columns.memory, alignment: .trailing)
                value(network.map { ProcessDetails.bytes($0.total(.all)) } ?? "–", active: false).frame(
                    width: columns.network, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { monitor.expandedProcessRow = isOpen ? nil : key }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("monitor.details.hint"))
            if isOpen {
                ProcessDetails(
                    identity: row.identity, processCount: row.processCount, cpuSeconds: row.cpuSeconds,
                    memory: row.memory, peakMemory: row.peakMemory,
                    network: monitor.traffic.total(for: row.identity, processes: monitor.processes),
                    actionsRow: row)
            }
        }
    }

    /// CPU time short enough for the column: "45 s", "12 min", "3,4 h".
    static func cpuTime(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min" }
        return (seconds / 3_600).formatted(.number.precision(.fractionLength(1))) + " h"
    }

    private func value(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(columns.font.weight(active ? .semibold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(active ? AnyShapeStyle(Theme.goldText) : AnyShapeStyle(.secondary))
            .monospacedDigit()
    }
}

/// Since when an app runs and what it used in all that time: CPU time,
/// memory now and at its highest, network since the Mac started.
struct ProcessDetails: View {
    let identity: ProcessIdentity?
    let processCount: Int
    let cpuSeconds: Double?
    let memory: UInt64?
    let peakMemory: UInt64?
    let network: NetworkUse?
    var networkNow: NetworkUse?
    var actionsRow: ProcessUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let start = identity.flatMap({ ProcessInspector.startDate(of: $0) }) {
                line("clock", "monitor.details.running", Self.since(start))
            }
            if let cpuSeconds, cpuSeconds > 0 {
                line("cpu", "monitor.details.cpuTime", Self.duration(cpuSeconds))
            }
            if let memory, memory > 0 {
                line(
                    "memorychip", "monitor.details.memory",
                    [
                        MonitorFormat.bytes(memory),
                        peakMemory.map { String(localized: "monitor.details.peak \(MonitorFormat.bytes($0))") },
                    ]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if let networkNow, networkNow.total(.all) > 0 {
                line(
                    "arrow.up.arrow.down", "monitor.details.networkNow",
                    "↓ \(MonitorFormat.rate(networkNow.download(.all)))  ↑ \(MonitorFormat.rate(networkNow.upload(.all)))"
                )
            }
            if let network, network.total(.all) > 0 {
                line(
                    "network", "monitor.details.networkTotal",
                    "↓ \(Self.bytes(network.download(.all)))  ↑ \(Self.bytes(network.upload(.all)))")
                if network.total(.vpn) > 0 {
                    line(
                        "lock.shield", "monitor.details.viaVPN",
                        "↓ \(Self.bytes(network.download(.vpn)))  ↑ \(Self.bytes(network.upload(.vpn)))")
                }
            }
            if processCount > 1 {
                line("square.stack.3d.up", "monitor.details.processes", "\(processCount)")
            }
            if let row = actionsRow, ProcessActions.canAct(on: row.identity) {
                HStack(spacing: 6) {
                    if ProcessActions.canActivate(row.identity) {
                        action("monitor.details.activate", "macwindow") { ProcessActions.activate(row.identity) }
                    }
                    action("monitor.details.quit", "xmark.circle") { ProcessActions.quit(row) }
                    action("monitor.details.forceQuit", "bolt.slash") { ProcessActions.forceQuit(row) }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
        .padding(.leading, 26)
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).lineLimit(1).fixedSize()
        }
        .buttonStyle(PillButtonStyle())
        .font(.caption)
    }

    private func line(_ symbol: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
        }
    }

    /// "3 h 12 min (since 09:14)"; older than a day with the date.
    static func since(_ start: Date) -> String {
        let age = Date().timeIntervalSince(start)
        let span = Duration.seconds(Int64(max(age, 0))).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        let clock =
            age < 86_400
            ? start.formatted(date: .omitted, time: .shortened) : start.formatted(date: .abbreviated, time: .shortened)
        return "\(span) (\(clock))"
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(Int64(seconds.rounded())).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file)
    }
}
