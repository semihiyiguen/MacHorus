// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusMonitor
import SwiftUI
import UniformTypeIdentifiers

/// A page made of widgets on a fixed grid, like a phone: 1×1, 1×2, 2×2,
/// 1×4 and 2×4 (rows × columns of the wide panel's four). "Arrange" edits
/// it in place: hold a widget and drag it; nothing else moves meanwhile, a
/// gold outline shows where it will land, and it moves there when let go
/// (one animation). − removes, the corner handle resizes to where it is
/// pulled, + adds any widget.
struct WidgetBoard: View {
    let page: WidgetPage
    let model: PanelModel
    @Bindable var layouts: WidgetLayoutsModel
    @State private var boardWidth: CGFloat = 0
    @Environment(\.panelIsShown) private var panelIsShown

    private var width: PanelWidth { model.navigation.isExpanded ? .expanded : .compact }
    private var isEditing: Bool { layouts.editing == page }

    /// What shows: every available widget, exactly as arranged. (Hiding
    /// an empty VPN, drives or printers widget let the grid close the gap,
    /// so the page no longer looked as arranged.)
    private var items: [WidgetItem] {
        // `-debug.allSize tile|small|square|wide|large` shows every widget in
        // that size (renders of every size; raw values as stored).
        let forced = UserDefaults.standard.string(forKey: "debug.allSize").flatMap(WidgetSize.init(rawValue:))
        return layouts.layout(page, width).items.map { item -> WidgetItem in
            if let forced { return WidgetItem(item.kind, forced) }
            return item
        }.filter { WidgetAvailability.isAvailable($0.kind, model) }
    }

    private var metrics: WidgetGridMetrics {
        WidgetGridMetrics(
            width: boardWidth > 0
                ? boardWidth : (width == .expanded ? Theme.expandedPanelWidth : Theme.panelWidth) - 32,
            columns: WidgetLayout.columns(width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.pageSpacing) {
            if isEditing { EditBar(page: page, width: width, layouts: layouts) }
            if isEditing, layouts.isAdding {
                AddWidgetList(page: page, width: width, model: model, layouts: layouts)
            }
            let items = items
            if items.isEmpty {
                Text("widget.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                // Holes from widgets this Mac lacks close; each widget shows
                // in the size of its (possibly widened) cell.
                let placed = WidgetLayout.closingHoles(WidgetLayout.place(items, width: width), width: width)
                let metrics = metrics
                // While not arranging, a growing widget gets the rows it needs.
                let cells = isEditing ? placed : grown(placed, metrics: metrics)
                let items = items.map { item in
                    cells[item.kind].flatMap { WidgetSize.exactly(columns: $0.columns, rows: $0.rows, width: width) }
                        .map { WidgetItem(item.kind, $0) } ?? item
                }
                let peekHeight = 3 * metrics.rowHeight + 2 * metrics.spacing
                WidgetGrid(metrics: metrics) {
                    ForEach(items) { item in
                        cell(item, frame: metrics.rect(cells[item.kind]!), cells: cells, metrics: metrics, items: items)
                            .layoutValue(key: WidgetCellKey.self, value: cells[item.kind]!)
                    }
                }
                .environment(\.panelCardFillsHeight, true)
                // Room for an opened widget even on a short page.
                .frame(minHeight: layouts.peeking != nil && !isEditing ? peekHeight : 0, alignment: .top)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    boardWidth = $0
                }
                .coordinateSpace(.named(WidgetBoard.space))
                .overlay(alignment: .topLeading) {
                    if !isEditing, let kind = layouts.peeking, let cell = cells[kind] {
                        OpenedWidget(
                            kind: kind, width: width, model: model, layouts: layouts, from: metrics.rect(cell),
                            boardWidth: metrics.width, height: peekHeight)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isEditing {
                        LandingOutline(items: items, width: width, metrics: metrics, layouts: layouts)
                        FloatingWidget(
                            layouts: layouts, width: width, model: model,
                            frame: layouts.dragging.flatMap { cells[$0] }.map(metrics.rect))
                    }
                }
                .padding(.bottom, isEditing ? 44 : 0)
            }
            // Small, at the page's end on the left: out of the way of the widgets.
            if !isEditing { ArrangeButton(page: page, layouts: layouts) }
        }
        // Only real changes animate (a drop, a size, add, remove), never a drag in progress.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: layouts.layout(page, width))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: layouts.neededHeights)
        // The VPN widget shows only while a VPN is up: look once when the page opens.
        .task(id: panelIsShown) {
            if panelIsShown, layouts.layout(page, width).contains(.vpn) { await model.monitor.traffic.refresh() }
        }
    }

    /// Adds rows to widgets whose content needs them (at most six); every
    /// widget that starts below one moves down by as much, those beside
    /// it stay. Saved layouts never change.
    private func grown(_ cells: [WidgetKind: WidgetCell], metrics: WidgetGridMetrics) -> [WidgetKind: WidgetCell] {
        var cells = cells
        for (kind, needed) in layouts.neededHeights.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let cell = cells[kind] else { continue }
            let short = needed - metrics.rect(cell).height
            guard short > 1 else { continue }
            let extra = min(Int((short / (metrics.rowHeight + metrics.spacing)).rounded(.up)), 6)
            let bottom = cell.row + cell.rows
            for (other, otherCell) in cells where other != kind && otherCell.row >= bottom {
                cells[other] = WidgetCell(
                    column: otherCell.column, row: otherCell.row + extra, columns: otherCell.columns,
                    rows: otherCell.rows)
            }
            cells[kind] = WidgetCell(column: cell.column, row: cell.row, columns: cell.columns, rows: cell.rows + extra)
        }
        return cells
    }

    nonisolated static let space = "widgetBoard"
    /// The page scrolls to an opened widget by this id.
    nonisolated static let openedAnchor = "openedWidget"

    @ViewBuilder private func cell(
        _ item: WidgetItem, frame: CGRect, cells: [WidgetKind: WidgetCell], metrics: WidgetGridMetrics,
        items: [WidgetItem]
    ) -> some View {
        if isEditing {
            EditableWidget(
                item: item, page: page, width: width, frame: frame, metrics: metrics, layouts: layouts,
                frames: cells.mapValues(metrics.rect), items: items
            ) {
                WidgetView(kind: item.kind, size: item.size, width: width, model: model)
            }
        } else {
            WidgetView(kind: item.kind, size: item.size, width: width, model: model)
                .contentShape(Rectangle())
                // A click shows more (its controls keep their own clicks).
                .onTapGesture {
                    guard !item.size.isFull else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { layouts.peeking = item.kind }
                }
                .help(!item.size.isFull ? Text("widget.tapForMore") : Text(verbatim: ""))
        }
    }
}

/// A widget opened by a click: it grows out of its own place, over its
/// own page (nothing else moves), at the panel's width and three rows
/// high, with the rest dimmed; the page scrolls to it. A click beside it
/// or the button closes it again, back into its place.
private struct OpenedWidget: View {
    let kind: WidgetKind
    let width: PanelWidth
    let model: PanelModel
    let layouts: WidgetLayoutsModel
    let from: CGRect
    let boardWidth: CGFloat
    let height: CGFloat
    @State private var boardHeight: CGFloat = 0

