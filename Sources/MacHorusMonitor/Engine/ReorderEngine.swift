// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreGraphics

/// Where a dragged widget will land. The page tries every place the
/// widget could take in the order (before each other widget, at the end,
/// where it is) and keeps the one that puts it under the dragged card's
/// centre; of equal ones, the one that moves the fewest others. So it
/// lands where it is held, also in an empty cell beside smaller widgets
/// (the grid fills the first free place, which a before/after rule alone
/// could not reach). Nothing moves while dragging, so the answer for a
/// spot never changes.
public enum ReorderEngine {
    /// `point`: the card's centre in grid units (x in columns, y in rows;
    /// cell (c, r) spans c..<c+1, r..<r+1).
    public static func drop(at point: CGPoint, items: [WidgetItem], moving: WidgetKind, width: PanelWidth)
        -> WidgetDrop
    {
        guard items.contains(where: { $0.kind == moving }) else { return .stay }
        let before = WidgetLayout.place(items, width: width)
        let candidates: [WidgetDrop] =
            [.stay] + items.map(\.kind).filter { $0 != moving }.map { .before($0) } + [.end]
        var best: (drop: WidgetDrop, distance: CGFloat, moved: Int)?
        for drop in candidates {
            var layout = WidgetLayout(items)
            layout.apply(drop, moving: moving)
            let cells = WidgetLayout.place(layout.items, width: width)
            guard let cell = cells[moving] else { continue }
            let dx = max(CGFloat(cell.column) - point.x, 0, point.x - CGFloat(cell.column + cell.columns))
            let dy = max(CGFloat(cell.row) - point.y, 0, point.y - CGFloat(cell.row + cell.rows))
            let distance = dx * dx + dy * dy
            let moved = cells.filter { $0.key != moving && before[$0.key] != $0.value }.count
            if let current = best,
                distance > current.distance + 0.0001
                    || (abs(distance - current.distance) <= 0.0001 && moved >= current.moved)
            {
                continue
            }
            best = (drop, distance, moved)
        }
        return best?.drop ?? .stay
    }
}
