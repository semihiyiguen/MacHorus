// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import SystemConfiguration

/// What this Mac is, read once: shown on the overview, never sent anywhere.
public struct MacIdentity: Sendable {
    /// The name from System Settings → General → Sharing.
    public let computerName: String?
    /// e.g. "Apple M1" (`machdep.cpu.brand_string`).
    public let chip: String?
    /// e.g. "MacBookPro17,1" (`hw.model`).
    public let model: String?
    public let memoryBytes: UInt64?
    /// e.g. "27.0" or "15.6.1".
    public let systemVersion: String

    public static let current = MacIdentity(
        computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
        chip: sysctlString("machdep.cpu.brand_string"),
        model: sysctlString("hw.model"),
        memoryBytes: sysctlValue("hw.memsize", as: UInt64.self),
        systemVersion: version(ProcessInfo.processInfo.operatingSystemVersion))

    static func version(_ version: OperatingSystemVersion) -> String {
        version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = NetworkSampler.string(fromNullTerminated: buffer)
        return value.isEmpty ? nil : value
    }
}