    var body: some View {
        // Over its own row where possible, never below the page's end.
        let top = min(max(0, from.midY - height / 2), max(0, boardHeight - height))
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.28)
                .clipShape(shape)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .transition(.opacity)
            WidgetView(kind: kind, size: .large, width: width, model: model)
                // As high as its content, at most three rows (longer scrolls inside).
                .environment(\.panelCardFillsHeight, false)
                .frame(width: boardWidth)
                .frame(maxHeight: height)
                .fixedSize(horizontal: false, vertical: true)
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.gold.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.primary.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help(Text("widget.collapse"))
                    .accessibilityLabel(Text("widget.collapse"))
                }
                .offset(y: top)
                .transition(
                    .scale(scale: 0.4, anchor: UnitPoint(x: from.midX / max(boardWidth, 1), y: 0))
                        .combined(with: .opacity))
            // The page scrolls to this marker (the card's place and size).
            Color.clear
                .frame(width: 1, height: height)
                .offset(y: top)
                .id(WidgetBoard.openedAnchor)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            boardHeight = $0
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { layouts.peeking = nil }
    }
}

/// Column width, row height and gaps of the grid at a given width.
struct WidgetGridMetrics: Equatable {
    let width: CGFloat
    let columns: Int
    var spacing: CGFloat = Theme.widgetSpacing
    var rowHeight: CGFloat = Theme.widgetRow

    var column: CGFloat { (width - CGFloat(columns - 1) * spacing) / CGFloat(columns) }

    /// A board point in grid units (x columns, y rows; gaps count to the
    /// cell before them).
    func gridPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / (column + spacing), y: point.y / (rowHeight + spacing))
    }

    func rect(_ cell: WidgetCell) -> CGRect {
        CGRect(
            x: CGFloat(cell.column) * (column + spacing), y: CGFloat(cell.row) * (rowHeight + spacing),
            width: CGFloat(cell.columns) * column + CGFloat(cell.columns - 1) * spacing,
            height: CGFloat(cell.rows) * rowHeight + CGFloat(cell.rows - 1) * spacing)
    }
}

struct WidgetCellKey: LayoutValueKey {
    static let defaultValue = WidgetCell(column: 0, row: 0, columns: 1, rows: 1)
}

