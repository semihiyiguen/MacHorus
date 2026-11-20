// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import Darwin
import MacHorusMonitor
import SwiftUI

/// `-debug.interactionBench all|<scenario,…>` (with `-debug.showPanel <tab>`)
/// measures what each panel interaction costs in the real popover, prints one
/// line per step and quits. A step changes the same state its click changes.
///
/// Each step starts 200 ms after a sampling round (or after 2.5 s without
/// one) and is measured for 1.2 s, so no regular round falls into the
/// window; a round the step itself causes (a tab that shows other values)
/// counts, because the click causes it too. Every scenario also measures the
/// same window without an action, which is subtracted.
@MainActor
final class InteractionBenchmark {
    private struct Step {
        let name: String
        let run: @MainActor () async -> Void
    }

    private struct Scenario {
        let name: String
        let tab: PanelTab
        let expanded: Bool
        let steps: [Step]
    }

    private static let expandedKey = "panelExpanded"
    private let model: PanelModel
    private let panelView: () -> NSView?
    private var lastRound = Date.distantPast
    /// The user's stored choice, restored at the end (not the launch argument).
    private let storedExpanded = UserDefaults.standard.persistentDomain(
        forName: Bundle.main.bundleIdentifier ?? "")?[InteractionBenchmark.expandedKey]

    init(model: PanelModel, panelView: @escaping () -> NSView?) {
        self.model = model
        self.panelView = panelView
        model.monitor.addRoundHandler(owner: self) { [weak self] _ in self?.lastRound = Date() }
    }

    func run(_ selection: String, repetitions: Int = 5) async {
        try? await Task.sleep(for: .seconds(6))  // first rounds and the opening settle
        let wanted = Set(selection.split(separator: ",").map(String.init))
        for scenario in scenarios() where wanted.contains("all") || wanted.contains(scenario.name) {
            await prepare(scenario)
            let idle = Step(name: "idle") {}
            var costs: [String: [Double]] = [:]
            var mainCosts: [String: [Double]] = [:]
            for _ in 0..<repetitions {
                for step in [idle] + scenario.steps {
                    let (total, main) = await measure(step)
                    costs[step.name, default: []].append(total)
                    mainCosts[step.name, default: []].append(main)
                }
            }
            report(scenario, costs: costs, mainCosts: mainCosts)
        }
        if let storedExpanded {
            UserDefaults.standard.set(storedExpanded, forKey: Self.expandedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.expandedKey)
        }
        NSApp.terminate(nil)
    }

    // MARK: Scenarios

    private func scenarios() -> [Scenario] {
        let navigation = model.navigation
        let monitor = model.monitor
        func tab(_ tab: PanelTab) -> Step {
            // What the tab bar's buttons do (they animate only their highlight).
            Step(name: "tab → \(tab.rawValue)") { navigation.tab = tab }
        }
        func expand(_ on: Bool) -> Step {
            Step(name: on ? "expand" : "collapse") { navigation.isExpanded = on }
        }
        func section(_ section: SettingsSection) -> Step {
            Step(name: "section → \(section.rawValue)") { navigation.settingsSection = section }
        }
        let sort = [
            Step(name: "sort → memory") { monitor.processSort = .memory },
            Step(name: "sort → cpu") { monitor.processSort = .cpu },
        ]
        let search = [
            Step(name: "search open") {
                PanelFocus.makeKey()
                monitor.processSearchActive = true
            },
            Step(name: "type 1st letter") { monitor.processQuery = "s" },
            Step(name: "type 2nd letter") { monitor.processQuery = "sa" },
            Step(name: "clear and close") {
                monitor.processQuery = ""
                monitor.processSearchActive = false
            },
        ]
        let reasons = [
            Step(name: "restart reasons open") { monitor.showsRestartReasons = true },
            Step(name: "restart reasons close") { monitor.showsRestartReasons = false },
        ]
        let scroll = [
            Step(name: "scroll down 360 pt") { await self.scroll(by: 30, steps: 12) },
            Step(name: "scroll up 360 pt") { await self.scroll(by: -30, steps: 12) },
        ]
        var list = [
            Scenario(name: "expand", tab: .monitor, expanded: false, steps: [expand(true), expand(false)]),
            Scenario(name: "expandOverview", tab: .overview, expanded: false, steps: [expand(true), expand(false)]),
        ]
        for expanded in [false, true] {
            let suffix = expanded ? "+" : ""
            list += [
                Scenario(
                    name: "tabs" + suffix, tab: .overview, expanded: expanded,
                    steps: [tab(.monitor), tab(.tools), tab(.settings), tab(.overview)]),
                Scenario(
                    name: "sections" + suffix, tab: .settings, expanded: expanded,
                    steps: [section(.privacy), section(.about), section(.features)]),
                Scenario(name: "sort" + suffix, tab: .monitor, expanded: expanded, steps: sort),
                Scenario(name: "search" + suffix, tab: .monitor, expanded: expanded, steps: search),
                Scenario(name: "reasons" + suffix, tab: .monitor, expanded: expanded, steps: reasons),
                Scenario(name: "scrollMonitor" + suffix, tab: .monitor, expanded: expanded, steps: scroll),
                Scenario(name: "scrollSettings" + suffix, tab: .settings, expanded: expanded, steps: scroll),
            ]
        }
        return list
    }

