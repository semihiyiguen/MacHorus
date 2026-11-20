// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Private Apple interfaces MacHorus may use. Each one has a kill switch:
/// listing it under `DisabledPrivateAPIs` in the policy turns it off.
public enum PrivateAPI: String, CaseIterable, Sendable {
    /// NetworkStatistics.framework: per-connection byte counts, like
    /// Activity Monitor. Used only for total download/upload bytes.
    case networkStatistics = "NetworkStatistics"
    /// HID event system: temperature sensors of the chip (read-only).
    case hidSensors = "HIDSensors"
    /// System Management Controller: fan speeds (read-only, never written).
    case smc = "SMC"
    /// libsystem: which app a helper process belongs to, for grouping.
    case processResponsibility = "ProcessResponsibility"
}

/// Administrator rules that override the user's choice of features.
/// Documented for administrators in docs/ADMINISTRATION.md.
public struct FeaturePolicy: Equatable, Sendable {
    enum Key {
        static let forcedEnabled = "ForcedEnabledFeatures"
        static let disabled = "DisabledFeatures"
        static let disabledPrivateAPIs = "DisabledPrivateAPIs"
    }

    /// Always on; the user cannot switch them off.
    public var forcedEnabled: Set<FeatureID>
    /// Always off; wins over `forcedEnabled` and over the user's choice.
    public var disabled: Set<FeatureID>
    /// Private interfaces the administrator has switched off.
    public var disabledPrivateAPIs: Set<PrivateAPI>

    public static let none = FeaturePolicy(forcedEnabled: [], disabled: [])

    public init(
        forcedEnabled: Set<FeatureID>, disabled: Set<FeatureID>, disabledPrivateAPIs: Set<PrivateAPI> = []
    ) {
        self.forcedEnabled = forcedEnabled
        self.disabled = disabled
        self.disabledPrivateAPIs = disabledPrivateAPIs
    }

    /// Reads the policy keys from a property list dictionary. Values of the
    /// wrong type are ignored instead of failing the whole policy.
    public init(dictionary: [String: Any]) {
        func strings(_ key: String) -> [String] {
            (dictionary[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        self.init(
            forcedEnabled: Set(strings(Key.forcedEnabled).map(FeatureID.init(rawValue:))),
            disabled: Set(strings(Key.disabled).map(FeatureID.init(rawValue:))),
            disabledPrivateAPIs: Set(strings(Key.disabledPrivateAPIs).compactMap(PrivateAPI.init(rawValue:)))
        )
    }

    public func merged(with other: FeaturePolicy) -> FeaturePolicy {
        FeaturePolicy(
            forcedEnabled: forcedEnabled.union(other.forcedEnabled),
            disabled: disabled.union(other.disabled),
            disabledPrivateAPIs: disabledPrivateAPIs.union(other.disabledPrivateAPIs)
        )
    }

    public func effective(userEnabled: Set<FeatureID>) -> Set<FeatureID> {
        userEnabled.union(forcedEnabled).subtracting(disabled)
    }

    public func isLocked(_ id: FeatureID) -> Bool {
        forcedEnabled.contains(id) || disabled.contains(id)
    }

    public func allows(_ api: PrivateAPI) -> Bool {
        !disabledPrivateAPIs.contains(api)
    }
}
