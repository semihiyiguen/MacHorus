// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Everything the panel can show as a widget. Any widget can go on any
/// page (maintainer's choice); the defaults put each where it was before.
public enum WidgetKind: String, CaseIterable, Codable, Sendable {
    // Overview
    case mac
    case rings
    case clipboard
    case audio
    // Monitor
    case cpu
    case memory
    case network
    case disk
    case gpu
    case battery
    case thermal
    case processes
    /// Which VPN is up and which apps went through it.
    case vpn
    // Tools
    case keepAwake
    case networkCheck
    case updates
    case hardware
    case drives
    case printers
    case ports

    /// The monitor value it needs measured while it is on screen.
    public var metrics: Set<Metric> {
        switch self {
        case .mac: [.memory, .disk, .power, .thermal, .network]
        case .rings: [.cpu, .memory, .disk, .power]
        case .cpu: [.cpu]
        case .memory: [.memory]
        case .network: [.network]
        case .disk: [.disk]
        case .gpu: [.gpu]
        case .battery: [.power]
        case .thermal: [.thermal]
        case .processes: [.processes]
        default: []
        }
    }

    /// Groups in the "add widget" list.
    public enum Group: String, CaseIterable, Sendable {
        case overview
        case monitor
        case tools
    }

    public var group: Group {
        switch self {
        case .mac, .rings, .clipboard, .audio: .overview
        case .cpu, .memory, .network, .disk, .gpu, .battery, .thermal, .processes, .vpn: .monitor
        default: .tools
        }
    }
}

/// Five sizes on a fixed grid, like widgets on a phone (rows × columns of
/// the wide panel's four): 1×1, 1×2, 2×2, 1×4, 2×4. The bigger, the more it
/// shows. Raw values keep layouts saved earlier: their "small" is medium.
public enum WidgetSize: String, Codable, Sendable, CaseIterable {
    /// 1×1: one value.
    case small = "tile"
    /// 1×2: value and history.
    case medium = "small"
    /// 2×2: value, history and what uses it most.
    case square
    /// 1×4: the same side by side across the panel.
    case wide
    /// 2×4: everything.
    case large
    /// 4×4: everything, twice as high (long lists such as the processes).
    case tall

    /// Large enough for the whole card (no "click for more").
    public var isFull: Bool { self == .large || self == .tall }

    public var bigger: WidgetSize? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index + 1 < all.count ? all[index + 1] : nil
    }

    public var smaller: WidgetSize? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index > 0 ? all[index - 1] : nil
    }

    /// Click on the resize handle: the next size, from large back to small.
    public var next: WidgetSize { bigger ?? .small }

    /// Columns and rows it takes: four columns wide, two narrow. Narrow,
    /// 2×2 is half wide and 1×4 is the panel's width (like 1×2).
    public func footprint(_ width: PanelWidth) -> (columns: Int, rows: Int) {
        switch (self, width) {
        case (.small, _): (1, 1)
        case (.medium, _): (2, 1)
        case (.square, .expanded): (2, 2)
        case (.square, .compact): (1, 2)
        case (.wide, .expanded): (4, 1)
        case (.wide, .compact): (2, 1)
        case (.large, .expanded): (4, 2)
        case (.large, .compact): (2, 2)
        case (.tall, .expanded): (4, 4)
        case (.tall, .compact): (2, 4)
        }
    }

    /// The size with exactly this footprint, if any.
    public static func exactly(columns: Int, rows: Int, width: PanelWidth) -> WidgetSize? {
        allCases.first { $0.footprint(width) == (columns, rows) }
    }

    /// The size whose footprint is closest to `columns` × `rows` (pulling
    /// the resize handle); on a tie the smaller one.
    public static func nearest(columns: Double, rows: Double, width: PanelWidth) -> WidgetSize {
        allCases.min { a, b in
            func distance(_ size: WidgetSize) -> Double {
                let footprint = size.footprint(width)
                return pow(Double(footprint.columns) - columns, 2) + pow(Double(footprint.rows) - rows, 2)
            }
            return distance(a) < distance(b)
        }!
    }
}

/// Where a widget sits on the grid (in columns and rows).
public struct WidgetCell: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// Where a dragged widget goes when it is let go.
public enum WidgetDrop: Equatable, Sendable {
    case before(WidgetKind)
    case after(WidgetKind)
    case end
    /// Back to its own place: nothing changes.
    case stay
}

public struct WidgetItem: Equatable, Codable, Sendable, Identifiable {
    public var kind: WidgetKind
    public var size: WidgetSize
    public var id: WidgetKind { kind }

    public init(_ kind: WidgetKind, _ size: WidgetSize = .large) {
        self.kind = kind
        self.size = size
    }
}

/// A page of the panel with its own widgets.
public enum WidgetPage: String, CaseIterable, Codable, Sendable {
    case overview
    case monitor
    case tools
}

