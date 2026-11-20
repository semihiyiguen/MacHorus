// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusCore

@Suite struct SelfUsageSamplerTests {
    @Test func firstSampleHasMemoryButNoCPUShare() throws {
        var sampler = SelfUsageSampler()
        let sample = sampler.sample()
        let usage = try #require(sample)
        #expect(usage.cpuPercent == nil)
        #expect(usage.footprintBytes > 1_000_000, "A running Swift process uses more than 1 MB")
    }

    @Test func secondSampleReportsCPUWork() throws {
        var sampler = SelfUsageSampler()
        let start = ProcessInfo.processInfo.systemUptime
        _ = sampler.sample(now: start)
        // Burn roughly 50 ms of CPU so the delta is measurable.
        var accumulator = 0.0
        while ProcessInfo.processInfo.systemUptime - start < 0.05 { accumulator += sin(accumulator) + 1 }
        #expect(accumulator > 0)
        let sample = sampler.sample()
        let usage = try #require(sample)
        let cpu = try #require(usage.cpuPercent)
        #expect(cpu > 0)
    }

    @Test func ignoresNonAdvancingClock() throws {
        var sampler = SelfUsageSampler()
        _ = sampler.sample(now: 100)
        let sample = sampler.sample(now: 100)
        let usage = try #require(sample)
        #expect(usage.cpuPercent == nil)
    }
}
