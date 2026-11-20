// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// What takes the most space in a folder (the home folder): its largest
/// subfolders and files. Read only, on request, never deleted or moved.
///
/// Sizes are the space on disk (`totalFileAllocatedSize`), as Finder's
/// "Get Info" shows them. Symbolic links are not followed. Folders that
/// would make macOS ask about other apps' data, mail, photos or iCloud
/// are left out (`skipped`); folders macOS refuses count in `denied`.
public struct DiskUsageReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let url: URL
        public let bytes: UInt64
        public var id: URL { url }
        /// Path below the scanned folder ("Library/Caches").
        public let relativePath: String
    }

    public let folders: [Entry]
    public let files: [Entry]
    /// Folders macOS did not let MacHorus read (consent refused).
    public let denied: [String]
    public let date: Date
}

public enum DiskUsageScanner {
    /// Below the home folder: other apps' data (macOS asks "access data
    /// from other apps"), mail, messages, photos and iCloud Drive.
    public static let skipped: Set<String> = [
        "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages",
        "Library/Safari", "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB", "Library/Suggestions", "Library/Metadata/CoreSpotlight",
        ".Trash",
    ]

    /// Folders whose biggest children say more than the folder itself.
    static let expanded: Set<String> = ["Library", "Library/Application Support"]

    /// Scans `root`; `limit` folders and files each. Stops early (with
    /// what it has) when `isCancelled` turns true.
    public static func scan(
        _ root: URL, limit: Int = 5, skipped: Set<String> = skipped, isCancelled: () -> Bool = { false }
    ) -> DiskUsageReport {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var folderSizes: [String: UInt64] = [:]
        var largest: [DiskUsageReport.Entry] = []
        var denied: [String] = []
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .isPackageKey,
        ]
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"

        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        }

        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { url, _ in
                let path = relative(url)
                if !path.isEmpty, !denied.contains(path) { denied.append(path) }
                return true
            })
        while let url = enumerator?.nextObject() as? URL {
            if isCancelled() { break }
            let path = relative(url)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if skipped.contains(path) || path.hasSuffix(".photoslibrary") {
                    enumerator?.skipDescendants()
                }
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? 0)
            guard size > 0 else { continue }
            for folder in owners(of: path) { folderSizes[folder, default: 0] += size }
            insert(DiskUsageReport.Entry(url: url, bytes: size, relativePath: path), into: &largest, limit: limit)
        }

        let folders = folderSizes.filter { !expanded.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map {
                DiskUsageReport.Entry(url: root.appendingPathComponent($0.key), bytes: $0.value, relativePath: $0.key)
            }
        return DiskUsageReport(folders: Array(folders), files: largest, denied: denied, date: Date())
    }

    /// The folders a file counts towards: its top-level folder, or below an
    /// expanded folder ("Library") the child inside it.
    static func owners(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        var folder = parts[0]
        var index = 1
        while expanded.contains(folder), index < parts.count - 1 {
            folder += "/" + parts[index]
            index += 1
        }
        return [folder]
    }

    private static func insert(
        _ entry: DiskUsageReport.Entry, into list: inout [DiskUsageReport.Entry], limit: Int
    ) {
        if list.count == limit, let last = list.last, last.bytes >= entry.bytes { return }
        let index = list.firstIndex { $0.bytes < entry.bytes } ?? list.count
        list.insert(entry, at: index)
        if list.count > limit { list.removeLast() }
    }
}