/// Narrow (360 pt) or wide (720 pt) panel: each has its own layouts.
public enum PanelWidth: String, CaseIterable, Codable, Sendable {
    case compact
    case expanded
}

/// The widgets of one page in one panel width, in order. A widget is at
/// most once on a page; it can be on several pages.
public struct WidgetLayout: Equatable, Codable, Sendable {
    public private(set) var items: [WidgetItem]

    public init(_ items: [WidgetItem]) {
        var seen = Set<WidgetKind>()
        self.items = items.filter { seen.insert($0.kind).inserted }
    }

    public var kinds: [WidgetKind] { items.map(\.kind) }

    public func contains(_ kind: WidgetKind) -> Bool { items.contains { $0.kind == kind } }

    /// Drag and drop: `kind` takes the place of `target`, which (with the
    /// ones after it) moves along, like widgets on a phone. Dragging over a
    /// later item puts it after, over an earlier one before it.
    public mutating func move(_ kind: WidgetKind, onto target: WidgetKind) {
        guard kind != target, let from = items.firstIndex(where: { $0.kind == kind }),
            let to = items.firstIndex(where: { $0.kind == target })
        else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    /// Moves to the very end (dropped below the last widget).
    public mutating func moveToEnd(_ kind: WidgetKind) {
        guard let from = items.firstIndex(where: { $0.kind == kind }) else { return }
        items.append(items.remove(at: from))
    }

    public mutating func add(_ kind: WidgetKind, size: WidgetSize = .medium) {
        guard !contains(kind) else { return }
        items.append(WidgetItem(kind, size))
    }

    public mutating func remove(_ kind: WidgetKind) {
        items.removeAll { $0.kind == kind }
    }

    public mutating func setSize(_ kind: WidgetKind, _ size: WidgetSize) {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[index].size = size
    }

    /// Puts the dragged widget where it was let go.
    public mutating func apply(_ drop: WidgetDrop, moving kind: WidgetKind) {
        switch drop {
        case .stay: return
        case .end: moveToEnd(kind)
        case .before(let target), .after(let target):
            guard kind != target, let from = items.firstIndex(where: { $0.kind == kind }) else { return }
            let item = items.remove(at: from)
            guard var to = items.firstIndex(where: { $0.kind == target }) else {
                items.insert(item, at: from)
                return
            }
            if case .after = drop { to += 1 }
            items.insert(item, at: to)
        }
    }

    public static func columns(_ width: PanelWidth) -> Int { width == .expanded ? 4 : 2 }

    /// A hole with widgets below it (a widget this Mac does not have, e.g. the
    /// battery on an iMac, leaves one in a layout made on a MacBook) is
    /// closed: the widget left of it widens to the next size that fits.
    /// The page's last widgets may end their row early, as arranged.
    public static func closingHoles(_ cells: [WidgetKind: WidgetCell], width: PanelWidth) -> [WidgetKind: WidgetCell] {
        let columns = columns(width)
        var taken = Set<Int>()
        func mark(_ cell: WidgetCell) {
            for r in cell.row..<(cell.row + cell.rows) {
                for c in cell.column..<(cell.column + cell.columns) { taken.insert(r * columns + c) }
            }
        }
        cells.values.forEach(mark)
        let widths = { (rows: Int) in
            Set(WidgetSize.allCases.map { $0.footprint(width) }.filter { $0.rows == rows }.map(\.columns)).sorted()
        }
        var result = cells
        for (kind, cell) in cells.sorted(by: { ($0.value.row, $0.value.column) < ($1.value.row, $1.value.column) }) {
            // Only where widgets follow below: the page's end may end early.
            guard cells.values.contains(where: { $0.row >= cell.row + cell.rows }) else { continue }
            for target in widths(cell.rows) where target > cell.columns && cell.column + target <= columns {
                let extra = (cell.column + cell.columns)..<(cell.column + target)
                let free = (cell.row..<(cell.row + cell.rows)).allSatisfy { r in
                    extra.allSatisfy { !taken.contains(r * columns + $0) }
                }
                guard free else { break }
                result[kind] = WidgetCell(column: cell.column, row: cell.row, columns: target, rows: cell.rows)
            }
            if let widened = result[kind], widened != cell { mark(widened) }
        }
        return result
    }

    /// The fixed grid: in order, each widget takes the first free place
    /// (top to bottom, left to right) where it fits, so small widgets fill
    /// the space beside a 2×2 like on a phone. Never overlapping.
    public static func place(_ items: [WidgetItem], width: PanelWidth) -> [WidgetKind: WidgetCell] {
        let columns = columns(width)
        var taken = Set<Int>()  // row * columns + column
        var cells: [WidgetKind: WidgetCell] = [:]
        for item in items {
            let footprint = item.size.footprint(width)
            let span = min(footprint.columns, columns)
            var row = 0
            search: while true {
                for column in 0...(columns - span) {
                    let fits = (row..<(row + footprint.rows)).allSatisfy { r in
                        (column..<(column + span)).allSatisfy { !taken.contains(r * columns + $0) }
                    }
                    if fits {
                        for r in row..<(row + footprint.rows) {
                            for c in column..<(column + span) { taken.insert(r * columns + c) }
                        }
                        cells[item.kind] = WidgetCell(column: column, row: row, columns: span, rows: footprint.rows)
                        break search
                    }
                }
                row += 1
            }
        }
        return cells
    }
}

/// All layouts (3 pages × 2 widths), stored as JSON.
public struct WidgetLayouts: Equatable, Codable, Sendable {
    private var layouts: [String: WidgetLayout]