    private func prepare(_ scenario: Scenario) async {
        let navigation = model.navigation
        navigation.isExpanded = scenario.expanded
        navigation.tab = scenario.tab
        navigation.settingsSection = .features
        model.monitor.processSearchActive = false
        model.monitor.processQuery = ""
        model.monitor.showsRestartReasons = false
        try? await Task.sleep(for: .seconds(3))
        if let root = panelView(), let scrollView = Self.scrollView(in: root) {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: Measuring

    /// Process CPU and main-thread CPU of one step, in ms.
    private func measure(_ step: Step) async -> (Double, Double) {
        let start = Date()
        let seen = lastRound
        while lastRound == seen, Date().timeIntervalSince(start) < 2.5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let before = Self.cpuMilliseconds()
        let mainBefore = Self.mainThreadMilliseconds()
        await step.run()
        try? await Task.sleep(for: .milliseconds(1_200))
        return (Self.cpuMilliseconds() - before, Self.mainThreadMilliseconds() - mainBefore)
    }

    /// CPU time of the main thread (this runs on the main actor).
    private static func mainThreadMilliseconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func milliseconds(_ time: time_value_t) -> Double {
            Double(time.seconds) * 1_000 + Double(time.microseconds) / 1_000
        }
        return milliseconds(info.user_time) + milliseconds(info.system_time)
    }

    /// Scrolls the panel's page like a short flick: `steps` moves of `by`
    /// points, one per display frame.
    private func scroll(by delta: CGFloat, steps: Int) async {
        guard let root = panelView(), let scrollView = Self.scrollView(in: root) else {
            print("bench: no scroll view found")
            return
        }
        let clip = scrollView.contentView
        for _ in 0..<steps {
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y = min(max(0, clip.bounds.origin.y + delta), maxY)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1_000 + Double(time.tv_usec) / 1_000 }
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }

    private func report(_ scenario: Scenario, costs: [String: [Double]], mainCosts: [String: [Double]]) {
        let idle = Self.median(costs["idle"] ?? [])
        let mainIdle = Self.median(mainCosts["idle"] ?? [])
        let mode = scenario.expanded ? "expanded" : "compact"
        print(String(format: "bench [%@, %@] idle window %.1f ms", scenario.name, mode, idle))
        for step in scenario.steps {
            let values = (costs[step.name] ?? []).map { $0 - idle }.sorted()
            guard let low = values.first, let high = values.last else { continue }
            let main = Self.median((mainCosts[step.name] ?? []).map { $0 - mainIdle })
            print(
                String(
                    format: "bench   %-24@ median %6.1f ms   min %6.1f   max %6.1f   main thread %6.1f",
                    step.name as NSString, Self.median(values), low, high, main))
        }
        fflush(stdout)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
