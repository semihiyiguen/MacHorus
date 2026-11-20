// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import os

/// Unified logging categories. View with:
/// `log stream --predicate 'subsystem == "app.machorus.MacHorus"'`
public enum Log {
    public static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")
    public static let features = Logger(subsystem: AppIdentity.bundleIdentifier, category: "features")
    public static let policy = Logger(subsystem: AppIdentity.bundleIdentifier, category: "policy")
    public static let settings = Logger(subsystem: AppIdentity.bundleIdentifier, category: "settings")
    public static let monitor = Logger(subsystem: AppIdentity.bundleIdentifier, category: "monitor")

    /// Intervals for Instruments-free timing via `log` and `sample` (e.g. feature start/stop).
    public static let signposter = OSSignposter(logger: features)
}
