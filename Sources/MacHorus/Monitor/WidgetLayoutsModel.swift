// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import CoreGraphics
import Foundation
import MacHorusCore
import MacHorusMonitor
import Observation
import SwiftUI

/// The widgets of every page in both panel widths, edited in place
/// ("Arrange"): drag to move (nothing else moves while dragging; a gold
/// outline shows where it lands, it moves when let go), − to remove, the
/// corner handle to resize, + to add. Saved after every change.
@MainActor
@Observable
final class WidgetLayoutsModel {
    static let key = "widgetLayouts"
    static let migratedKey = "widgetLayoutsMigrated"

    private(set) var layouts: WidgetLayouts
    /// The page whose widgets are being arranged (one at a time).
    var editing: WidgetPage?
    /// The widget held by the pointer while dragging.
    var dragging: WidgetKind?
    /// The "add widget" list is open.
    var isAdding = false
    /// Changes with every edit, so sampling follows the shown widgets.
    private(set) var revision = 0
    /// Heights growing widgets (the sound box) need to show everything
    /// without scrolling; the board adds rows below them.
    private(set) var neededHeights: [WidgetKind: CGFloat] = [:]

    func setNeededHeight(_ height: CGFloat, for kind: WidgetKind) {
        guard abs((neededHeights[kind] ?? 0) - height) > 1 else { return }
        neededHeights[kind] = height
    }

    init(defaults: UserDefaults = .standard) {
        // `-debug.defaultLayouts YES`: the default layouts, the saved ones untouched (renders).
        layouts =
            defaults.bool(forKey: "debug.defaultLayouts")
            ? WidgetLayouts() : WidgetLayouts(stored: defaults.data(forKey: Self.key))
        migrateMonitorArrangement(defaults)
        addVPNOnce(defaults)
    }

    func layout(_ page: WidgetPage, _ width: PanelWidth) -> WidgetLayout { layouts[page, width] }

    func remove(_ kind: WidgetKind, page: WidgetPage, width: PanelWidth) {
        edit(page, width) { $0.remove(kind) }
    }

    func add(_ kind: WidgetKind, page: WidgetPage, width: PanelWidth) {
        // Narrow: as a card; wide: half width, next to another.
        edit(page, width) { $0.add(kind, size: .medium) }
    }

    func setSize(_ kind: WidgetKind, _ size: WidgetSize, page: WidgetPage, width: PanelWidth) {
        edit(page, width) { $0.setSize(kind, size) }
    }

    /// The widget opened in place by a click: shown large until clicked
    /// again, without changing the saved layout.
    var peeking: WidgetKind?

    func reset(_ page: WidgetPage, _ width: PanelWidth) {
        layouts.reset(page, width)
        save()
    }

    func finishEditing() {
        editing = nil
        peeking = nil
        cancelDragging()
        isAdding = false
    }

    // MARK: Dragging (MacHorus' own, see WidgetBoard)

    /// Where the pointer is while dragging (board coordinates).
    var dragPointer: CGPoint?
    /// Where it will land if let go now.
    private(set) var drop: WidgetDrop?
    /// Where the widget was taken, from its top-left corner.
    @ObservationIgnored private(set) var grab: CGSize = .zero
    /// The widgets' frames when the drag began (they do not move until it ends).
    @ObservationIgnored private(set) var frames: [WidgetKind: CGRect] = [:]

    /// The widgets as shown when the drag began, the width, and how board
    /// points map to grid units.
    @ObservationIgnored private var dragItems: [WidgetItem] = []
    @ObservationIgnored private var dragWidth: PanelWidth = .compact
    @ObservationIgnored private var toGrid: (CGPoint) -> CGPoint = { $0 }

    func beginDragging(
        _ kind: WidgetKind, grab: CGSize, frames: [WidgetKind: CGRect], items: [WidgetItem], width: PanelWidth,
        toGrid: @escaping (CGPoint) -> CGPoint
    ) {
        self.grab = grab
        self.frames = frames
        dragItems = items
        dragWidth = width
        self.toGrid = toGrid
        drop = .stay
        dragging = kind
    }

    /// The pointer moved: only the landing place changes. What counts is
    /// the held card's centre, not the pointer (a card taken by its lower
    /// edge would otherwise land a row too low).
    func dragMoved(to pointer: CGPoint) {
        dragPointer = pointer
        guard let dragging, let frame = frames[dragging] else { return }
        let centre = CGPoint(
            x: pointer.x - grab.width + frame.width / 2, y: pointer.y - grab.height + frame.height / 2)
        let found = ReorderEngine.drop(at: toGrid(centre), items: dragItems, moving: dragging, width: dragWidth)
        if found != drop { drop = found }
    }

    /// Let go: the one change of the drag.
    func endDragging(page: WidgetPage, width: PanelWidth) {
        if let dragging, let drop { edit(page, width) { $0.apply(drop, moving: dragging) } }
        cancelDragging()
    }

    func cancelDragging() {
        dragging = nil
        dragPointer = nil
        drop = nil
        frames = [:]
        dragItems = []
    }

    func layoutSize(of kind: WidgetKind, page: WidgetPage? = nil, width: PanelWidth) -> WidgetSize? {
        let pages = page.map { [$0] } ?? WidgetPage.allCases
        for page in pages {
            if let item = layouts[page, width].items.first(where: { $0.kind == kind }) { return item.size }
        }
        return nil
    }

    private func edit(_ page: WidgetPage, _ width: PanelWidth, _ change: (inout WidgetLayout) -> Void) {
        var layout = layouts[page, width]
        change(&layout)
        guard layout != layouts[page, width] else { return }
        layouts[page, width] = layout
        save()
    }

    /// Debug runs (`-debug.dragDemo`) change the layout without keeping it.
    @ObservationIgnored var persists = true

    private func save() {
        if persists { UserDefaults.standard.set(layouts.stored, forKey: Self.key) }
        revision += 1
    }

    /// The VPN widget came after the first layouts were saved: it joins the
    /// monitor pages once, right after the network widget; removing it sticks.
    private func addVPNOnce(_ defaults: UserDefaults) {
        let key = "widgetVPNAdded"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        for width in PanelWidth.allCases {
            var layout = layouts[.monitor, width]
            guard !layout.contains(.vpn) else { continue }
            let kinds = layout.kinds
            layout.add(.vpn, size: .medium)
            // Dropped onto the widget after the network one takes its place.
            if let index = kinds.firstIndex(of: .network), index + 1 < kinds.count {
                layout.move(.vpn, onto: kinds[index + 1])
            }
            layouts[.monitor, width] = layout
        }
        defaults.set(layouts.stored, forKey: Self.key)
    }

    /// Once: the monitor's arrangement of 1.0.18–1.0.22 (order and hidden
    /// values per width) becomes its widget layouts.
    private func migrateMonitorArrangement(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        let expanded = defaults.dictionary(forKey: "monitorArrangement")
        let compact = defaults.dictionary(forKey: "monitorArrangementCompact")
        guard expanded != nil || compact != nil else { return }
        let wide = MonitorArrangement(stored: expanded)
        let narrow = MonitorArrangement(stored: compact, defaults: MonitorArrangement.compactOrder)
        layouts.adopt(oldExpandedOrder: wide.order, hiddenCompact: narrow.hidden, hiddenExpanded: wide.hidden)
        defaults.set(layouts.stored, forKey: Self.key)
        Log.app.notice("Monitor arrangement carried over into widget layouts")
    }
}
