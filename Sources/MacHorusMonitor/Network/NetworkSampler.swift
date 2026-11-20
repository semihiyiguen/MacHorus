// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation
import MacHorusCore
import SystemConfiguration

/// Byte counters of one network interface (64-bit, from NET_RT_IFLIST2).
public struct InterfaceCounters: Equatable, Sendable {
    public let name: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedPackets: UInt64
    public let sentPackets: UInt64
}

/// Where the rates come from.
public enum NetworkMeasurement: String, Sendable {
    /// Physical-interface bytes per connection from NetworkStatistics (the
    /// framework nettop and Activity Monitor use); correct behind network
    /// filters and VPN clients.
    case connections
    /// Interface counters; correct as long as nothing re-injects traffic.
    case interfaces
    /// Interface counters, but incoming traffic is not counted (a network
    /// filter re-injects it): the download cannot be measured.
    case interfacesInboundBlind
}

public struct NetworkSnapshot: Equatable, Sendable {
    /// Nil until two readings exist, and always nil for
    /// `.interfacesInboundBlind`, so the UI never shows a misleading zero.
    public let downloadBytesPerSecond: Double?
    public let uploadBytesPerSecond: Double?
    public let measurement: NetworkMeasurement
    /// Interface that carries the default route, e.g. `en0`.
    public let primaryInterface: String?
    public let localIPv4: String?
    /// Connected VPN tunnels (tunnel interfaces with an IPv4 address).
    public let vpnTunnels: [VPNTunnel]
    /// Counters of the counted interfaces, used to verify against `netstat -ib`.
    public let interfaces: [InterfaceCounters]
    /// Physical-interface totals since sampling started (connections only),
    /// used to verify against `nettop -t wifi -t wired`.
    public let connectionTotals: (received: UInt64, sent: UInt64)?

    public static func == (lhs: NetworkSnapshot, rhs: NetworkSnapshot) -> Bool {
        lhs.downloadBytesPerSecond == rhs.downloadBytesPerSecond && lhs.uploadBytesPerSecond == rhs.uploadBytesPerSecond
            && lhs.measurement == rhs.measurement && lhs.primaryInterface == rhs.primaryInterface
            && lhs.localIPv4 == rhs.localIPv4 && lhs.vpnTunnels == rhs.vpnTunnels && lhs.interfaces == rhs.interfaces
            && lhs.connectionTotals?.received == rhs.connectionTotals?.received
            && lhs.connectionTotals?.sent == rhs.connectionTotals?.sent
    }
}

/// Interfaces that carry real traffic. Tunnels (utun), bridges and AirDrop
/// links would count the same bytes twice.
enum InterfaceFilter {
    static func counts(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }
}

/// Network filters (e.g. endpoint security software) can re-inject incoming
/// packets so that the interface counters never grow, while outgoing ones
/// do. TCP always answers outgoing data with incoming ACKs, so outgoing
/// packets with zero incoming packets mean the inbound counter is blind.
public enum InboundCounting {
    public static func isBlind(sentPackets: UInt64, receivedPackets: UInt64) -> Bool {
        sentPackets >= 20 && receivedPackets == 0
    }
}

public enum ConnectionCounting {
    public static func isBroken(connectionBytes: UInt64, interfaceBytesSent: UInt64) -> Bool {
        connectionBytes == 0 && interfaceBytesSent >= 1_048_576
    }
}

/// Rates from connection statistics when allowed and available, otherwise
/// from interface counters (one sysctl). No subprocesses either way.
final class NetworkSampler {
    /// Nil when the policy disables it, the framework is missing, or it
    /// turned out not to count (see `judgeConnections`).
    private(set) var connectionStatistics: NetworkStatisticsAdapter?
    private var previousConnections: NetworkStatisticsAdapter.Totals?
    /// First totals and interface bytes sent, to notice a framework that
    /// answers but never counts anything.
    private var connectionBaseline: (totals: UInt64, interfaceSent: UInt64)?
    private var previous: (received: UInt64, sent: UInt64, uptime: TimeInterval)?
    private var lastInterfaces: [InterfaceCounters]?
    private var calls = 0
    /// Packet counters at the first reading. Judged cumulatively, because an
    /// idle Mac may send fewer than 20 packets per round.
    private var packetBaseline: (received: UInt64, sent: UInt64)?
    private var inbound = InboundState.undecided
    private let store = SCDynamicStoreCreate(nil, "MacHorus" as CFString, nil, nil)

