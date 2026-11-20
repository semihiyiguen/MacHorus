// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// Knows every feature and owns the instances of the running ones.
@MainActor
public final class FeatureRegistry {
    private struct Entry {
        let descriptor: FeatureDescriptor
        let make: @MainActor () -> any FeatureModule
    }

    private var entries: [FeatureID: Entry] = [:]

    private var order: [FeatureID] = []
    private var running: [FeatureID: any FeatureModule] = [:]

    public init() {}

    public func register(_ descriptor: FeatureDescriptor, make: @escaping @MainActor () -> any FeatureModule) {
        precondition(entries[descriptor.id] == nil, "Feature \(descriptor.id) registered twice")
        precondition(
            descriptor.permissions.allSatisfy { $0.usage == .perFeature },
            "Feature \(descriptor.id) needs a permission MacHorus never requests")
        if entries[descriptor.id] == nil { order.append(descriptor.id) }
        entries[descriptor.id] = Entry(descriptor: descriptor, make: make)
    }

    /// In the order of registration, which is the order the panel shows.
    public var descriptors: [FeatureDescriptor] {
        order.compactMap { entries[$0]?.descriptor }
    }

    public var runningFeatures: Set<FeatureID> { Set(running.keys) }

    /// Union of the permissions the given features need.
    public func permissions(for ids: Set<FeatureID>) -> Set<Permission> {
        ids.reduce(into: Set<Permission>()) { result, id in
            result.formUnion(entries[id]?.descriptor.permissions ?? [])
        }
    }

    /// For each permission, the given features that need it.
    public func permissionUsage(for ids: Set<FeatureID>) -> [Permission: [FeatureID]] {
        var usage: [Permission: [FeatureID]] = [:]
        for id in ids.sorted() {
            for permission in entries[id]?.descriptor.permissions ?? [] {
                usage[permission, default: []].append(id)
            }
        }
        return usage
    }

    /// Makes exactly the registered features in `enabled` run. Disabled
    /// features are stopped and released; unknown identifiers are ignored.
    public func apply(enabled: Set<FeatureID>) {
        let interval = Log.signposter.beginInterval("ApplyFeatures")
        defer { Log.signposter.endInterval("ApplyFeatures", interval) }
        for id in running.keys.sorted() where !enabled.contains(id) {
            running.removeValue(forKey: id)?.stop()
            Log.features.info("Stopped feature \(id.rawValue, privacy: .public)")
        }
        for id in enabled.sorted() where running[id] == nil {
            guard let entry = entries[id] else { continue }
            let module = entry.make()
            module.start()
            running[id] = module
            Log.features.info("Started feature \(id.rawValue, privacy: .public)")
        }
    }

    public func stopAll() {
        apply(enabled: [])
    }
}
