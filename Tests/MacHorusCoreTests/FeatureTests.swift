// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusCore

@MainActor
private final class FakeModule: FeatureModule {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
private final class Harness {
    let registry = FeatureRegistry()
    private(set) var created: [FeatureID: [FakeModule]] = [:]
    /// Weak references prove that disabled features are released.
    private(set) var weakInstances: [FeatureID: [WeakBox]] = [:]

    init(_ ids: [FeatureID], permissions: [FeatureID: Set<Permission>] = [:]) {
        for id in ids {
            registry.register(FeatureDescriptor(id: id, category: .tools, permissions: permissions[id] ?? [])) {
                [unowned self] in
                let module = FakeModule()
                self.weakInstances[id, default: []].append(WeakBox(module))
                return module
            }
        }
    }

    func liveInstances(_ id: FeatureID) -> Int {
        weakInstances[id, default: []].filter { $0.object != nil }.count
    }
}

private final class WeakBox {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

/// Isolated UserDefaults suite that is deleted again when the test ends.
private final class ScratchDefaults {
    let suite = "machorus.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        // cfprefsd keeps an empty plist behind; remove it as well.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
@Suite struct FeatureRegistryTests {
    @Test func descriptorsKeepTheRegistrationOrder() {
        // The settings list follows this order, not the alphabet.
        let harness = Harness(["monitor.cpu", "monitor.memory", "monitor.gpu", "monitor.disk"])
        #expect(
            harness.registry.descriptors.map(\.id) == ["monitor.cpu", "monitor.memory", "monitor.gpu", "monitor.disk"])
    }

    @Test func startsEnabledAndReleasesDisabledFeatures() {
        let harness = Harness(["a", "b"])
        harness.registry.apply(enabled: ["a", "b"])
        #expect(harness.registry.runningFeatures == ["a", "b"])
        #expect(harness.liveInstances("a") == 1)

        harness.registry.apply(enabled: ["b"])
        #expect(harness.registry.runningFeatures == ["b"])
        #expect(harness.liveInstances("a") == 0, "A disabled feature must not stay in memory")
        #expect(harness.liveInstances("b") == 1)
    }

    @Test func applyIsIdempotent() {
        let harness = Harness(["a"])
        harness.registry.apply(enabled: ["a"])
        harness.registry.apply(enabled: ["a"])
        #expect(harness.weakInstances["a"]?.count == 1, "Re-applying must not create a second instance")
    }

    @Test func callsStartAndStopExactlyOnce() {
        let registry = FeatureRegistry()
        let module = FakeModule()
        registry.register(FeatureDescriptor(id: "a", category: .tools)) { module }
        registry.apply(enabled: ["a"])
        registry.stopAll()
        #expect(module.startCount == 1)
        #expect(module.stopCount == 1)
    }

    @Test func ignoresUnknownFeatures() {
        let harness = Harness(["a"])
        harness.registry.apply(enabled: ["a", "unknown"])
        #expect(harness.registry.runningFeatures == ["a"])
    }

    @Test func unionsPermissionsOfGivenFeatures() {
        let harness = Harness(
            ["a", "b", "c"],
            permissions: [
                "a": [.accessibility],
                "b": [.accessibility, .inputMonitoring],
            ])
        #expect(harness.registry.permissions(for: ["a", "b"]) == [.accessibility, .inputMonitoring])
        #expect(harness.registry.permissions(for: ["c"]).isEmpty)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func schemaTwoSwitchesOnTheInitialFeaturesOnce() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        // A schema 1 user with one feature on keeps it and gets the defaults.
        defaults.set(1, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["windows.layout"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(store.enabledFeatures == SettingsStore.initialFeatures.union(["windows.layout"]))
        // Switching one off afterwards sticks across launches.
        store.enabledFeatures.remove("monitor.cpu")
        #expect(!SettingsStore(defaults: defaults).enabledFeatures.contains("monitor.cpu"))
    }

    @Test func schemaThreeAddsNewMonitorFeaturesButKeepsChoices() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        // A schema 2 user who switched the CPU monitor off.
        defaults.set(2, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.memory"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(
            store.enabledFeatures
                == Set<FeatureID>([
                    "monitor.memory", "monitor.disk", "monitor.network", "monitor.power", "monitor.thermal",
                    "monitor.gpu", "monitor.processes",
                ]).union(SettingsStore.schemaSixFeatures).union(SettingsStore.schemaSevenFeatures)
                .union(SettingsStore.schemaEightFeatures).union(SettingsStore.schemaNineFeatures).union(
                    SettingsStore.schemaTenFeatures
                ).union(SettingsStore.schemaElevenFeatures).union(SettingsStore.schemaTwelveFeatures))
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
    }

    @Test func schemaFourAddsTemperaturesAndGPUButKeepsChoices() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        // A schema 3 user who switched the network monitor off.
        defaults.set(3, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.cpu"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(
            store.enabledFeatures
                == Set<FeatureID>(["monitor.cpu", "monitor.thermal", "monitor.gpu", "monitor.processes"]).union(
                    SettingsStore.schemaSixFeatures
                ).union(SettingsStore.schemaSevenFeatures).union(SettingsStore.schemaEightFeatures).union(
                    SettingsStore.schemaNineFeatures
                ).union(SettingsStore.schemaTenFeatures).union(SettingsStore.schemaElevenFeatures).union(
                    SettingsStore.schemaTwelveFeatures))
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
    }

