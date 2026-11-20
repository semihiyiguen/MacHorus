// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// What macOS reports for one privacy permission.
public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// No global state exists (e.g. Automation is granted per target app).
    case notApplicable
    /// Deliberately not read, because no active feature needs it.
    case notChecked
}

/// One line of the permissions page: state plus the active features that need it.
public struct PermissionRow: Identifiable, Equatable, Sendable {
    public let permission: Permission
    public let state: PermissionState
    public let usedBy: [FeatureID]

    public var id: Permission { permission }

    /// An active feature needs the permission, but it is not granted.
    public var isMissing: Bool {
        !usedBy.isEmpty && (state == .denied || state == .notDetermined)
    }

    /// Granted, but no active feature needs it any more: the user may revoke it.
    public var isUnneeded: Bool {
        usedBy.isEmpty && state == .granted
    }
}

public enum PermissionOverview {
    public static func rows(
        states: [Permission: PermissionState],
        usage: [Permission: [FeatureID]]
    ) -> [PermissionRow] {
        Permission.allCases.map { permission in
            PermissionRow(
                permission: permission,
                state: states[permission] ?? .notChecked,
                usedBy: (usage[permission] ?? []).sorted()
            )
        }
    }
}