    enum InboundState {
        case undecided
        case counted
        case blind
    }

    /// `allowConnectionStatistics` is false when the policy disables the
    /// private NetworkStatistics interface (kill switch).
    private let interfaceRefreshEvery: Int

    /// `interfaceRefreshEvery`: with connection statistics, read the interface
    /// counters only every n-th call (the probe uses 1 to compare with netstat).
    init(allowConnectionStatistics: Bool = true, interfaceRefreshEvery: Int = 5) {
        connectionStatistics = allowConnectionStatistics ? NetworkStatisticsAdapter() : nil
        self.interfaceRefreshEvery = max(1, interfaceRefreshEvery)
    }

    /// `connectionTotals` comes from `connectionStatistics.refresh()` right
    /// before the call; nil (a timed-out query) leaves this round's rates
    /// empty instead of guessing.
    func sample(
        connectionTotals: NetworkStatisticsAdapter.Totals? = nil,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NetworkSnapshot? {
        // With connection statistics the interface counters only feed the
        // self-check (`judgeConnections`): every fifth call is enough
        // (1.3 ms each). The fallback needs them every time.
        defer { calls &+= 1 }
        if connectionStatistics != nil, calls % interfaceRefreshEvery != 0, let cached = lastInterfaces {
            return snapshot(interfaces: cached, connectionTotals: connectionTotals, uptime: uptime, fresh: false)
        }
        guard let interfaces = Self.interfaceCounters() else { return nil }
        lastInterfaces = interfaces
        return snapshot(interfaces: interfaces, connectionTotals: connectionTotals, uptime: uptime, fresh: true)
    }

    private func snapshot(
        interfaces: [InterfaceCounters], connectionTotals: NetworkStatisticsAdapter.Totals?, uptime: TimeInterval,
        fresh: Bool
    ) -> NetworkSnapshot? {
        let counted = interfaces.filter { InterfaceFilter.counts($0.name) }
        let received = counted.reduce(UInt64(0)) { $0 + $1.receivedBytes }
        let sent = counted.reduce(UInt64(0)) { $0 + $1.sentBytes }
        var interfaceRates: (download: Double, upload: Double)?
        if fresh, let previous, uptime > previous.uptime, received >= previous.received, sent >= previous.sent {
            interfaceRates = (
                Double(received - previous.received) / (uptime - previous.uptime),
                Double(sent - previous.sent) / (uptime - previous.uptime)
            )
        }
        if fresh { previous = (received, sent, uptime) }
        judgeInbound(
            receivedPackets: counted.reduce(UInt64(0)) { $0 + $1.receivedPackets },
            sentPackets: counted.reduce(UInt64(0)) { $0 + $1.sentPackets })
        let primary = primaryInterface()
        let addresses = InterfaceAddresses.read()

        if fresh, let totals = connectionTotals { judgeConnections(totals, interfaceSent: sent) }

        let measurement: NetworkMeasurement
        var download: Double?
        var upload: Double?
        var totals: NetworkStatisticsAdapter.Totals?
        if connectionStatistics != nil {
            measurement = .connections
            totals = connectionTotals
            if let old = previousConnections, let new = totals, new.uptime > old.uptime,
                new.received >= old.received, new.sent >= old.sent
            {
                download = Double(new.received - old.received) / (new.uptime - old.uptime)
                upload = Double(new.sent - old.sent) / (new.uptime - old.uptime)
            }
            if let totals { previousConnections = totals }
        } else {
            measurement = inbound == .blind ? .interfacesInboundBlind : .interfaces
            // Until an incoming packet was counted, a 0 could be a blind counter.
            download = inbound == .counted ? interfaceRates?.download : nil
            upload = interfaceRates?.upload
        }
        return NetworkSnapshot(
            downloadBytesPerSecond: download, uploadBytesPerSecond: upload, measurement: measurement,
            primaryInterface: primary, localIPv4: primary.flatMap(addresses.ipv4(of:)),
            vpnTunnels: addresses.vpnTunnels, interfaces: counted,
            connectionTotals: totals.map { ($0.received, $0.sent) })
    }

    /// Interface counters always count outgoing bytes, also behind network
    /// filters. If they grew by 1 MB while the connection totals did not
    /// move at all, the framework answers but does not count (e.g. changed
    /// keys in a future macOS): fall back to the interface counters.
    private func judgeConnections(_ totals: NetworkStatisticsAdapter.Totals, interfaceSent: UInt64) {
        guard connectionStatistics != nil else { return }
        guard let baseline = connectionBaseline else {
            connectionBaseline = (totals.received + totals.sent, interfaceSent)
            return
        }
        if ConnectionCounting.isBroken(
            connectionBytes: totals.received + totals.sent - baseline.totals,
            interfaceBytesSent: interfaceSent >= baseline.interfaceSent ? interfaceSent - baseline.interfaceSent : 0)
        {
            Log.monitor.error("NetworkStatistics does not count; using interface counters")
            connectionStatistics = nil
            previousConnections = nil
        }
    }

    /// Decides once per sampler whether incoming traffic is counted at all.
    private func judgeInbound(receivedPackets: UInt64, sentPackets: UInt64) {
        guard inbound == .undecided else { return }
        guard let baseline = packetBaseline else {
            packetBaseline = (receivedPackets, sentPackets)
            return
        }
        if receivedPackets > baseline.received {
            inbound = .counted
        } else if sentPackets >= baseline.sent,
            InboundCounting.isBlind(sentPackets: sentPackets - baseline.sent, receivedPackets: 0)
        {
            inbound = .blind
        }
    }

    /// Reads all interfaces with up-to-date 64-bit counters.
    static func interfaceCounters() -> [InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var result: [InterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let link = offset + MemoryLayout<if_msghdr2>.size
                    if let name = Self.linkName(
                        raw, at: link, end: offset + messageLength, addresses: message.ifm_addrs)
                        ?? Self.indexName(message.ifm_index)
                    {
                        result.append(
                            InterfaceCounters(
                                name: name,
                                receivedBytes: message.ifm_data.ifi_ibytes,
                                sentBytes: message.ifm_data.ifi_obytes,
                                receivedPackets: message.ifm_data.ifi_ipackets,
                                sentPackets: message.ifm_data.ifi_opackets))
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// The interface name from the link address that follows the message.
    /// `if_indextoname` would read every interface again (getifaddrs) and
    /// cost 6.8 ms per round instead of 0.3 ms (docs/MEASUREMENTS.md).
    static func linkName(_ raw: UnsafeRawBufferPointer, at offset: Int, end: Int, addresses: Int32) -> String? {
        let header = 8  // sdl_len, sdl_family, sdl_index, sdl_type, sdl_nlen, sdl_alen, sdl_slen
        guard addresses & RTA_IFP != 0, offset + header <= end, offset + header <= raw.count,
            raw[offset + 1] == UInt8(AF_LINK)
        else { return nil }
        let length = Int(raw[offset + 5])
        guard length > 0, length < Int(IF_NAMESIZE), offset + header + length <= min(end, raw.count) else { return nil }
        return String(decoding: raw[(offset + header)..<(offset + header + length)], as: UTF8.self)
    }

    private static func indexName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return if_indextoname(UInt32(index), &name) != nil ? string(fromNullTerminated: name) : nil
    }

    static func string(fromNullTerminated characters: [CChar]) -> String {
        String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func primaryInterface() -> String? {
        guard let store,
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
}