    @Test func schemaFiveAddsTheProcessList() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(4, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.gpu"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(store.enabledFeatures.isSuperset(of: ["monitor.gpu", "monitor.processes"]))
        #expect(!store.enabledFeatures.contains("monitor.cpu"), "Earlier choices stay")
    }

    @Test func schemaSixAddsTheToolsButKeepsChoices() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(5, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.cpu"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(
            store.enabledFeatures
                == Set<FeatureID>(["monitor.cpu", "display.keepAwake", "audio.micMute", "support.updates"]).union(
                    SettingsStore.schemaSevenFeatures
                ).union(SettingsStore.schemaEightFeatures).union(SettingsStore.schemaNineFeatures).union(
                    SettingsStore.schemaTenFeatures
                ).union(SettingsStore.schemaElevenFeatures).union(SettingsStore.schemaTwelveFeatures))
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
    }

    @Test func schemaSevenMakesTheEverydaySetTheDefault() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(6, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.cpu"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(
            store.enabledFeatures
                == Set<FeatureID>(["monitor.cpu"]).union(SettingsStore.schemaSevenFeatures).union(
                    SettingsStore.schemaEightFeatures
                ).union(SettingsStore.schemaNineFeatures).union(SettingsStore.schemaTenFeatures).union(
                    SettingsStore.schemaElevenFeatures
                ).union(SettingsStore.schemaTwelveFeatures))
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
    }

    @Test func schemaElevenKeepsTheMonitorOffWhenAllItsValuesWereOff() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(10, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["audio.mixer"], forKey: SettingsStore.Key.enabledFeatures)
        #expect(
            SettingsStore(defaults: defaults).enabledFeatures
                == Set<FeatureID>(["audio.mixer"]).union(SettingsStore.schemaTwelveFeatures))
        defaults.set(10, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.gpu"], forKey: SettingsStore.Key.enabledFeatures)
        #expect(
            SettingsStore(defaults: defaults).enabledFeatures
                == Set<FeatureID>(["monitor.gpu", "monitor.system"]).union(SettingsStore.schemaTwelveFeatures))
    }

    /// A Mac with 1.0.9 (schema 8, as installed by Munki) gets the update:
    /// alerts stay on, the monitor becomes the one switch, nothing the user
    /// switched off comes back.
    @Test func anUpdateFromVersion109KeepsAlertsWorking() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(8, forKey: SettingsStore.Key.schemaVersion)
        let old: [String] = [
            "audio.devices", "audio.micMute", "audio.mixer", "clipboard.history", "display.keepAwake", "monitor.alerts",
            "monitor.cpu", "monitor.disk", "monitor.memory", "monitor.menubar", "monitor.network", "monitor.power",
            "monitor.processes", "monitor.thermal", "support.updates",
        ]
        defaults.set(old, forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(store.enabledFeatures.isSuperset(of: ["monitor.alerts", "monitor.menubar", "monitor.system"]))
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
        // Switched off before the update: stays off.
        defaults.set(8, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(old.filter { $0 != "monitor.alerts" }, forKey: SettingsStore.Key.enabledFeatures)
        #expect(!SettingsStore(defaults: defaults).enabledFeatures.contains("monitor.alerts"))
    }

    @Test func schemaEightAddsDevicesAndClipboardButKeepsChoices() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        // A schema 7 user who switched the mixer off.
        defaults.set(7, forKey: SettingsStore.Key.schemaVersion)
        defaults.set(["monitor.cpu", "audio.micMute"], forKey: SettingsStore.Key.enabledFeatures)
        let store = SettingsStore(defaults: defaults)
        #expect(
            store.enabledFeatures == [
                "monitor.cpu", "audio.micMute", "audio.devices", "clipboard.history", "support.networkCheck",
                "tools.drives", "tools.hardware", "tools.printers", "monitor.system", "tools.ports",
            ])
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
        // A fresh install gets every feature in everyday use.
        #expect(
            SettingsStore.initialFeatures == [
                "audio.devices", "audio.micMute", "audio.mixer", "clipboard.history", "display.keepAwake",
                "monitor.alerts", "monitor.cpu", "monitor.disk", "monitor.gpu",
                "monitor.memory", "monitor.menubar", "monitor.network", "monitor.power", "monitor.processes",
                "monitor.thermal", "support.networkCheck", "support.updates", "tools.drives", "tools.hardware",
                "tools.printers", "monitor.system", "tools.ports",
            ])
    }

    @Test func freshStoreWritesCurrentSchemaVersion() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        let store = SettingsStore(defaults: defaults)
        #expect(store.schemaVersion == SettingsStore.currentSchemaVersion)
        #expect(store.enabledFeatures == SettingsStore.initialFeatures)
    }

    @Test func newerSchemaIsLeftUntouched() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        defaults.set(99, forKey: SettingsStore.Key.schemaVersion)
        _ = SettingsStore(defaults: defaults)
        #expect(defaults.integer(forKey: SettingsStore.Key.schemaVersion) == 99)
    }

    @Test func enabledFeaturesRoundTrip() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        let store = SettingsStore(defaults: defaults)
        store.enabledFeatures = ["monitor.cpu", "monitor.memory"]
        #expect(SettingsStore(defaults: defaults).enabledFeatures == ["monitor.cpu", "monitor.memory"])
    }
}

