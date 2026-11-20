// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Typed access to the user's settings with a schema version, so that later
/// format changes run through one ordered migration chain instead of ad-hoc
/// fixes on every launch.
@MainActor
public final class SettingsStore {
    public static let currentSchemaVersion = 12

    /// Switched on for new users and once for existing ones (schemas 2 to
    /// 5): features that need no permission and cost nothing while hidden.
    public static let initialFeatures: Set<FeatureID> =
        schemaTwoFeatures.union(schemaThreeFeatures).union(schemaFourFeatures).union(schemaFiveFeatures)
        .union(schemaSixFeatures).union(schemaSevenFeatures).union(schemaEightFeatures).union(schemaNineFeatures)
        .union(schemaTenFeatures).union(schemaElevenFeatures).union(schemaTwelveFeatures)
    static let schemaTwoFeatures: Set<FeatureID> = ["monitor.cpu", "monitor.memory"]
    static let schemaThreeFeatures: Set<FeatureID> = ["monitor.disk", "monitor.network", "monitor.power"]
    static let schemaFourFeatures: Set<FeatureID> = ["monitor.thermal", "monitor.gpu"]
    static let schemaFiveFeatures: Set<FeatureID> = ["monitor.processes"]
    /// Version 1.0: the tools that need no permission and cost nothing while idle.
    static let schemaSixFeatures: Set<FeatureID> = ["display.keepAwake", "audio.micMute", "support.updates"]
    /// Version 1.0.3: the maintainer's everyday set becomes the default. Sound
    /// per app asks for its permission only at the first adjustment; menu bar
    /// values and alerts cost about 0.37 % CPU with the panel closed.
    static let schemaSevenFeatures: Set<FeatureID> = [
        "audio.mixer", "monitor.menubar", "monitor.alerts",
    ]
    /// 1.0.6: switching the sound output and input, the clipboard history
    /// (memory only). Presentation mode stays off: rarely needed.
    static let schemaEightFeatures: Set<FeatureID> = ["audio.devices", "clipboard.history"]
    /// 1.0.16: the network check (connects only when clicked).
    static let schemaNineFeatures: Set<FeatureID> = ["support.networkCheck"]
    /// 1.0.17: drives, connected hardware and printers (read only while shown).
    static let schemaTenFeatures: Set<FeatureID> = ["tools.drives", "tools.hardware", "tools.printers"]
    /// 1.0.18: one switch for the whole monitor; which cards show is set on
    /// the monitor page. The old per-metric switches stay in the stored set
    /// (no longer registered) so the layout can carry the user's choice over.
    static let schemaElevenFeatures: Set<FeatureID> = ["monitor.system"]
    /// 1.0.23: the tools have no switches any more (each is a widget, added
    /// with "+ Widget"); they read only while shown, so all are on, ports too.
    static let schemaTwelveFeatures: Set<FeatureID> = [
        "tools.drives", "tools.hardware", "tools.printers", "tools.ports",
    ]
    static let oldMonitorFeatures: Set<FeatureID> = [
        "monitor.cpu", "monitor.memory", "monitor.disk", "monitor.network", "monitor.power", "monitor.thermal",
        "monitor.gpu", "monitor.processes",
    ]

    public enum Key {
        public static let schemaVersion = "settings.schemaVersion"
        public static let enabledFeatures = "features.enabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    public var schemaVersion: Int { defaults.integer(forKey: Key.schemaVersion) }

    /// Features the user switched on. Policy may still force or block them.
    public var enabledFeatures: Set<FeatureID> {
        get { Set((defaults.stringArray(forKey: Key.enabledFeatures) ?? []).map(FeatureID.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.enabledFeatures) }
    }

    private func migrateIfNeeded() {
        let stored = defaults.integer(forKey: Key.schemaVersion)
        guard stored < Self.currentSchemaVersion else {
            if stored > Self.currentSchemaVersion {
                // Written by a newer build: leave it untouched rather than guess.
                Log.settings.error("Settings schema \(stored) is newer than supported \(Self.currentSchemaVersion)")
            }
            return
        }
        // Migrations, oldest first.
        if stored < 2 {
            enabledFeatures.formUnion(Self.schemaTwoFeatures)
        }
        if stored < 3 {
            enabledFeatures.formUnion(Self.schemaThreeFeatures)
        }
        if stored < 4 {
            enabledFeatures.formUnion(Self.schemaFourFeatures)
        }
        if stored < 5 {
            enabledFeatures.formUnion(Self.schemaFiveFeatures)
        }
        if stored < 6 {
            enabledFeatures.formUnion(Self.schemaSixFeatures)
        }
        if stored < 7 {
            enabledFeatures.formUnion(Self.schemaSevenFeatures)
        }
        if stored < 8 {
            enabledFeatures.formUnion(Self.schemaEightFeatures)
        }
        if stored < 9 {
            enabledFeatures.formUnion(Self.schemaNineFeatures)
        }
        if stored < 10 {
            enabledFeatures.formUnion(Self.schemaTenFeatures)
        }
        // The monitor stays on if any of its values was on.
        if stored < 11, !enabledFeatures.isDisjoint(with: Self.oldMonitorFeatures) {
            enabledFeatures.formUnion(Self.schemaElevenFeatures)
        }
        if stored < 12 {
            enabledFeatures.formUnion(Self.schemaTwelveFeatures)
        }
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
        Log.settings.notice("Settings schema migrated from \(stored) to \(Self.currentSchemaVersion)")
    }
}
