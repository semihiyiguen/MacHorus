// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// Which VPN is up: the tunnels with an address, the VPN services macOS
/// reports as connected (`scutil --nc list`, no permission), and, for
/// clients that open their tunnel without a system service (OpenVPN
/// Connect, many corporate clients), the client recognised by its process.
public struct VPNStatus: Equatable, Sendable {
    public struct Tunnel: Equatable, Sendable {
        public let interface: String
        public let address: String
    }

    public let tunnels: [Tunnel]
    /// Names of connected system VPN services ("Tailscale", "Office").
    public let services: [String]

    public var isUp: Bool { !tunnels.isEmpty }

    public init(tunnels: [Tunnel], services: [String]) {
        self.tunnels = tunnels
        self.services = services
    }

    /// Process names of common VPN clients (as `nettop` shows them, which
    /// cuts names at 15 characters). Lower case, matched by prefix.
    static let clientPrefixes = [
        "openvpn", "ovpnagent", "tunnelblick", "viscosity", "tailscale", "ipnextension", "wireguard",
        "nordvpn", "protonvpn", "expressvpn", "mullvad", "cisco", "vpnagentd", "acwebsecagent", "globalprotect",
        "pangps", "forticlient", "fortitray", "zscaler", "f5", "pulse", "netextender", "surfshark", "cloudflare",
        "warp", "nesessionmanager",
    ]

    public static func isClient(_ processName: String) -> Bool {
        let name = processName.lowercased()
        return clientPrefixes.contains { name.hasPrefix($0) }
    }

    /// `scutil --nc list` lines like
    /// `* (Connected)  <UUID> VPN (io.tailscale.ipn.macos) "Tailscale"  [VPN:…]`.
    static func connectedServices(fromList output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains("(Connected)"), let open = line.firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            let name = String(rest[..<close])
            return name.isEmpty ? nil : name
        }
    }

    /// Blocking (one `scutil` run when a tunnel is up): off the main thread.
    public static func read() -> VPNStatus {
        let tunnels = tunnelAddresses()
        guard !tunnels.isEmpty else { return VPNStatus(tunnels: [], services: []) }
        return VPNStatus(
            tunnels: tunnels, services: connectedServices(fromList: run("/usr/sbin/scutil", ["--nc", "list"])))
    }

    static func tunnelAddresses() -> [Tunnel] {
        var result: [Tunnel] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard AppTraffic.isTunnel(name), let address = entry.ifa_addr,
                Int32(address.pointee.sa_family) == AF_INET
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("169.254.") { result.append(Tunnel(interface: name, address: text)) }
        }
        return result.sorted { $0.interface < $1.interface }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
