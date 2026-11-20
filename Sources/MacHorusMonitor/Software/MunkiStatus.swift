// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// Pending software updates as Munki and macOS report them, read from the
/// local files only (world-readable, no permission, no network). The
/// repository address and client identifier in Munki's preferences are
/// never read into this type.
public struct SoftwareUpdates: Equatable, Sendable {
    public enum Restart: Int, Comparable, Sendable {
        case none, logout, recommended, required

        public static func < (lhs: Restart, rhs: Restart) -> Bool { lhs.rawValue < rhs.rawValue }

        init(munki value: String?) {
            switch value {
            case "RequireRestart": self = .required
            case "RecommendRestart": self = .recommended
            case "RequireLogout": self = .logout
            default: self = .none
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public let name: String
        public let version: String?
        public let restart: Restart
        public let isRemoval: Bool
    }

    /// Munki items to install or remove, in Munki's order.
    public let munkiItems: [Item]
    /// Items Munki could not install last time.
    public let problemItems: [String]
    /// End of Munki's last check.
    public let lastCheck: Date?
    /// macOS updates the system recommends (Software Update).
    public let appleUpdates: [Item]

    public var count: Int { munkiItems.count + appleUpdates.count }
    public var restart: Restart { (munkiItems + appleUpdates).map(\.restart).max() ?? .none }

    public static let munkiDirectory = URL(fileURLWithPath: "/Library/Managed Installs")
    public static let munkiPreferences = URL(fileURLWithPath: "/Library/Preferences/ManagedInstalls.plist")
    public static let softwareUpdatePreferences = URL(
        fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")

    /// Whether Munki manages this Mac; without it the feature does not exist.
    public static var isMunkiInstalled: Bool {
        FileManager.default.fileExists(atPath: munkiDirectory.appendingPathComponent("InstallInfo.plist").path)
    }

    /// Reads the current state; nil when Munki's install list is missing.
    public static func read(
        munkiDirectory: URL = munkiDirectory, preferences: URL = munkiPreferences,
        softwareUpdate: URL = softwareUpdatePreferences
    ) -> SoftwareUpdates? {
        guard let installInfo = dictionary(at: munkiDirectory.appendingPathComponent("InstallInfo.plist")) else {
            return nil
        }
        let preferences = dictionary(at: preferences)
        return parse(
            installInfo: installInfo,
            lastCheck: preferences?["LastCheckDate"] as? Date,
            softwareUpdate: dictionary(at: softwareUpdate))
    }

    /// Macs without Munki: only what Software Update recommends.
    public static func appleUpdatesOnly(softwareUpdate: URL = softwareUpdatePreferences) -> SoftwareUpdates {
        parse(installInfo: [:], lastCheck: nil, softwareUpdate: dictionary(at: softwareUpdate))
    }

    static func parse(installInfo: [String: Any], lastCheck: Date?, softwareUpdate: [String: Any]?) -> SoftwareUpdates {
        func items(_ key: String, removal: Bool) -> [Item] {
            (installInfo[key] as? [[String: Any]] ?? []).compactMap { item in
                // Already installed items stay in the list; they are not pending.
                if !removal, item["installed"] as? Bool == true { return nil }
                if removal, item["installed"] as? Bool == false { return nil }
                guard let name = (item["display_name"] as? String) ?? (item["name"] as? String), !name.isEmpty
                else { return nil }
                return Item(
                    name: name, version: removal ? nil : item["version_to_install"] as? String,
                    restart: Restart(munki: item["RestartAction"] as? String), isRemoval: removal)
            }
        }
        let problems = (installInfo["problem_items"] as? [[String: Any]] ?? []).compactMap {
            ($0["display_name"] as? String) ?? ($0["name"] as? String)
        }
        let apple = (softwareUpdate?["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap { item -> Item? in
            guard let name = item["Display Name"] as? String else { return nil }
            // macOS updates restart; the list does not say which ones do not.
            return Item(name: name, version: item["Display Version"] as? String, restart: .required, isRemoval: false)
        }
        return SoftwareUpdates(
            munkiItems: items("managed_installs", removal: false) + items("managed_updates", removal: false)
                + items("removals", removal: true),
            problemItems: problems, lastCheck: lastCheck, appleUpdates: apple)
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
