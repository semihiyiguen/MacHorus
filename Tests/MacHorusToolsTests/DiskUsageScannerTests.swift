// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusTools

/// Runs only on a temporary folder: a scan of the real home folder would
/// make macOS ask for Desktop, Documents and Downloads.
struct DiskUsageScannerTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)")
        func file(_ path: String, _ size: Int) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
        try file("Movies/a.mov", 3_000_000)
        try file("Movies/clips/b.mov", 1_000_000)
        try file("Projects/src/main.swift", 200_000)
        try file("Library/Caches/big.cache", 2_000_000)
        try file("Library/Application Support/Tool/data.db", 1_500_000)
        try file("Library/Containers/other.app/secret", 9_000_000)
        try file("notes.txt", 10_000)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Movies"))
        return root
    }

    @Test func ranksFoldersAndFilesBySpaceOnDisk() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = DiskUsageScanner.scan(root, limit: 3)
        #expect(report.folders.map(\.relativePath) == ["Movies", "Library/Caches", "Library/Application Support/Tool"])
        #expect(report.folders[0].bytes >= 4_000_000)
        #expect(
            report.files.map(\.relativePath) == [
                "Movies/a.mov", "Library/Caches/big.cache",
                "Library/Application Support/Tool/data.db",
            ])
        #expect(report.denied.isEmpty)
    }

    @Test func leavesOutOtherAppsDataAndLinks() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = DiskUsageScanner.scan(root, limit: 10)
        #expect(!report.files.contains { $0.relativePath.hasPrefix("Library/Containers") })
        #expect(!report.folders.contains { $0.relativePath.hasPrefix("Library/Containers") })
        // The link to Movies does not count Movies twice.
        #expect(!report.files.contains { $0.relativePath.hasPrefix("link") })
        #expect(report.folders.filter { $0.relativePath == "Movies" }.count == 1)
    }

    @Test func stopsWhenCancelled() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = DiskUsageScanner.scan(root, isCancelled: { true })
        #expect(report.files.isEmpty)
    }

    @Test func expandsLibraryToItsChildren() {
        #expect(DiskUsageScanner.owners(of: "Library/Caches/x/y") == ["Library/Caches"])
        #expect(
            DiskUsageScanner.owners(of: "Library/Application Support/Tool/x") == ["Library/Application Support/Tool"])
        #expect(DiskUsageScanner.owners(of: "Movies/a.mov") == ["Movies"])
        #expect(DiskUsageScanner.owners(of: "notes.txt") == [])
    }
}