@Suite struct FeaturePolicyTests {
    @Test func disabledWinsOverForcedAndUser() {
        let policy = FeaturePolicy(forcedEnabled: ["a", "b"], disabled: ["b", "c"])
        #expect(policy.effective(userEnabled: ["c", "d"]) == ["a", "d"])
    }

    @Test func readsDictionaryAndIgnoresWrongTypes() {
        let policy = FeaturePolicy(dictionary: [
            "ForcedEnabledFeatures": ["a", 42, "b"],
            "DisabledFeatures": "not-an-array",
        ])
        #expect(policy.forcedEnabled == ["a", "b"])
        #expect(policy.disabled.isEmpty)
    }

    @Test func mergesFiles() {
        let merged = FeaturePolicy(forcedEnabled: ["a"], disabled: [])
            .merged(with: FeaturePolicy(forcedEnabled: [], disabled: ["b"], disabledPrivateAPIs: [.networkStatistics]))
        #expect(
            merged == FeaturePolicy(forcedEnabled: ["a"], disabled: ["b"], disabledPrivateAPIs: [.networkStatistics]))
    }

    @Test func privateAPIsAreAllowedUntilSwitchedOff() {
        #expect(FeaturePolicy.none.allows(.networkStatistics))
        let policy = FeaturePolicy(dictionary: ["DisabledPrivateAPIs": ["NetworkStatistics", "Unknown", 7]])
        #expect(policy.disabledPrivateAPIs == [.networkStatistics])
        #expect(!policy.allows(.networkStatistics))
        // The names are part of the documented policy format (docs/ADMINISTRATION.md).
        #expect(
            PrivateAPI.allCases.map(\.rawValue) == ["NetworkStatistics", "HIDSensors", "SMC", "ProcessResponsibility"])
    }
}

@Suite struct PolicyLoaderTests {
    private func writePolicy(_ dictionary: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("machorus-policy-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @Test func loadsAndMergesExistingFilesOnly() throws {
        let first = try writePolicy(["DisabledFeatures": ["a"]])
        let second = try writePolicy(["ForcedEnabledFeatures": ["b"]])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "missing-\(UUID().uuidString).plist")

        let policy = PolicyLoader.load(from: [first, missing, second], requireRootOwnership: false)
        #expect(policy == FeaturePolicy(forcedEnabled: ["b"], disabled: ["a"]))
    }

    @Test func ignoresFilesNotOwnedByRoot() throws {
        let url = try writePolicy(["DisabledFeatures": ["a"]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PolicyLoader.load(from: [url]) == .none)
    }

    @Test func ignoresMalformedFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).plist")
        try Data("not a plist".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PolicyLoader.load(from: [url], requireRootOwnership: false) == .none)
    }
}

@MainActor
@Suite struct FeatureControllerTests {
    @Test func policyLocksFeaturesAgainstUserChanges() {
        let scratch = ScratchDefaults()
        let harness = Harness(["a", "b", "c"])
        let controller = FeatureController(
            registry: harness.registry,
            settings: SettingsStore(defaults: scratch.defaults),
            policy: FeaturePolicy(forcedEnabled: ["a"], disabled: ["b"])
        )
        controller.apply()
        #expect(harness.registry.runningFeatures == ["a"])

        #expect(controller.setEnabled(false, for: "a") == false)
        #expect(controller.setEnabled(true, for: "b") == false)
        #expect(controller.setEnabled(true, for: "c"))
        #expect(harness.registry.runningFeatures == ["a", "c"])
        #expect(controller.isLocked("a") && controller.isLocked("b") && !controller.isLocked("c"))
    }

    @Test func userChoicePersistsAcrossControllers() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        let first = Harness(["a"])
        FeatureController(registry: first.registry, settings: SettingsStore(defaults: defaults), policy: .none)
            .setEnabled(true, for: "a")

        let second = Harness(["a"])
        let controller = FeatureController(
            registry: second.registry, settings: SettingsStore(defaults: defaults), policy: .none)
        controller.apply()
        #expect(second.registry.runningFeatures == ["a"])
    }
}
