// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin

/// A VPN tunnel that is up: a tunnel interface with an IPv4 address.
public struct VPNTunnel: Equatable, Sendable {
    public let interface: String
    public let ipv4: String
}

/// IPv4 addresses of all interfaces, read in one `getifaddrs` pass.
public struct InterfaceAddresses: Equatable, Sendable {
    /// Interface name and address, in the system's order.
    public let ipv4: [(interface: String, address: String)]

    public init(ipv4: [(interface: String, address: String)]) {
        self.ipv4 = ipv4
    }

    public static func == (lhs: InterfaceAddresses, rhs: InterfaceAddresses) -> Bool {
        lhs.ipv4.map(\.interface) == rhs.ipv4.map(\.interface) && lhs.ipv4.map(\.address) == rhs.ipv4.map(\.address)
    }

    public func ipv4(of interface: String) -> String? {
        ipv4.first { $0.interface == interface }?.address
    }

    /// macOS keeps several `utun` interfaces even without a VPN (iCloud,
    /// Handoff), but those carry only IPv6 link-local addresses. A tunnel
    /// with an IPv4 address (not 169.254.x) is a VPN that is connected
    /// (OpenVPN, WireGuard, IPsec, Cisco and the like).
    public var vpnTunnels: [VPNTunnel] {
        ipv4.compactMap { entry in
            let isTunnel = ["utun", "ipsec", "ppp", "tun", "tap"].contains { entry.interface.hasPrefix($0) }
            guard isTunnel, !entry.address.hasPrefix("169.254.") else { return nil }
            return VPNTunnel(interface: entry.interface, ipv4: entry.address)
        }
    }

    public static func read() -> InterfaceAddresses {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return InterfaceAddresses(ipv4: []) }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let address = entry.pointee
            guard let socket = address.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            found.append((String(cString: address.ifa_name), NetworkSampler.string(fromNullTerminated: host)))
        }
        return InterfaceAddresses(ipv4: found)
    }
}
