// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusMonitor
import Observation

/// Info points the user hid (worn battery, pending updates), kept across
/// launches until they change (`StatusItem.dismissKey`).
@MainActor
@Observable
final class StatusDismissals {
    static let key = "statusDismissed"
    /// Enough for every info kind with some history; older keys go first.
    private static let capacity = 20

    private(set) var keys: [String] = UserDefaults.standard.stringArray(forKey: StatusDismissals.key) ?? []

    var set: Set<String> { Set(keys) }

    func dismiss(_ item: StatusItem) {
        guard let key = item.dismissKey, !keys.contains(key) else { return }
        keys = Array((keys + [key]).suffix(Self.capacity))
        UserDefaults.standard.set(keys, forKey: Self.key)
    }
}
