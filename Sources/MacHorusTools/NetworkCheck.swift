// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import SystemConfiguration

/// "Is it me or the internet?": four steps, only when the user clicks.
/// Connection and router stay on the Mac and in the local network; only
/// the last two leave it: one DNS lookup and one HTTPS request to Apple's
/// own reachability address, the same one macOS uses to detect Wi-Fi
/// login pages. Nothing is sent about the Mac or the user.
public struct NetworkCheck: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        /// An interface with an address carries the traffic.
        case connection
        /// The router (default gateway) answers a ping.
        case router
        /// A name resolves.
        case dns
        /// Apple's reachability page answers with its expected content.
        case internet
    }

    public enum Outcome: Equatable, Sendable {
        case passed(milliseconds: Int?)
        case failed
        /// The step could not run because an earlier one failed.
        case skipped
    }

    public enum Verdict: Equatable, Sendable {
        case allGood
        case noConnection
        /// The router does not answer, but the internet works (many routers
        /// ignore pings): not a problem.
        case routerSilent
        case noRouter
        case noDNS
        case noInternet
        /// The page came back different: a Wi-Fi login page is in the way.
        case loginPage
    }

    public let outcomes: [Step: Outcome]
    public let interface: String?
    public let address: String?
    public let router: String?
    /// Tunnels in use (a VPN), from `AppTraffic`-style detection.
    public let vpnInterfaces: [String]
    public let loginPageSuspected: Bool

    public init(
        outcomes: [Step: Outcome], interface: String?, address: String?, router: String?, vpnInterfaces: [String],
        loginPageSuspected: Bool = false
    ) {
        self.outcomes = outcomes
        self.interface = interface
        self.address = address
        self.router = router
        self.vpnInterfaces = vpnInterfaces
        self.loginPageSuspected = loginPageSuspected
    }

    public var verdict: Verdict {
        func passed(_ step: Step) -> Bool {
            if case .passed = outcomes[step] { return true }
            return false
        }
        guard passed(.connection) else { return .noConnection }
        if passed(.internet) { return passed(.router) ? .allGood : .routerSilent }
        if loginPageSuspected { return .loginPage }
        if !passed(.dns) { return passed(.router) ? .noDNS : .noRouter }
        return .noInternet
    }

    /// The reachability address macOS itself checks.
    static let probeHost = "captive.apple.com"
    static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")

    // MARK: Running

    /// Runs all steps; the blocking ones on a background thread.
    public static func run() async -> NetworkCheck {
        let local = await Task.detached(priority: .userInitiated) { () -> LocalPart in
            let route = primaryRoute()
            let address = route.interface.flatMap(ipv4Address(of:))
            let connection: Outcome = address != nil ? .passed(milliseconds: nil) : .failed
            var router: Outcome = .skipped
            if address != nil, let gateway = route.router {
                router = ping(gateway).map { .passed(milliseconds: $0) } ?? .failed
            }
            var dns: Outcome = .skipped
            if address != nil { dns = resolve(probeHost).map { .passed(milliseconds: $0) } ?? .failed }
            return LocalPart(
                interface: route.interface, address: address, router: route.router, connection: connection,
                routerOutcome: router, dns: dns, tunnels: tunnelInterfaces())
        }.value
        var internet: Outcome = .skipped
        var loginPage = false
        if case .passed = local.dns {
            let (outcome, suspected) = await fetchProbe()
            internet = outcome
            loginPage = suspected
        } else if case .passed = local.connection {
            // DNS failed: a login page may block it too; still try the address.
            let (outcome, suspected) = await fetchProbe()
            internet = outcome
            loginPage = suspected
        }
        return NetworkCheck(
            outcomes: [
                .connection: local.connection, .router: local.routerOutcome, .dns: local.dns, .internet: internet,
            ], interface: local.interface, address: local.address, router: local.router,
            vpnInterfaces: local.tunnels.sorted(), loginPageSuspected: loginPage)
    }

    private struct LocalPart: Sendable {
        let interface: String?
        let address: String?
        let router: String?
        let connection: Outcome
        let routerOutcome: Outcome
        let dns: Outcome
        let tunnels: Set<String>
    }

    /// One GET without cookies, cache or stored credentials, 6 s at most.
    /// The answer of Apple's page contains "Success"; anything else that
    /// comes back means a login page answered instead.
    static func fetchProbe() async -> (Outcome, loginPage: Bool) {
        guard let url = probeURL else { return (.failed, false) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(from: url)
            let milliseconds = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let body = String(decoding: data.prefix(4_096), as: UTF8.self)
            guard (response as? HTTPURLResponse)?.statusCode == 200, body.contains("Success") else {
                return (.failed, true)
            }
            return (.passed(milliseconds: milliseconds), false)
        } catch let error as URLError
            where error.code == .serverCertificateUntrusted
            || error.code == .serverCertificateHasUnknownRoot || error.code == .secureConnectionFailed
        {
            // Someone answered in Apple's place: typical for a login page.
            return (.failed, true)
        } catch {
            return (.failed, false)
        }
    }

    // MARK: Local reads

    /// The interface and router macOS routes the internet through.
    static func primaryRoute() -> (interface: String?, router: String?) {
        guard let store = SCDynamicStoreCreate(nil, "MacHorus" as CFString, nil, nil),
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (global["PrimaryInterface"] as? String, global["Router"] as? String)
    }

    static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == interface, let address = entry.ifa_addr,
                Int32(address.pointee.sa_family) == AF_INET
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }

    static func tunnelInterfaces() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains(where: { name.hasPrefix($0) }),
                let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET
            else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if UInt32(bigEndian: ipv4) >> 16 != 0xA9FE { result.insert(name) }
        }
        return result
    }

    /// One name lookup through the system resolver; milliseconds or nil
    /// after 5 s.
    static func resolve(_ host: String) -> Int? {
        let start = DispatchTime.now()
        let done = DispatchSemaphore(value: 0)
        let result = Flag()
        Thread.detachNewThread {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &info) == 0 {
                result.set()
                freeaddrinfo(info)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, result.value else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// ICMP echo over a datagram socket (no administrator rights needed on
    /// macOS); up to three tries, 1 s each. Milliseconds of the first answer.
    static func ping(_ host: String) -> Int? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { return nil }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let identifier = UInt16(truncatingIfNeeded: getpid())
        for sequence in UInt16(1)...3 {
            var packet = echoRequest(identifier: identifier, sequence: sequence)
            let start = DispatchTime.now()
            let sent = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, &packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == packet.count else { continue }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let received = recv(socket, &buffer, buffer.count, 0)
                guard received > 0 else { break }
                // The kernel may hand back the IP header first.
                let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
                guard received >= offset + 8, buffer[offset] == 0 else { continue }  // echo reply
                let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
                if replySequence == sequence {
                    return Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                }
            }
        }
        return nil
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8),
            UInt8(sequence & 0xFF),
        ]
        packet += Array("MacHorus".utf8)
        let checksum = internetChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }
}
