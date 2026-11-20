// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// Build with `make` (see Makefile): the Command Line Tools only work with
// SDKROOT pinned to MacOSX26.sdk (the Command Line Tools ship it; no Xcode needed).
let package = Package(
    name: "MacHorus",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "MacHorus", targets: ["MacHorus"])
    ],
    targets: [
        .target(name: "MacHorusCore"),
        // Lock-free relaxed atomics for the audio thread on macOS 14 (Synchronization needs 15).
        .target(name: "CAtomics"),
        // libcups (part of macOS) for the print queue: list and cancel the user's jobs.
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        // System monitor: read-only kernel and IOKit counters, no permissions (docs/PRIVACY.md).
        .target(
            name: "MacHorusMonitor", dependencies: ["MacHorusCore"],
            linkerSettings: [
                .linkedFramework("IOKit"), .linkedFramework("SystemConfiguration"), .linkedFramework("CoreWLAN"),
            ]),
        // Tools that change something on request (keep awake, microphones): public APIs, no permissions.
        // Vision reads QR codes and text in copied images, on the Mac.
        .target(
            name: "MacHorusTools", dependencies: ["MacHorusCore", "CCups", "CAtomics"],
            linkerSettings: [
                .linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("Vision"),
                .linkedFramework("SystemConfiguration"),
            ]),
        // Carbon: RegisterEventHotKey for the clipboard shortcut (no permission).
        .executableTarget(
            name: "MacHorus", dependencies: ["MacHorusCore", "MacHorusMonitor", "MacHorusTools"],
            linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "MacHorusCoreTests", dependencies: ["MacHorusCore"]),
        .testTarget(name: "MacHorusMonitorTests", dependencies: ["MacHorusMonitor"]),
        .testTarget(name: "MacHorusToolsTests", dependencies: ["MacHorusTools"]),
    ],
    swiftLanguageModes: [.v6]
)
