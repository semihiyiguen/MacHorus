// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreGraphics
import Testing

@testable import MacHorusMonitor

@Suite struct ReorderEngineTests {
    private func landing(_ items: [WidgetItem], _ drop: WidgetDrop, _ kind: WidgetKind, _ width: PanelWidth)
        -> WidgetCell?
    {
        var layout = WidgetLayout(items)
        layout.apply(drop, moving: kind)
        return WidgetLayout.place(layout.items, width: width)[kind]
    }

    @Test func itLandsWhereTheCardIsHeld() {
        let items: [WidgetItem] = [.init(.cpu, .medium), .init(.memory, .medium), .init(.network, .wide)]
        // Over its own place: stays.
        #expect(ReorderEngine.drop(at: CGPoint(x: 1, y: 0.5), items: items, moving: .cpu, width: .expanded) == .stay)
        // Held over the memory's place: takes it.
        let onMemory = ReorderEngine.drop(at: CGPoint(x: 3, y: 0.5), items: items, moving: .cpu, width: .expanded)
        #expect(landing(items, onMemory, .cpu, .expanded) == WidgetCell(column: 2, row: 0, columns: 2, rows: 1))
        // Held below everything: the grid would put it back up top anyway
        // (first free place), so nothing moves for nothing.
        #expect(ReorderEngine.drop(at: CGPoint(x: 1, y: 3.5), items: items, moving: .cpu, width: .expanded) == .stay)
        // A 1×4 held below the others goes below them.
        let wide: [WidgetItem] = [.init(.network, .wide), .init(.cpu, .medium), .init(.memory, .medium)]
        let below = ReorderEngine.drop(at: CGPoint(x: 2, y: 1.5), items: wide, moving: .network, width: .expanded)
        #expect(landing(wide, below, .network, .expanded) == WidgetCell(column: 0, row: 1, columns: 4, rows: 1))
    }

    /// The maintainer's monitor page: two 2×2 on top, two 1×1 below on
    /// the left, an empty half beside them. Held there, a 2×2 goes there.
    @Test func itReachesTheEmptyHalfBesideSmallWidgets() {
        let items: [WidgetItem] = [
            .init(.cpu, .square), .init(.memory, .square), .init(.thermal, .small), .init(.gpu, .small),
            .init(.disk, .wide), .init(.network, .wide), .init(.processes, .large),
        ]
        let drop = ReorderEngine.drop(at: CGPoint(x: 3, y: 2.5), items: items, moving: .cpu, width: .expanded)
        let cell = landing(items, drop, .cpu, .expanded)!
        #expect(cell.column <= 3 && 3 < cell.column + cell.columns && cell.row <= 2 && 2 < cell.row + cell.rows)
    }

    /// Any spot on a real page gives an answer that keeps every widget.
    @Test func everySpotKeepsThePageWhole() {
        let page = WidgetLayouts.defaultLayout(.monitor, .expanded)
        for x in stride(from: 0.0, through: 4.0, by: 0.5) {
            for y in stride(from: 0.0, through: 9.0, by: 0.5) {
                let drop = ReorderEngine.drop(
                    at: CGPoint(x: x, y: y), items: page.items, moving: .processes, width: .expanded)
                var result = page
                result.apply(drop, moving: .processes)
                #expect(Set(result.kinds) == Set(page.kinds))
            }
        }
    }
}
