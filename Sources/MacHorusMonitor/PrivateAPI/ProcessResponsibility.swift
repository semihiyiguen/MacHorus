// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin

/// Which process is responsible for another one, e.g. a browser for its
/// renderer helpers. macOS uses the same answer to attribute energy and
/// privacy prompts. The idea to use it for grouping comes from Vorssaint's
/// ResponsibleProcess (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint).
///
/// Private interface: `responsibility_get_pid_responsible_for_pid` in
/// libsystem has no public header. Without it (missing symbol or policy
/// `DisabledPrivateAPIs` = `ProcessResponsibility`) every process is its own
/// row.
public struct ProcessResponsibility: Sendable {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    private let function: Function

    public init?() {
        // RTLD_DEFAULT: search every image already loaded.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        function = unsafeBitCast(symbol, to: Function.self)
    }

    public func owner(of pid: pid_t) -> pid_t? {
        let owner = function(pid)
        return owner > 0 ? owner : nil
    }
}
