// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// Combines the user's settings with the administrator policy and keeps the
/// running features in sync with the result.
@MainActor
public final class FeatureController {
    public let registry: FeatureRegistry
    private let settings: SettingsStore
    private let policy: FeaturePolicy

    public init(registry: FeatureRegistry, settings: SettingsStore, policy: FeaturePolicy) {
        self.registry = registry
        self.settings = settings
        self.policy = policy
    }

    public var effectiveFeatures: Set<FeatureID> {
        policy.effective(userEnabled: settings.enabledFeatures)
    }

    public func isEnabled(_ id: FeatureID) -> Bool { effectiveFeatures.contains(id) }

    /// True when policy decides about the feature and the user cannot change it.
    public func isLocked(_ id: FeatureID) -> Bool { policy.isLocked(id) }

    /// Returns false (and changes nothing) when policy locks the feature.
    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: FeatureID) -> Bool {
        guard !isLocked(id) else { return false }
        var features = settings.enabledFeatures
        if enabled { features.insert(id) } else { features.remove(id) }
        settings.enabledFeatures = features
        apply()
        return true
    }

    /// Which running features need which permission (for the permissions page).
    public var permissionUsage: [Permission: [FeatureID]] {
        registry.permissionUsage(for: effectiveFeatures)
    }

    public func apply() {
        registry.apply(enabled: effectiveFeatures)
    }
}
