// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusTools
import Observation

/// "What takes the space": scans the home folder only when asked
/// (Analysieren), off the main thread; the result stays until MacHorus
/// ends or the next scan. macOS asks once each for Desktop, Documents and
/// Downloads the first time; nothing is changed on disk.
@MainActor
@Observable
final class DiskUsageModel {
    private(set) var report: DiskUsageReport?
    private(set) var isScanning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        if UserDefaults.standard.string(forKey: "debug.diskUsageRoot") != nil { scan() }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        // `-debug.diskUsageRoot <folder>` scans that folder instead (renders
        // without macOS asking about the real Desktop or Documents).
        let home =
            UserDefaults.standard.string(forKey: "debug.diskUsageRoot").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        task = Task { [weak self] in
            let report = await OffMain.run { DiskUsageScanner.scan(home) }
            guard let self else { return }
            self.report = report
            isScanning = false
            Log.features.notice(
                "Disk usage scanned: \(report.folders.count, privacy: .public) folders, \(report.denied.count, privacy: .public) refused"
            )
        }
    }

    /// Shows the item in Finder (selected), never opens it.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
