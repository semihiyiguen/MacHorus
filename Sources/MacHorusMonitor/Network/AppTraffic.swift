// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// Which way traffic leaves the Mac: through a VPN tunnel or directly over
/// the own connection (Wi-Fi, cable).
public enum TrafficRoute: String, CaseIterable, Sendable {
    case all
    case vpn
    case direct
}

/// One app's (one process's) network rate in bytes per second, split by route.
public struct NetworkUse: Equatable, Sendable {
    public var vpnIn: Double = 0
    public var vpnOut: Double = 0
    public var directIn: Double = 0
    public var directOut: Double = 0

    public init(vpnIn: Double = 0, vpnOut: Double = 0, directIn: Double = 0, directOut: Double = 0) {
        self.vpnIn = vpnIn
        self.vpnOut = vpnOut
        self.directIn = directIn
        self.directOut = directOut
    }

    public func download(_ route: TrafficRoute) -> Double {
        switch route {
        case .all: vpnIn + directIn
        case .vpn: vpnIn
        case .direct: directIn
        }
    }

    public func upload(_ route: TrafficRoute) -> Double {
        switch route {
        case .all: vpnOut + directOut
        case .vpn: vpnOut
        case .direct: directOut
        }
    }

    public func total(_ route: TrafficRoute) -> Double { download(route) + upload(route) }

    public static func + (lhs: NetworkUse, rhs: NetworkUse) -> NetworkUse {
        NetworkUse(
            vpnIn: lhs.vpnIn + rhs.vpnIn, vpnOut: lhs.vpnOut + rhs.vpnOut, directIn: lhs.directIn + rhs.directIn,
            directOut: lhs.directOut + rhs.directOut)
    }
}

/// Network use per process from `nettop` (part of macOS; it reads the
/// kernel's per-connection counters without any permission and sees every
/// process). One run costs about 30 ms CPU, so it runs only while the list
/// sorted by network is on screen.
public struct AppTraffic: Sendable {
    /// One connection as `nettop` prints it, under its process.
    public struct Flow: Equatable, Sendable {
        public let pid: pid_t
        public let name: String
        /// Protocol and addresses: unique per connection of a process.
        public let key: String
        public let interface: String
        public let bytesIn: UInt64
        public let bytesOut: UInt64
    }

    public struct Use: Equatable, Sendable {
        public let pid: pid_t
        public let name: String
        /// Bytes per second since the last reading (zero at the first one).
        public let use: NetworkUse
        /// Bytes carried since the last reading; at the first reading all a
        /// connection carried since it opened (to add up totals).
        public let bytes: NetworkUse

        public init(pid: pid_t, name: String, use: NetworkUse, bytes: NetworkUse) {
            self.pid = pid
            self.name = name
            self.use = use
            self.bytes = bytes
        }
    }

    private var previous: [String: (in: UInt64, out: UInt64)] = [:]
    private var previousTime: Date?

    public init() {}

    /// Rates since the last call; the first call has none yet. A connection
    /// that is new since the last call counts with everything it carried.
    @discardableResult
    public mutating func rates(_ flows: [Flow], vpnInterfaces: Set<String>, at now: Date) -> [Use] {
        defer {
            previous = Dictionary(
                flows.map { ("\($0.pid)|\($0.key)", (in: $0.bytesIn, out: $0.bytesOut)) },
                uniquingKeysWith: { first, _ in first })
            previousTime = now
        }
        let isFirst = previousTime == nil
        guard isFirst || now > previousTime! else { return [] }
        let seconds = previousTime.map { now.timeIntervalSince($0) }
        var uses: [pid_t: (name: String, use: NetworkUse, bytes: NetworkUse)] = [:]
        for flow in flows where !Self.isLocal(flow.interface) {
            let before = previous["\(flow.pid)|\(flow.key)"] ?? (in: 0, out: 0)
            // Counters only grow; a reused key with smaller counts is a new connection.
            let received = flow.bytesIn >= before.in ? flow.bytesIn - before.in : flow.bytesIn
            let sent = flow.bytesOut >= before.out ? flow.bytesOut - before.out : flow.bytesOut
            guard received > 0 || sent > 0 else { continue }
            let vpn = vpnInterfaces.contains(flow.interface)
            var entry = uses[flow.pid] ?? (name: flow.name, use: NetworkUse(), bytes: NetworkUse())
            let rateIn = seconds.map { Double(received) / $0 } ?? 0
            let rateOut = seconds.map { Double(sent) / $0 } ?? 0
            if vpn {
                entry.use.vpnIn += rateIn
                entry.use.vpnOut += rateOut
                entry.bytes.vpnIn += Double(received)
                entry.bytes.vpnOut += Double(sent)
            } else {
                entry.use.directIn += rateIn
                entry.use.directOut += rateOut
                entry.bytes.directIn += Double(received)
                entry.bytes.directOut += Double(sent)
            }
            uses[flow.pid] = entry
        }
        return uses.map { Use(pid: $0.key, name: $0.value.name, use: $0.value.use, bytes: $0.value.bytes) }
    }

    static func isLocal(_ interface: String) -> Bool {
        interface.isEmpty || interface.hasPrefix("lo")
    }

    // MARK: Reading

    /// `nettop -L 1 -n -x -t external -J interface,bytes_in,bytes_out`: a process line
    /// ("Safari.123,,in,out,") followed by its connections
    /// ("tcp4 a:1<->b:2,en0,in,out,").
    public static func parse(_ csv: String) -> [Flow] {
        var flows: [Flow] = []
        var pid: pid_t?
        var name = ""
        for line in csv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { continue }
            let first = fields[0]
            if first.hasPrefix("tcp") || first.hasPrefix("udp") {
                guard let pid, let bytesIn = UInt64(fields[2]), let bytesOut = UInt64(fields[3]) else { continue }
                flows.append(
                    Flow(pid: pid, name: name, key: first, interface: fields[1], bytesIn: bytesIn, bytesOut: bytesOut))
            } else if let dot = first.lastIndex(of: "."), let number = pid_t(first[first.index(after: dot)...]) {
                pid = number
                name = String(first[..<dot])
            }
        }
        return flows
    }

    /// Runs `nettop` once; nil if it is missing or takes longer than 3 s.
    /// Blocking: call off the main thread.
    public static func read() -> [Flow]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // External interfaces only (Wi-Fi, cable, VPN tunnels): skips loopback
        // and AWDL and costs 30 instead of 80 ms CPU (measured).
        process.arguments = ["-L", "1", "-n", "-x", "-t", "external", "-J", "interface,bytes_in,bytes_out"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = DispatchTime.now() + .seconds(3)
        let finished = DispatchSemaphore(value: 0)
        let reader = DispatchQueue.global(qos: .utility)
        let box = DataBox()
        reader.async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: box.data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Tunnels with an address in use: a VPN (WireGuard, IPsec, OpenVPN,
    /// corporate clients). macOS keeps a few `utun` without such an address
    /// for itself; those do not count.
    public static func vpnInterfaces() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard isTunnel(name), let address = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                // 169.254/16 is link-local, not a tunnel in use.
                if UInt32(bigEndian: ipv4) >> 16 != 0xA9FE { result.insert(name) }
            case AF_INET6:
                let first = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0
                }
                // Global unicast (2000::/3) only; fe80:: link-local is the system's own.
                if first & 0xE0 == 0x20 { result.insert(name) }
            default: break
            }
        }
        return result
    }

    static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { name.hasPrefix($0) }
    }
}
