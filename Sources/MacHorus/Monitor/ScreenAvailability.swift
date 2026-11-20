// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore

/// Whether anybody can see the screen: asleep, locked or another user
/// active means no. Background work (menu bar values, alerts) pauses then
/// (docs/ARCHITECTURE.md).
@MainActor
final class ScreenAvailability {
    /// Read at launch: MacHorus may start while the screen is locked (an
    /// update installed at night, a login item before unlocking).
    private(set) var isAvailable = ScreenAvailability.currentlyAvailable()
    private var handlers: [(Bool) -> Void] = []
    private var observers: [NSObjectProtocol] = []
    /// While paused, the real state is read again every 10 s: a missed
    /// unlock or wake notification must not pause the work for good (the
    /// clipboard history then recorded nothing until something else changed).
    private var recheck: Timer?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Delivered on the main queue (queue: .main below).
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.set(true) }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: pause))
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: resume))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause)
        )
        observers.append(
            distributed.addObserver(
                forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume))
        // `-debug.screenUnavailableAfter <s>` acts as if the screen locked,
        // to measure that background work stops.
        updateRecheck()
        let delay = UserDefaults.standard.double(forKey: "debug.screenUnavailableAfter")
        if delay > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.set(false)
            }
        }
    }

    static func currentlyAvailable() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        // Another user's session is in front (fast user switching).
        if session[kCGSessionOnConsoleKey as String] as? Bool == false { return false }
        return true
    }

    func onChange(_ handler: @escaping (Bool) -> Void) {
        handlers.append(handler)
    }

    private func updateRecheck() {
        if isAvailable {
            recheck?.invalidate()
            recheck = nil
        } else if recheck == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if Self.currentlyAvailable() { self?.set(true) }
                }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            recheck = timer
        }
    }

    private func set(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        updateRecheck()
        Log.monitor.notice(
            "Background work \(available ? "resumes" : "pauses", privacy: .public): screen \(available ? "available" : "asleep or locked", privacy: .public)"
        )
        for handler in handlers { handler(available) }
    }
}
