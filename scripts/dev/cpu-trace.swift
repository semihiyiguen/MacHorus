// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Exact CPU time of a process over time, to measure what one panel opening
// or one sampling round costs (top's 1-second percentages are too coarse).
// Usage: cpu-trace <pid> <seconds> [step-ms]
// Prints one line per step: elapsed seconds, CPU ms in this step, total CPU ms.

import Darwin
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count >= 2, let pid = pid_t(exactly: arguments[0]) else {
    FileHandle.standardError.write(Data("usage: cpu-trace <pid> <seconds> [step-ms]\n".utf8))
    exit(2)
}
let seconds = arguments[1]
let step = (arguments.count > 2 ? arguments[2] : 100) / 1_000
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func cpuMilliseconds() -> Double? {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    let ticks = Double(usage.ri_user_time + usage.ri_system_time)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

guard let first = cpuMilliseconds() else {
    FileHandle.standardError.write(Data("cannot read pid \(pid)\n".utf8))
    exit(1)
}
let start = Date()
var last = first
while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: step)
    guard let now = cpuMilliseconds() else { break }
    print(String(format: "%.1f %.2f %.2f", Date().timeIntervalSince(start), now - last, now - first))
    fflush(stdout)
    last = now
}