/// Places every widget in its cell, at its cell's size: nothing is
/// measured, so the grid never shifts by itself.
struct WidgetGrid: Layout {
    let metrics: WidgetGridMetrics

    private func metrics(_ proposal: ProposedViewSize) -> WidgetGridMetrics {
        var metrics = metrics
        if let width = proposal.width, width > 0, width.isFinite {
            metrics = WidgetGridMetrics(width: width, columns: metrics.columns)
        }
        return metrics
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = metrics(proposal)
        let height = subviews.map { metrics.rect($0[WidgetCellKey.self]).maxY }.max() ?? 0
        return CGSize(width: metrics.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(ProposedViewSize(width: bounds.width, height: nil))
        for subview in subviews {
            let rect = metrics.rect(subview[WidgetCellKey.self])
            subview.place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
    }
}

/// While dragging: where the widget will land if let go now, in its size.
private struct LandingOutline: View {
    let items: [WidgetItem]
    let width: PanelWidth
    let metrics: WidgetGridMetrics
    let layouts: WidgetLayoutsModel

    var body: some View {
        if let kind = layouts.dragging, let drop = layouts.drop, drop != .stay {
            let landed: WidgetLayout = {
                var layout = WidgetLayout(items)
                layout.apply(drop, moving: kind)
                return layout
            }()
            if let cell = WidgetLayout.place(landed.items, width: width)[kind] {
                let rect = metrics.rect(cell)
                let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                shape.fill(Theme.gold.opacity(0.14))
                    .overlay(shape.strokeBorder(Theme.gold, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6])))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: rect)
            }
        }
    }
}

/// The held widget, following the pointer above the others: a little
/// larger, deckend, with a shadow and a gold dashed edge in its real size.
private struct FloatingWidget: View {
    let layouts: WidgetLayoutsModel
    let width: PanelWidth
    let model: PanelModel
    let frame: CGRect?

    var body: some View {
        if let kind = layouts.dragging, let pointer = layouts.dragPointer, let frame,
            let size = layouts.layoutSize(of: kind, width: width)
        {
            let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            WidgetView(kind: kind, size: size, width: width, model: model)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                // Cards are see-through on the panel; lifted, it hides what is below.
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.gold, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .offset(x: pointer.x - layouts.grab.width, y: pointer.y - layouts.grab.height)
                .allowsHitTesting(false)
        }
    }
}

/// A widget while arranging: dashed outline, − top left, the size handle
/// bottom right; dragging it anywhere else moves it. Its own controls do
/// nothing meanwhile. While held, its place stays dimmed.
private struct EditableWidget<Content: View>: View {
    let item: WidgetItem
    let page: WidgetPage
    let width: PanelWidth
    let frame: CGRect
    let metrics: WidgetGridMetrics
    let layouts: WidgetLayoutsModel
    /// Every widget's frame now (taken as they are when a drag begins).
    let frames: [WidgetKind: CGRect]
    /// The widgets shown, in order (the drop tries its places among them).
    let items: [WidgetItem]
    @ViewBuilder var content: Content

    var body: some View {
        let isHeld = layouts.dragging == item.kind
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        content
            .allowsHitTesting(false)
            .opacity(isHeld ? 0.3 : 1)
            .overlay(
                shape.strokeBorder(
                    Theme.gold.opacity(isHeld ? 0.3 : 0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(WidgetBoard.space))
                    .onChanged { value in
                        if layouts.dragging != item.kind {
                            layouts.beginDragging(
                                item.kind,
                                grab: CGSize(
                                    width: value.startLocation.x - frame.minX,
                                    height: value.startLocation.y - frame.minY),
                                frames: frames, items: items, width: width, toGrid: metrics.gridPoint)
                        }
                        layouts.dragMoved(to: value.location)
                    }
                    .onEnded { _ in layouts.endDragging(page: page, width: width) }
            )
            .overlay(alignment: .topLeading) {
                if !isHeld {
                    CornerButton(symbol: "minus.circle.fill", tint: Theme.critical, help: "widget.remove") {
                        layouts.remove(item.kind, page: page, width: width)
                    }
                    .offset(x: -6, y: -6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isHeld {
                    ResizeHandle(item: item, page: page, width: width, frame: frame, metrics: metrics, layouts: layouts)
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(WidgetTexts.title(item.kind)))
    }
}

/// Bottom-right corner: pull it and the widget takes the size closest to
/// where it is pulled (1×1 … 2×4); a click steps to the next size. It grows
/// a little while held (no hover effect: hover handlers cost CPU on every
/// pointer move).
private struct ResizeHandle: View {
    let item: WidgetItem
    let page: WidgetPage
    let width: PanelWidth
    let frame: CGRect
    let metrics: WidgetGridMetrics
    let layouts: WidgetLayoutsModel
    @State private var isPressed = false
    @State private var origin: CGPoint?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Theme.lapis))
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            .scaleEffect(isPressed ? 1.3 : 1)
            .shadow(color: .black.opacity(isPressed ? 0.3 : 0), radius: 4, y: 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
            .contentShape(Circle().inset(by: -6))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(WidgetBoard.space))
                    .onChanged { value in
                        isPressed = true
                        // The widget's top-left corner when the pull began (it stays put).
                        let origin = self.origin ?? frame.origin
                        self.origin = origin
                        let columns =
                            (value.location.x - origin.x + metrics.spacing) / (metrics.column + metrics.spacing)
                        let rows =
                            (value.location.y - origin.y + metrics.spacing) / (metrics.rowHeight + metrics.spacing)
                        guard abs(value.translation.width) + abs(value.translation.height) > 6 else { return }
                        let size = WidgetSize.nearest(columns: Double(columns), rows: Double(rows), width: width)
                        if size != layouts.layoutSize(of: item.kind, page: page, width: width) {
                            layouts.setSize(item.kind, size, page: page, width: width)
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.width) + abs(value.translation.height) <= 6 {
                            layouts.setSize(item.kind, item.size.next, page: page, width: width)
                        }
                        origin = nil
                        isPressed = false
                    }
            )
            .help(Text("widget.resize"))
            .accessibilityLabel(Text("widget.resize"))
            .accessibilityAddTraits(.isButton)
    }
}

