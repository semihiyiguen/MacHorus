// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Saves a screenshot of every on-screen window of a process, used to verify
// UI changes without clicking through the app.
// Usage: swift scripts/dev/window-screenshot.swift <process name> <output directory>
// Needs the Screen Recording permission for the calling terminal.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let owner = arguments.first, let directory = arguments.last else {
    FileHandle.standardError.write(Data("usage: window-screenshot.swift <process name> <output directory>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let matches = windows.filter {
    ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0
}
guard !matches.isEmpty else {
    FileHandle.standardError.write(Data("No on-screen window of \(owner)\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for window in matches {
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    // The status item itself is a tiny window; skip it.
    guard width > 40, height > 40 else { continue }
    let path = "\(directory)/\(owner)-\(number).png"
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), path]
    try capture.run()
    capture.waitUntilExit()
    print("\(path) (\(width)×\(height))")
}
