// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import SwiftUI

/// The menu bar panel: header, section bar, the selected section, footer.
struct PanelRootView: View {
    let model: PanelModel
    @Bindable var navigation: PanelNavigation
    private let pageHeightOverride: CGFloat?

    /// `pageHeight` is set only in the development preview, so a whole
    /// section fits into one screenshot.
    init(model: PanelModel, pageHeight: CGFloat? = nil) {
        self.model = model
        pageHeightOverride = pageHeight
        navigation = model.navigation
    }

    private var pageHeight: CGFloat {
        pageHeightOverride ?? (navigation.isExpanded ? Theme.expandedPageHeight : Theme.pageHeight)
    }

    var body: some View {
        VStack(spacing: 16) {
            PanelHeader(tab: navigation.tab, isExpanded: $navigation.isExpanded)
            PanelTabBar(selection: $navigation.tab, isExpanded: navigation.isExpanded)
            ScrollViewReader { proxy in
                ScrollView {
                    page
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
                .frame(height: pageHeight)
                // An opened widget comes fully into view (only as far as needed).
                .onChange(of: model.widgets.peeking) {
                    guard model.widgets.peeking != nil else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(WidgetBoard.openedAnchor) }
                    }
                }
            }
            PanelFooter(usage: model.selfUsage.usage)
        }
        .padding(16)
        .frame(width: navigation.isExpanded ? Theme.expandedPanelWidth : Theme.panelWidth)
        .tint(Theme.gold)
        .environment(\.panelIsShown, navigation.isShown)
        .onChange(of: navigation.tab) { model.updateMonitorDemand() }
        .onChange(of: navigation.isExpanded) { model.updateMonitorDemand() }
        .onChange(of: model.widgets.revision) { model.updateMonitorDemand() }
        .onChange(of: model.widgets.isAdding) { model.updateMonitorDemand() }
        // Arranging ends when the panel closes or the section changes.
        .onChange(of: navigation.tab) { model.widgets.finishEditing() }
        .onChange(of: navigation.isShown) { if !navigation.isShown { model.widgets.finishEditing() } }
        .modifier(ToolPolling(model: model))
    }

    @ViewBuilder private var page: some View {
        switch navigation.tab {
        case .overview:
            WidgetBoard(page: .overview, model: model, layouts: model.widgets)
        case .monitor:
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                if model.monitor.isAnyMetricEnabled {
                    HealthStrip(monitor: model.monitor)
                } else {
                    MonitorOffCard(features: model.features)
                }
                WidgetBoard(page: .monitor, model: model, layouts: model.widgets)
            }
        case .tools:
            WidgetBoard(page: .tools, model: model, layouts: model.widgets)
        case .settings: SettingsPage(model: model, navigation: navigation)
        }
    }
}

private struct PanelHeader: View {
    let tab: PanelTab
    @Binding var isExpanded: Bool
    private let version = AppIdentity.currentVersion()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ImageThumbnail.appIcon)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(AppIdentity.name)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text(tab.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            // Neutral like the button next to it: gold read as a warning.
            Text(verbatim: "v" + version.description)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.primary.opacity(0.07)))
            Button {
                isExpanded.toggle()
            } label: {
                Image(
                    systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(0.07)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text(isExpanded ? "panel.collapse" : "panel.expand"))
            .accessibilityLabel(Text(isExpanded ? "panel.collapse" : "panel.expand"))
        }
    }
}

/// Icon segments for the panel sections. The selection switches without an
/// animation: every animation frame made SwiftUI walk the whole panel's
/// display list again, 80-90 ms CPU per switch (docs/MEASUREMENTS.md).
private struct PanelTabBar: View {
    @Binding var selection: PanelTab
    /// Wide panel: room for every name, the bar spans the whole width.
    var isExpanded = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    selection = tab
                } label: {
                    // The chosen section names itself; the others are symbols.
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        if selection == tab || isExpanded {
                            Text(verbatim: tab.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selection == tab ? Theme.lapisDeep : Color.secondary)
                    .padding(.horizontal, selection == tab ? 10 : 0)
                    // Even steps for the symbols; the named section up to 190 pt.
                    .frame(
                        minWidth: isExpanded || selection == tab ? nil : 52,
                        maxWidth: isExpanded ? .infinity : selection == tab ? 190 : 52, minHeight: 30
                    )
                    .background {
                        if selection == tab { Capsule().fill(Theme.goldGradient) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(tab.title) (⌘\(index + 1))"))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
    }
}

private struct PanelFooter: View {
    let usage: ResourceUsage?

    var body: some View {
        HStack {
            // Says whose values these are: MacHorus' own, not the Mac's.
            HStack(spacing: 6) {
                Image(nsImage: ImageThumbnail.appIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("panel.selfUsage.title")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("panel.selfUsage \(SelfUsageText.cpu(usage)) \(SelfUsageText.memory(usage))")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(0.06)))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .help(Text("panel.selfUsage.help"))
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("menu.quit", systemImage: "power")
            }
            .buttonStyle(PillButtonStyle())
            .keyboardShortcut("q")
        }
    }
}

/// Formats MacHorus' own resource use for display.
enum SelfUsageText {
    static func cpu(_ usage: ResourceUsage?) -> String {
        guard let cpu = usage?.cpuPercent else { return "–" }
        return cpu.formatted(.number.precision(.fractionLength(1))) + " %"
    }

    static func memory(_ usage: ResourceUsage?) -> String {
        guard let bytes = usage?.footprintBytes else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

/// Print jobs and drives are read while the panel shows a page with their
/// widget (the widgets stay hidden while there is nothing, and an empty
/// view would never run its own task).
private struct ToolPolling: ViewModifier {
    let model: PanelModel

    private var showsPrinters: Bool { shows(.printers) && model.tools?.printers.isEnabled == true }
    private var showsDrives: Bool { shows(.drives) && model.tools?.drives.isEnabled == true }

    private func shows(_ kind: WidgetKind) -> Bool {
        guard model.navigation.isShown, let page = model.widgetPage else { return false }
        return model.widgets.layout(page, model.panelWidth).contains(kind)
    }

    func body(content: Content) -> some View {
        content
            .task(id: showsPrinters) {
                while showsPrinters, let printers = model.tools?.printers, !Task.isCancelled {
                    await printers.refresh()
                    try? await Task.sleep(for: PrintersModel.interval)
                }
            }
            .task(id: showsDrives) {
                guard let drives = model.tools?.drives else { return }
                showsDrives ? drives.startWatching() : drives.stopWatching()
            }
    }
}