/// "Arrange" on the right; while arranging: add, default, done.
private struct EditBar: View {
    let page: WidgetPage
    let width: PanelWidth
    @Bindable var layouts: WidgetLayoutsModel

    var body: some View {
        HStack(spacing: 6) {
            if width == .expanded {
                Text("monitor.arrange.expanded")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                layouts.isAdding.toggle()
            } label: {
                Label("widget.add", systemImage: "plus").lineLimit(1).fixedSize()
            }
            .buttonStyle(PillButtonStyle())
            Button("monitor.arrange.reset") { layouts.reset(page, width) }
                .buttonStyle(PillButtonStyle())
            Button("monitor.arrange.done") { layouts.finishEditing() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .font(.caption)
    }
}

/// "Anordnen": small, at the bottom left of every page.
private struct ArrangeButton: View {
    let page: WidgetPage
    let layouts: WidgetLayoutsModel

    var body: some View {
        Button {
            layouts.finishEditing()
            layouts.editing = page
        } label: {
            Label("monitor.arrange", systemImage: "square.grid.2x2")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CornerButton: View {
    let symbol: String
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .background(Circle().fill(.background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// The widget gallery, like a phone's: every widget not yet on this page
/// as a live miniature with its name, by group; a click adds it at the end.
private struct AddWidgetList: View {
    let page: WidgetPage
    let width: PanelWidth
    let model: PanelModel
    let layouts: WidgetLayoutsModel

    var body: some View {
        let onPage = Set(layouts.layout(page, width).kinds)
        PanelCard(spacing: 10) {
            ForEach(WidgetKind.Group.allCases, id: \.self) { group in
                let kinds = WidgetKind.allCases.filter {
                    $0.group == group && !onPage.contains($0) && WidgetAvailability.isAvailable($0, model)
                }
                if !kinds.isEmpty {
                    Text(WidgetTexts.group(group))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8
                    ) {
                        ForEach(kinds, id: \.self) { kind in
                            GalleryTile(kind: kind, model: model) { layouts.add(kind, page: page, width: width) }
                        }
                    }
                }
            }
            if WidgetKind.allCases.allSatisfy({ onPage.contains($0) || !WidgetAvailability.isAvailable($0, model) }) {
                Text("widget.allAdded").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One widget in the gallery: the real widget, scaled down and inert, so
/// what it shows is visible before adding it; a green + to add.
private struct GalleryTile: View {
    let kind: WidgetKind
    let model: PanelModel
    let add: () -> Void

    /// The widget in its 1×2 size at the narrow panel's width, scaled down.
    static let renderWidth: CGFloat = 328
    static let scale: CGFloat = 0.42

    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetView(kind: kind, size: .medium, width: .compact, model: model)
                    .environment(\.panelCardFillsHeight, true)
                    .frame(width: Self.renderWidth, height: Theme.widgetRow)
                    .allowsHitTesting(false)
                    .scaleEffect(Self.scale, anchor: .topLeading)
                    .frame(
                        width: Self.renderWidth * Self.scale, height: Theme.widgetRow * Self.scale,
                        alignment: .topLeading
                    )
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.positive)
                            .padding(2)
                    }
                Label(WidgetTexts.title(kind), systemImage: WidgetTexts.symbol(kind))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text("widget.addHelp"))
        .accessibilityLabel(Text(WidgetTexts.title(kind)))
        .accessibilityHint(Text("widget.addHelp"))
    }
}
