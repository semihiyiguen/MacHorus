// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct VPNDetectionTests {
    @Test func onlyTunnelsWithIPv4CountAsVPN() {
        // utun0-4 exist without a VPN but carry no IPv4 address.
        let addresses = InterfaceAddresses(ipv4: [
            ("lo0", "127.0.0.1"), ("en0", "192.168.1.20"), ("utun5", "10.8.0.7"), ("utun6", "169.254.3.1"),
            ("ipsec0", "172.16.0.2"), ("bridge0", "192.168.2.1"),
        ])
        #expect(
            addresses.vpnTunnels == [
                VPNTunnel(interface: "utun5", ipv4: "10.8.0.7"), VPNTunnel(interface: "ipsec0", ipv4: "172.16.0.2"),
            ])
        #expect(addresses.ipv4(of: "en0") == "192.168.1.20")
        #expect(InterfaceAddresses(ipv4: [("en0", "192.168.1.20")]).vpnTunnels.isEmpty)
    }

    @Test func liveReadIncludesLoopback() {
        #expect(InterfaceAddresses.read().ipv4(of: "lo0") == "127.0.0.1")
    }
}

@Suite struct SoftwareUpdatesTests {
    private let installInfo: [String: Any] = [
        "managed_installs": [
            ["name": "Browser", "display_name": "Web Browser", "version_to_install": "2.0", "installed": false],
            ["name": "Editor", "version_to_install": "1.1", "installed": true],
            [
                "name": "Driver", "display_name": "Printer Driver", "version_to_install": "5",
                "installed": false, "RestartAction": "RequireRestart",
            ],
        ],
        "removals": [
            ["name": "OldTool", "installed": true],
            ["name": "GoneTool", "installed": false],
        ],
        "problem_items": [["name": "Broken", "display_name": "Broken App"]],
    ]

    @Test func pendingItemsOnly() {
        let updates = SoftwareUpdates.parse(installInfo: installInfo, lastCheck: nil, softwareUpdate: nil)
        #expect(updates.munkiItems.map(\.name) == ["Web Browser", "Printer Driver", "OldTool"])
        #expect(updates.munkiItems.map(\.isRemoval) == [false, false, true])
        #expect(updates.munkiItems.first?.version == "2.0")
        #expect(updates.problemItems == ["Broken App"])
        #expect(updates.restart == .required)
        #expect(updates.count == 3)
    }

    @Test func appleUpdatesRestartAndCount() {
        let apple: [String: Any] = [
            "RecommendedUpdates": [["Display Name": "macOS 27.0.1", "Display Version": "27.0.1"]]
        ]
        let updates = SoftwareUpdates.parse(
            installInfo: [:], lastCheck: Date(timeIntervalSince1970: 0), softwareUpdate: apple)
        #expect(updates.munkiItems.isEmpty)
        #expect(updates.appleUpdates.map(\.name) == ["macOS 27.0.1"])
        #expect(updates.restart == .required)
        #expect(updates.lastCheck == Date(timeIntervalSince1970: 0))
    }

    @Test func nothingPendingNeedsNoRestart() {
        let updates = SoftwareUpdates.parse(
            installInfo: ["managed_installs": [["name": "Editor", "installed": true]]], lastCheck: nil,
            softwareUpdate: nil)
        #expect(updates.count == 0)
        #expect(updates.restart == .none)
    }

    @Test func readsFilesAndIgnoresAMissingDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try PropertyListSerialization.data(fromPropertyList: installInfo, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("InstallInfo.plist"))
        let missing = folder.appendingPathComponent("missing.plist")
        let updates = try #require(
            SoftwareUpdates.read(munkiDirectory: folder, preferences: missing, softwareUpdate: missing))
        #expect(updates.munkiItems.count == 3)
        #expect(SoftwareUpdates.read(munkiDirectory: missing, preferences: missing, softwareUpdate: missing) == nil)
    }
}

@Suite struct ListeningPortsTests {
    /// Opens a real listening socket in this test process and finds it.
    @Test func findsOwnListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let found = ListeningPorts.read().filter { $0.port == port }
        #expect(found.count == 1)
        #expect(found.first?.identity.pid == getpid())
        #expect(found.first?.isLoopbackOnly == true)
    }

    @Test func mergesIPv4AndIPv6OfOnePort() {
        let merged = ListeningPorts.merge([(8080, true), (8080, false), (3000, true), (3000, true)])
        #expect(merged.map(\.0) == [3000, 8080])
        #expect(merged.map(\.1) == [true, false])
    }
}
