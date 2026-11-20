// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Testing

@testable import MacHorusCore

@Suite struct PermissionOverviewTests {
    private func row(_ permission: Permission, in rows: [PermissionRow]) -> PermissionRow? {
        rows.first { $0.permission == permission }
    }

    @Test func listsEveryPermissionOnce() {
        let rows = PermissionOverview.rows(states: [:], usage: [:])
        #expect(rows.map(\.permission) == Permission.allCases)
    }

    @Test func flagsMissingAndUnneededPermissions() throws {
        let rows = PermissionOverview.rows(
            states: [.accessibility: .denied, .screenRecording: .granted, .camera: .granted],
            usage: [.accessibility: ["b", "a"], .camera: ["c"]]
        )
        let accessibility = try #require(row(.accessibility, in: rows))
        #expect(accessibility.isMissing)
        #expect(accessibility.usedBy == ["a", "b"])

        let screen = try #require(row(.screenRecording, in: rows))
        #expect(screen.isUnneeded, "Granted but used by no feature")
        #expect(!screen.isMissing)

        let camera = try #require(row(.camera, in: rows))
        #expect(!camera.isMissing && !camera.isUnneeded)
    }

    @Test func neverRequestedPermissionsMatchDecisions() {
        // These are never requested; everything else only per feature.
        let never = Set(Permission.allCases.filter { $0.usage == .never })
        #expect(never == [.fullDiskAccess, .screenRecording, .bluetooth])
    }

    @Test func onlyAccessibilityAndScreenRecordingRegisterTheApp() {
        #expect(Set(Permission.allCases.filter(\.checkRegistersApp)) == [.accessibility, .screenRecording])
    }

    @Test func uncheckedPermissionsAreNeitherMissingNorUnneeded() throws {
        let rows = PermissionOverview.rows(states: [:], usage: [:])
        let accessibility = try #require(row(.accessibility, in: rows))
        #expect(accessibility.state == .notChecked)
        #expect(!accessibility.isMissing && !accessibility.isUnneeded)
    }

    @Test func notApplicableIsNeverMissing() throws {
        let rows = PermissionOverview.rows(states: [.automation: .notApplicable], usage: [.automation: ["a"]])
        let automation = try #require(row(.automation, in: rows))
        #expect(!automation.isMissing)
    }

    @MainActor @Test func registryMapsPermissionsToFeatures() {
        let registry = FeatureRegistry()
        final class Noop: FeatureModule {
            func start() {}
            func stop() {}
        }
        registry.register(FeatureDescriptor(id: "x", category: .tools, permissions: [.accessibility, .camera])) {
            Noop()
        }
        registry.register(FeatureDescriptor(id: "y", category: .tools, permissions: [.accessibility])) { Noop() }
        let usage = registry.permissionUsage(for: ["x", "y"])
        #expect(usage[.accessibility] == ["x", "y"])
        #expect(usage[.camera] == ["x"])
        #expect(registry.permissionUsage(for: ["y"])[.camera] == nil)
    }
}
