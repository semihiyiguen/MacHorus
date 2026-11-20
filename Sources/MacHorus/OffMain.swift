// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Blocking system reads (Core Audio, sysctl, files, launchd) run on a
/// background thread: when the daemon behind them hangs, only that thread
/// waits, never the menu bar or the panel.
enum OffMain {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

/// One refresh at a time: a request while one runs is remembered and run
/// once afterwards, so the last state always gets read and reads never pile up.
@MainActor
final class SerialRefresh {
    private var running = false
    private var again = false

    func run(_ body: @escaping @MainActor () async -> Void) {
        guard !running else {
            again = true
            return
        }
        running = true
        Task { @MainActor in
            repeat {
                again = false
                await body()
            } while again
            running = false
        }
    }
}
