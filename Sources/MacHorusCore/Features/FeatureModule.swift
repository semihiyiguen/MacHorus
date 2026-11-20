// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// Stable identifier of a feature, e.g. `monitor.cpu`. Used in settings and
/// policy files, so existing identifiers must never be renamed.
public struct FeatureID: RawRepresentable, Hashable, Comparable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static func < (lhs: FeatureID, rhs: FeatureID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// macOS privacy permissions (TCC) a feature may need.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case camera
    case microphone
    /// "System Audio Recording Only": process taps for per-app volume.
    case systemAudio
    case calendars
    case fullDiskAccess
    case notifications
    case automation
    case bluetooth
}

/// How MacHorus deals with a permission (docs/PRIVACY.md).
public enum PermissionUsage: Sendable {
    /// Never requested by MacHorus.
    case never
    /// Requested only when the user enables a feature that needs it.
    case perFeature
}

extension Permission {
    public var usage: PermissionUsage {
        switch self {
        case .fullDiskAccess, .screenRecording, .bluetooth: .never
        default: .perFeature
        }
    }

    /// Reading the state of these already lists MacHorus in System Settings,
    /// so they are only checked while an active feature needs them.
    public var checkRegistersApp: Bool {
        self == .accessibility || self == .screenRecording
    }
}

/// Groups features in the panel; the order of the cases is the display order.
public enum FeatureCategory: String, CaseIterable, Sendable {
    // Most used first: sound and microphones, the menu bar, the monitor.
    case audio
    /// What MacHorus shows in the menu bar: values next to the eye and
    /// alerts. It samples on its own, independent of the monitor's switches.
    case menuBar
    case monitor
    /// Software updates and the network check.
    case support
    case display
    case windows
    case input
    case clipboard
    case tools
    case island
}

public struct FeatureDescriptor: Hashable, Sendable {
    public let id: FeatureID
    public let category: FeatureCategory
    public let permissions: Set<Permission>

    public init(id: FeatureID, category: FeatureCategory, permissions: Set<Permission> = []) {
        self.id = id
        self.category = category
        self.permissions = permissions
    }
}

/// A feature is created when it gets enabled and released when it gets
/// disabled, so a disabled feature costs no memory and no CPU.
@MainActor
public protocol FeatureModule: AnyObject {
    func start()
    func stop()
}