    public init() {
        layouts = [:]
        for page in WidgetPage.allCases {
            for width in PanelWidth.allCases {
                layouts[Self.key(page, width)] = Self.defaultLayout(page, width)
            }
        }
    }

    static func key(_ page: WidgetPage, _ width: PanelWidth) -> String { "\(page.rawValue).\(width.rawValue)" }

    public subscript(page: WidgetPage, width: PanelWidth) -> WidgetLayout {
        get { layouts[Self.key(page, width)] ?? Self.defaultLayout(page, width) }
        set { layouts[Self.key(page, width)] = newValue }
    }

    public mutating func reset(_ page: WidgetPage, _ width: PanelWidth) {
        self[page, width] = Self.defaultLayout(page, width)
    }

    /// What every new user starts with: the maintainer arranged each page
    /// in both widths on their Mac, and that is the default. Ports
    /// (for developers) only via "+ Widget". In order; the grid fills the
    /// first free place, so a small widget after a large one may sit
    /// beside it (the narrow Monitor's battery beside the disk).
    public static func defaultLayout(_ page: WidgetPage, _ width: PanelWidth) -> WidgetLayout {
        func items(_ list: [(WidgetKind, WidgetSize)]) -> WidgetLayout {
            WidgetLayout(list.map { WidgetItem($0.0, $0.1) })
        }
        switch (page, width) {
        case (.overview, .expanded):
            return items([(.mac, .square), (.rings, .square), (.audio, .square), (.clipboard, .square)])
        case (.overview, .compact):
            return items([(.mac, .medium), (.rings, .medium), (.clipboard, .medium), (.audio, .large)])
        case (.monitor, .expanded):
            return items([
                (.cpu, .square), (.memory, .square), (.thermal, .medium), (.gpu, .medium), (.disk, .wide),
                (.network, .wide), (.vpn, .wide), (.processes, .tall),
            ])
        case (.monitor, .compact):
            return items([
                (.cpu, .small), (.memory, .small), (.gpu, .small), (.thermal, .small), (.network, .small),
                (.vpn, .small), (.disk, .small), (.processes, .large), (.battery, .small),
            ])
        case (.tools, .expanded):
            return items([
                (.updates, .medium), (.networkCheck, .medium), (.hardware, .medium), (.keepAwake, .medium),
                (.drives, .small), (.printers, .small),
            ])
        case (.tools, .compact):
            return items([
                (.updates, .medium), (.keepAwake, .medium), (.networkCheck, .medium), (.hardware, .medium),
                (.drives, .small), (.printers, .small),
            ])
        }
    }

    /// Unreadable data means the defaults; a missing page keeps its default.
    public init(stored data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode([String: WidgetLayout].self, from: data) else {
            self.init()
            return
        }
        self.init()
        for (key, layout) in decoded where layouts[key] != nil { layouts[key] = layout }
    }

    public var stored: Data? { try? JSONEncoder().encode(layouts) }

    /// The monitor's old arrangement (1.0.18–1.0.22): its hidden values
    /// leave the monitor pages, its wide order carries over.
    public mutating func adopt(oldExpandedOrder: [Metric], hiddenCompact: Set<Metric>, hiddenExpanded: Set<Metric>) {
        func kind(_ metric: Metric) -> WidgetKind {
            switch metric {
            case .cpu: .cpu
            case .memory: .memory
            case .network: .network
            case .disk: .disk
            case .gpu: .gpu
            case .power: .battery
            case .thermal: .thermal
            case .processes: .processes
            }
        }
        var expanded = WidgetLayout(oldExpandedOrder.map { WidgetItem(kind($0), .medium) })
        for metric in hiddenExpanded { expanded.remove(kind(metric)) }
        self[.monitor, .expanded] = expanded
        var compact = self[.monitor, .compact]
        for metric in hiddenCompact { compact.remove(kind(metric)) }
        self[.monitor, .compact] = compact
    }
}

extension WidgetItem {
    /// What it needs measured in its size: large CPU and memory widgets
    /// also list the apps that use them most.
    public var metrics: Set<Metric> {
        var metrics = kind.metrics
        if size.isFull, kind == .cpu || kind == .memory { metrics.insert(.processes) }
        return metrics
    }
}
