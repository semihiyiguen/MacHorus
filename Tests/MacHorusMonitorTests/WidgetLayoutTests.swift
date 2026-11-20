// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct WidgetLayoutTests {
    private func layout(_ kinds: [WidgetKind]) -> WidgetLayout { WidgetLayout(kinds.map { WidgetItem($0, .small) }) }

    @Test func draggingOntoAWidgetTakesItsPlaceAndPushesItOn() {
        var page = layout([.cpu, .memory, .network, .disk])
        // Drag the disk onto the CPU: disk first, the rest move down.
        page.move(.disk, onto: .cpu)
        #expect(page.kinds == [.disk, .cpu, .memory, .network])
        // Drag the disk onto the network (later): it takes the network's place,
        // the ones in between move up, as on a phone.
        page.move(.disk, onto: .network)
        #expect(page.kinds == [.cpu, .memory, .network, .disk])
        page.move(.cpu, onto: .cpu)
        #expect(page.kinds == [.cpu, .memory, .network, .disk], "onto itself changes nothing")
        page.moveToEnd(.cpu)
        #expect(page.kinds.last == .cpu)
    }

    @Test func addRemoveAndResize() {
        var page = layout([.cpu])
        page.add(.clipboard)
        page.add(.cpu)
        #expect(page.kinds == [.cpu, .clipboard], "no widget twice on a page")
        page.setSize(.cpu, .large)
        #expect(page.items[0].size == .large)
        page.remove(.cpu)
        #expect(page.kinds == [.clipboard])
    }

    @Test func theGridFillsBesideA2x2LikeAPhone() {
        let items: [WidgetItem] = [
            .init(.cpu, .square), .init(.memory, .small), .init(.gpu, .small), .init(.battery, .small),
            .init(.thermal, .small), .init(.network, .wide), .init(.disk, .medium), .init(.processes, .large),
        ]
        let cells = WidgetLayout.place(items, width: .expanded)
        #expect(cells[.cpu] == WidgetCell(column: 0, row: 0, columns: 2, rows: 2))
        #expect(cells[.memory] == WidgetCell(column: 2, row: 0, columns: 1, rows: 1))
        #expect(cells[.gpu] == WidgetCell(column: 3, row: 0, columns: 1, rows: 1))
        #expect(cells[.battery] == WidgetCell(column: 2, row: 1, columns: 1, rows: 1))
        #expect(cells[.thermal] == WidgetCell(column: 3, row: 1, columns: 1, rows: 1))
        #expect(cells[.network] == WidgetCell(column: 0, row: 2, columns: 4, rows: 1))
        #expect(cells[.disk] == WidgetCell(column: 0, row: 3, columns: 2, rows: 1))
        #expect(cells[.processes] == WidgetCell(column: 0, row: 4, columns: 4, rows: 2))
        // Narrow: two columns; 2×2 is half wide and two rows high.
        let narrow = WidgetLayout.place(items, width: .compact)
        #expect(narrow[.cpu] == WidgetCell(column: 0, row: 0, columns: 1, rows: 2))
        #expect(narrow[.memory] == WidgetCell(column: 1, row: 0, columns: 1, rows: 1))
        #expect(narrow[.network] == WidgetCell(column: 0, row: 3, columns: 2, rows: 1))
    }

    @Test func noLayoutEverOverlapsOrLeavesTheGrid() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let items = WidgetKind.allCases.shuffled(using: &generator).prefix(Int.random(in: 1...21))
                .map { WidgetItem($0, WidgetSize.allCases.randomElement(using: &generator)!) }
            for width in PanelWidth.allCases {
                let cells = WidgetLayout.place(items, width: width)
                #expect(cells.count == items.count)
                var taken = Set<[Int]>()
                for cell in cells.values {
                    #expect(cell.column >= 0 && cell.column + cell.columns <= WidgetLayout.columns(width))
                    for r in cell.row..<(cell.row + cell.rows) {
                        for c in cell.column..<(cell.column + cell.columns) {
                            #expect(taken.insert([r, c]).inserted, "overlap at \(r),\(c)")
                        }
                    }
                }
            }
        }
    }

    /// What new users see: the maintainer's arrangement, each widget once,
    /// nothing overlapping (`place` guarantees that), ports only on request.
    @Test func theDefaultsAreTheDevelopersArrangement() {
        for page in WidgetPage.allCases {
            for width in PanelWidth.allCases {
                let layout = WidgetLayouts.defaultLayout(page, width)
                #expect(Set(layout.kinds).count == layout.kinds.count)
                #expect(!layout.contains(.ports))
            }
        }
        // No hole above the last row on any page (a last row may end early).
        for page in WidgetPage.allCases {
            for width in PanelWidth.allCases {
                let cells = WidgetLayout.place(WidgetLayouts.defaultLayout(page, width).items, width: width).values
                let rows = cells.map { $0.row + $0.rows }.max() ?? 0
                var taken = Set<[Int]>()
                for cell in cells {
                    for r in cell.row..<(cell.row + cell.rows) {
                        for c in cell.column..<(cell.column + cell.columns) { taken.insert([r, c]) }
                    }
                }
                for r in 0..<max(rows - 1, 0) {
                    for c in 0..<WidgetLayout.columns(width) {
                        #expect(taken.contains([r, c]), "\(page) \(width): hole at row \(r), column \(c)")
                    }
                }
            }
        }
        #expect(WidgetLayouts.defaultLayout(.monitor, .expanded).items.last == WidgetItem(.processes, .tall))
        // Narrow Monitor: the battery fills the place beside the disk.
        let narrow = WidgetLayout.place(WidgetLayouts.defaultLayout(.monitor, .compact).items, width: .compact)
        #expect(narrow[.battery] == WidgetCell(column: 1, row: 3, columns: 1, rows: 1))
    }

    /// The narrow Monitor default on a Mac without a battery: the disk
    /// would stand alone; it widens instead of leaving a hole.
    @Test func aMissingWidgetLeavesNoHole() {
        let items = WidgetLayouts.defaultLayout(.monitor, .compact).items.filter { $0.kind != .battery }
        let cells = WidgetLayout.closingHoles(WidgetLayout.place(items, width: .compact), width: .compact)
        #expect(cells[.disk] == WidgetCell(column: 0, row: 3, columns: 2, rows: 1))
        #expect(WidgetSize.exactly(columns: 2, rows: 1, width: .compact) == .medium)
        // Every page without any one widget: still no hole above the last row.
        for page in WidgetPage.allCases {
            for width in PanelWidth.allCases {
                let all = WidgetLayouts.defaultLayout(page, width).items
                for missing in all.map(\.kind) {
                    let cells = WidgetLayout.closingHoles(
                        WidgetLayout.place(all.filter { $0.kind != missing }, width: width), width: width)
                    let rows = cells.values.map { $0.row + $0.rows }.max() ?? 0
                    var taken = Set<[Int]>()
                    for cell in cells.values {
                        for r in cell.row..<(cell.row + cell.rows) {
                            for c in cell.column..<(cell.column + cell.columns) {
                                #expect(taken.insert([r, c]).inserted)
                            }
                        }
                    }
                    // A hole counts when a widget starts below it.
                    let holes = (0..<rows).flatMap { r in
                        (0..<WidgetLayout.columns(width)).filter { !taken.contains([r, $0]) }.map { [r, $0] }
                    }.filter { hole in cells.values.contains { $0.row > hole[0] } }
                    #expect(holes.isEmpty, "\(page) \(width) without \(missing): holes \(holes)")
                }
            }
        }
    }

    @Test func pullingTheHandleSnapsToTheNearestSize() {
        #expect(WidgetSize.nearest(columns: 1.2, rows: 0.9, width: .expanded) == .small)
        #expect(WidgetSize.nearest(columns: 2.1, rows: 1.8, width: .expanded) == .square)
        #expect(WidgetSize.nearest(columns: 3.8, rows: 1.1, width: .expanded) == .wide)
        #expect(WidgetSize.nearest(columns: 4, rows: 2.3, width: .expanded) == .large)
        #expect(WidgetSize.nearest(columns: 1, rows: 2, width: .compact) == .square)
        #expect(WidgetSize.nearest(columns: 2, rows: 1, width: .compact) == .medium)
    }

    @Test func dropsPutTheWidgetBeforeOrAfterItsTarget() {
        var page = layout([.cpu, .memory, .network, .disk])
        page.apply(.after(.network), moving: .cpu)
        #expect(page.kinds == [.memory, .network, .cpu, .disk])
        page.apply(.before(.memory), moving: .disk)
        #expect(page.kinds == [.disk, .memory, .network, .cpu])
        page.apply(.stay, moving: .disk)
        page.apply(.before(.disk), moving: .disk)
        #expect(page.kinds == [.disk, .memory, .network, .cpu])
        page.apply(.end, moving: .disk)
        #expect(page.kinds.last == .disk)
    }

    @Test func sizesStepAndOldLayoutsKeepTheirLook() throws {
        #expect(WidgetSize.allCases == [.small, .medium, .square, .wide, .large, .tall])
        #expect(WidgetSize.medium.bigger == .square && WidgetSize.square.smaller == .medium)
        #expect(WidgetSize.tall.next == .small && WidgetSize.small.smaller == nil)
        // A layout saved with two sizes: its "small" (half width) is medium now.
        let old = Data(#"{"kind":"cpu","size":"small"}"#.utf8)
        #expect(try JSONDecoder().decode(WidgetItem.self, from: old).size == .medium)
    }

    @Test func storedLayoutsRoundTripAndFallBackToDefaults() {
        var layouts = WidgetLayouts()
        var tools = layouts[.tools, .compact]
        tools.remove(.ports)
        tools.add(.cpu)
        layouts[.tools, .compact] = tools
        #expect(WidgetLayouts(stored: layouts.stored) == layouts)
        #expect(WidgetLayouts(stored: Data("garbage".utf8)) == WidgetLayouts())
        #expect(WidgetLayouts(stored: nil)[.overview, .expanded].kinds.prefix(4) == [.mac, .rings, .audio, .clipboard])
    }

    @Test func theOldMonitorArrangementCarriesOver() {
        var layouts = WidgetLayouts()
        layouts.adopt(
            oldExpandedOrder: [.disk, .cpu, .memory, .network, .gpu, .power, .thermal, .processes],
            hiddenCompact: [.gpu], hiddenExpanded: [.thermal])
        #expect(layouts[.monitor, .expanded].kinds.first == .disk)
        #expect(!layouts[.monitor, .expanded].contains(.thermal))
        #expect(!layouts[.monitor, .compact].contains(.gpu))
        #expect(layouts[.monitor, .compact].contains(.thermal))
    }
}

@Suite struct WidgetMetricsTests {
    @Test func largeCPUAndMemoryAlsoNeedTheProcessList() {
        #expect(WidgetItem(.cpu, .small).metrics == [.cpu])
        #expect(WidgetItem(.cpu, .large).metrics == [.cpu, .processes])
        #expect(WidgetItem(.memory, .large).metrics == [.memory, .processes])
        #expect(WidgetItem(.disk, .large).metrics == [.disk])
    }
}
