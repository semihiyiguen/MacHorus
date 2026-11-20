// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// The user's arrangement of the expanded monitor: card order and hidden
/// cards. Two cards per row, so both cards of a row share top and bottom.
public struct MonitorArrangement: Equatable, Sendable {
    /// Pairs of similar height: CPU/memory, network/disk, graphics/battery,
    /// temperatures/processes (the two lists).
    public static let defaultOrder: [Metric] = [.cpu, .memory, .network, .disk, .gpu, .power, .thermal, .processes]
    /// The compact panel: temperatures as tiles first, one row per value,
    /// the process list last (its layout before arranging existed).
    public static let compactOrder: [Metric] = [.thermal, .cpu, .gpu, .memory, .network, .disk, .power, .processes]

    /// Metrics shown as one line each in the compact panel; the others
    /// (temperatures, processes) are blocks of their own.
    public static let lineMetrics: Set<Metric> = [.cpu, .gpu, .memory, .network, .disk, .power]

    public private(set) var order: [Metric]
    public private(set) var hidden: Set<Metric>

    public init(order: [Metric] = defaultOrder, hidden: Set<Metric> = [], defaults: [Metric] = defaultOrder) {
        // Unknown or repeated entries are dropped; cards added in a later
        // version are appended in their default place order.
        var seen = Set<Metric>()
        var sanitized = order.filter { seen.insert($0).inserted }
        sanitized += defaults.filter { !seen.contains($0) }
        self.order = sanitized
        self.hidden = hidden
    }

    /// From the stored form (raw names); anything unreadable means default.
    public init(stored: [String: Any]?, defaults: [Metric] = defaultOrder) {
        let order = (stored?["order"] as? [String])?.compactMap(Metric.init(rawValue:)) ?? defaults
        let hidden = (stored?["hidden"] as? [String])?.compactMap(Metric.init(rawValue:)) ?? []
        self.init(order: order, hidden: Set(hidden), defaults: defaults)
    }

    /// Blocks of the compact panel in order: consecutive line metrics form
    /// one card, temperatures and processes stand alone.
    public static func compactBlocks(_ shown: [Metric]) -> [[Metric]] {
        var blocks: [[Metric]] = []
        for metric in shown {
            if lineMetrics.contains(metric), let last = blocks.last, let first = last.first,
                lineMetrics.contains(first)
            {
                blocks[blocks.count - 1].append(metric)
            } else {
                blocks.append([metric])
            }
        }
        return blocks
    }

    /// Until 1.0.17 every metric had its own switch. Those the user had
    /// switched off start hidden in both layouts; nil when none was on (the
    /// monitor was off as a whole: nothing to carry over).
    public static func hiddenFromOldSwitches(enabledFeatures: Set<String>) -> Set<Metric>? {
        let on = Set(Metric.allCases.filter { enabledFeatures.contains("monitor." + $0.rawValue) })
        guard !on.isEmpty else { return nil }
        return Set(Metric.allCases).subtracting(on)
    }

    public var stored: [String: Any] {
        ["order": order.map(\.rawValue), "hidden": hidden.map(\.rawValue).sorted()]
    }

    /// Moves a card one place earlier (-1) or later (+1) among the cards
    /// that are shown; hidden cards keep their place.
    public mutating func move(_ metric: Metric, by offset: Int, among shown: [Metric]) {
        guard let index = shown.firstIndex(of: metric), shown.indices.contains(index + offset) else { return }
        let other = shown[index + offset]
        guard let from = order.firstIndex(of: metric), let to = order.firstIndex(of: other) else { return }
        order.swapAt(from, to)
    }

    /// Drag and drop: shows `metric` and puts it right before `target`, or
    /// after the last shown card when `target` is nil (dropped on the end).
    public mutating func place(_ metric: Metric, before target: Metric?, enabled: Set<Metric>) {
        hidden.remove(metric)
        guard metric != target else { return }
        order.removeAll { $0 == metric }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(metric, at: index)
        } else if let last = shown(enabled: enabled).last, let index = order.firstIndex(of: last) {
            order.insert(metric, at: index + 1)
        } else {
            order.insert(metric, at: 0)
        }
    }

    public mutating func setHidden(_ metric: Metric, _ isHidden: Bool) {
        if isHidden { hidden.insert(metric) } else { hidden.remove(metric) }
    }

    /// The cards to show, in order: switched on and not hidden.
    public func shown(enabled: Set<Metric>) -> [Metric] {
        order.filter { enabled.contains($0) && !hidden.contains($0) }
    }

    /// Rows of two; an odd last card stands alone in the left column.
    public static func rows(_ cards: [Metric]) -> [[Metric]] {
        stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
    }
}
