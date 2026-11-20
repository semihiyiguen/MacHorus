// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusCore
import Observation

/// Publishes MacHorus' own CPU and memory use while the panel is visible.
/// When nothing shows the value, no timer runs. While the monitor samples,
/// its rounds drive the update instead of a second timer, so the panel
/// redraws once per round, not twice.
@MainActor
@Observable
final class SelfUsageModel {
    private(set) var usage: ResourceUsage?

    @ObservationIgnored private var sampler = SelfUsageSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var followsRounds = false

    func startUpdating() {
        guard !isUpdating else { return }
        isUpdating = true
        refresh()
        if !followsRounds { startTimer() }
    }

    func stopUpdating() {
        isUpdating = false
        timer?.invalidate()
        timer = nil
        // A fresh baseline keeps the next CPU value from averaging over closed time.
        sampler = SelfUsageSampler()
    }

    /// `true` while the monitor's rounds call `roundCompleted()`.
    func followRounds(_ follow: Bool) {
        followsRounds = follow
        timer?.invalidate()
        timer = nil
        if !follow, isUpdating { startTimer() }
    }

    func roundCompleted() {
        if followsRounds, isUpdating { refresh() }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        usage = sampler.sample()
    }
}
