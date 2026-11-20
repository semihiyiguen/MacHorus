// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Testing

@testable import MacHorusMonitor

@Suite struct MonitorArrangementTests {
    @Test func defaultPairsCardsOfSimilarHeight() {
        let rows = MonitorArrangement.rows(MonitorArrangement().shown(enabled: Set(Metric.allCases)))
        #expect(rows == [[.cpu, .memory], [.network, .disk], [.gpu, .power], [.thermal, .processes]])
    }

    @Test func storedFormSurvivesAndIsRepaired() {
        var arrangement = MonitorArrangement()
        arrangement.setHidden(.gpu, true)
        let copy = MonitorArrangement(stored: arrangement.stored)
        #expect(copy == arrangement)
        // Unknown names and repeats are dropped, missing cards appended.
        let repaired = MonitorArrangement(stored: ["order": ["power", "fans", "power", "cpu"], "hidden": ["x"]])
        #expect(repaired.order.prefix(2) == [.power, .cpu])
        #expect(Set(repaired.order) == Set(Metric.allCases))
        #expect(repaired.order.count == Metric.allCases.count)
        #expect(repaired.hidden.isEmpty)
        #expect(MonitorArrangement(stored: nil) == MonitorArrangement())
    }

    @Test func movingSkipsHiddenAndSwitchedOffCards() {
        var arrangement = MonitorArrangement()
        arrangement.setHidden(.network, true)
        let enabled = Set(Metric.allCases).subtracting([.disk])
        var shown = arrangement.shown(enabled: enabled)
        #expect(shown.prefix(3) == [.cpu, .memory, .gpu])
        // GPU one place earlier jumps over hidden network and switched-off disk.
        arrangement.move(.gpu, by: -1, among: shown)
        shown = arrangement.shown(enabled: enabled)
        #expect(shown.prefix(3) == [.cpu, .gpu, .memory])
        // At the edges nothing happens.
        arrangement.move(.cpu, by: -1, among: shown)
        #expect(arrangement.shown(enabled: enabled).first == .cpu)
    }

    @Test func oddCountLeavesTheLastCardAlone() {
        #expect(MonitorArrangement.rows([.cpu, .memory, .disk]) == [[.cpu, .memory], [.disk]])
        #expect(MonitorArrangement.rows([]).isEmpty)
    }

    @Test func compactBlocksGroupTheLinesBetweenTilesAndLists() {
        #expect(
            MonitorArrangement.compactBlocks(MonitorArrangement.compactOrder) == [
                [.thermal], [.cpu, .gpu, .memory, .network, .disk, .power], [.processes],
            ])
        #expect(MonitorArrangement.compactBlocks([.cpu, .processes, .memory]) == [[.cpu], [.processes], [.memory]])
        let compact = MonitorArrangement(stored: nil, defaults: MonitorArrangement.compactOrder)
        #expect(compact.order == MonitorArrangement.compactOrder)
    }

    @Test func oldSwitchesBecomeHiddenCards() {
        #expect(
            MonitorArrangement.hiddenFromOldSwitches(enabledFeatures: [
                "monitor.cpu", "monitor.memory", "monitor.disk", "monitor.network", "monitor.power", "monitor.thermal",
                "monitor.processes", "audio.mixer",
            ]) == [.gpu])
        #expect(MonitorArrangement.hiddenFromOldSwitches(enabledFeatures: ["audio.mixer"]) == nil)
    }

    @Test func dropPlacesACardBeforeAnotherOrAtTheEnd() {
        let all = Set(Metric.allCases)
        var arrangement = MonitorArrangement(order: [.cpu, .memory, .network, .disk], hidden: [.gpu])
        arrangement.place(.disk, before: .cpu, enabled: all)
        #expect(arrangement.shown(enabled: [.cpu, .memory, .network, .disk]) == [.disk, .cpu, .memory, .network])
        // A hidden card dropped on the end comes back after the last shown one.
        arrangement.place(.gpu, before: nil, enabled: [.cpu, .memory, .network, .disk, .gpu])
        #expect(!arrangement.hidden.contains(.gpu))
        #expect(arrangement.shown(enabled: [.cpu, .memory, .network, .disk, .gpu]).last == .gpu)
        // Dropping a card on itself changes nothing.
        let before = arrangement
        arrangement.place(.cpu, before: .cpu, enabled: all)
        #expect(arrangement == before)
    }
}
