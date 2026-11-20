// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Loads administrator policy from root-owned property lists, e.g. deployed
/// by Munki or, if one is ever introduced, an MDM.
public enum PolicyLoader {
    public static var defaultLocations: [URL] {
        let file = "\(AppIdentity.bundleIdentifier).plist"
        return [
            URL(fileURLWithPath: "/Library/Preferences").appendingPathComponent(file),
            URL(fileURLWithPath: "/Library/Managed Preferences").appendingPathComponent(file),
            URL(fileURLWithPath: "/Library/Managed Preferences")
                .appendingPathComponent(NSUserName())
                .appendingPathComponent(file),
        ]
    }

    /// Merges all trusted policy files that exist. A file counts only when it
    /// is owned by root and not writable by group or others; otherwise a user
    /// could grant themselves features the administrator blocked.
    public static func load(
        from urls: [URL] = defaultLocations,
        requireRootOwnership: Bool = true,
        fileManager: FileManager = .default
    ) -> FeaturePolicy {
        urls.reduce(FeaturePolicy.none) { policy, url in
            guard let filePolicy = loadFile(url, requireRootOwnership: requireRootOwnership, fileManager: fileManager)
            else {
                return policy
            }
            return policy.merged(with: filePolicy)
        }
    }

    static func loadFile(_ url: URL, requireRootOwnership: Bool, fileManager: FileManager) -> FeaturePolicy? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        if requireRootOwnership {
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard owner == 0, mode & 0o022 == 0 else {
                Log.policy.error("Ignoring untrusted policy file \(url.path, privacy: .public)")
                return nil
            }
        }
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            Log.policy.error("Ignoring unreadable policy file \(url.path, privacy: .public)")
            return nil
        }
        Log.policy.notice("Loaded policy from \(url.path, privacy: .public)")
        return FeaturePolicy(dictionary: dictionary)
    }
}
