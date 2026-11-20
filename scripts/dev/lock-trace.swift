// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Proves that MacHorus stops sampling while the screen is locked: run it,
// lock the screen (Ctrl-Cmd-Q) for half a minute, unlock.
// Per second: elapsed seconds, CPU ms of <pid> in that second, screen locked (0/1).
// Also prints every lock/sleep/session event the system sends, as
// "EVENT <t> <name>", and stops 45 s after an unlock (or after <seconds>).
// Usage: lock-trace <pid> <seconds>

import AppKit
import CoreGraphics
import Darwin
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count == 2, let pid = pid_t(exactly: arguments[0]) else { exit(2) }
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let start = Date()
var stopAt = start.addingTimeInterval(arguments[1])

func elapsed() -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }

func cpuMilliseconds() -> Double? {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    return Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func isLocked() -> Int {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return -1 }
    return (session["CGSSessionScreenIsLocked"] as? Bool ?? false) ? 1 : 0
}

func event(_ name: String) {
    print("EVENT \(elapsed()) \(name)")
    fflush(stdout)
    if name.hasSuffix("Unlocked") || name.hasSuffix("DidWake") || name.hasSuffix("DidBecomeActive") {
        stopAt = min(stopAt, Date().addingTimeInterval(45))
    }
}

for name in [
    "com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart",
    "com.apple.screensaver.didstop",
] {
    DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(name), object: nil, queue: .main
    ) { _ in event(name) }
}
let workspace = NSWorkspace.shared.notificationCenter
for name in [
    NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
    NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
    NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
] {
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in event(name.rawValue) }
}

guard var last = cpuMilliseconds() else { exit(1) }
let timer = Timer(timeInterval: 1, repeats: true) { _ in
    guard Date() < stopAt, let now = cpuMilliseconds() else { exit(0) }
    print("\(elapsed()) \(String(format: "%.2f", now - last)) \(isLocked())")
    fflush(stdout)
    last = now
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
