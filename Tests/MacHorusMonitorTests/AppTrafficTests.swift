// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusMonitor

@Suite struct AppTrafficTests {
    /// As nettop prints it (shortened from a real run).
    private static func csv(chrome: (Int, Int), vpn: (Int, Int)) -> String {
        """
        ,interface,bytes_in,bytes_out,
        launchd.1,,0,0,
        tcp4 127.0.0.1:8021<->*:*,lo0,,,
        Google Chrome He.4711,,0,0,
        tcp4 10.0.0.2:5000<->1.2.3.4:443,en0,\(chrome.0),\(chrome.1),
        udp4 10.8.0.2:6000<->5.6.7.8:443,utun4,\(vpn.0),\(vpn.1),
        tcp4 127.0.0.1:9<->127.0.0.1:10,lo0,999,999,
        my.app.name.88,,0,0,
        tcp6 *.22<->*.*,,,,

        """
    }

    @Test func parsesProcessesAndTheirConnections() {
        let flows = AppTraffic.parse(Self.csv(chrome: (100, 10), vpn: (50, 5)))
        #expect(flows.count == 3)
        #expect(flows[0].pid == 4711 && flows[0].name == "Google Chrome He" && flows[0].interface == "en0")
        #expect(flows[1].interface == "utun4" && flows[1].bytesIn == 50)
        // Listening sockets without counters are no connections.
        #expect(!flows.contains { $0.pid == 88 })
    }

    @Test func ratesAreSplitIntoVPNAndDirectAndLoopbackIsIgnored() {
        var traffic = AppTraffic()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = traffic.rates(
            AppTraffic.parse(Self.csv(chrome: (100, 10), vpn: (50, 5))), vpnInterfaces: ["utun4"], at: start)
        // No rate yet, but what the open connections carried so far counts for totals.
        #expect(first.first?.use == NetworkUse())
        #expect(first.first?.bytes == NetworkUse(vpnIn: 50, vpnOut: 5, directIn: 100, directOut: 10))
        let uses = traffic.rates(
            AppTraffic.parse(Self.csv(chrome: (2_100, 210), vpn: (4_050, 405))), vpnInterfaces: ["utun4"],
            at: start + 2)
        #expect(uses.count == 1)
        #expect(uses[0].bytes.directIn == 2_000 && uses[0].bytes.vpnIn == 4_000)
        let use = uses[0].use
        #expect(use.directIn == 1_000 && use.directOut == 100)
        #expect(use.vpnIn == 2_000 && use.vpnOut == 200)
        #expect(use.total(.vpn) == 2_200 && use.download(.all) == 3_000)
    }

    @Test func aNewConnectionCountsWithEverythingItCarried() {
        var traffic = AppTraffic()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        traffic.rates([], vpnInterfaces: [], at: start)
        let uses = traffic.rates(
            AppTraffic.parse(Self.csv(chrome: (400, 40), vpn: (0, 0))), vpnInterfaces: [], at: start + 4)
        #expect(uses.first?.use.directIn == 100)
    }

    @Test func tunnelsAreRecognisedByName() {
        #expect(AppTraffic.isTunnel("utun3") && AppTraffic.isTunnel("ipsec0") && AppTraffic.isTunnel("ppp0"))
        #expect(!AppTraffic.isTunnel("en0") && !AppTraffic.isTunnel("bridge0"))
    }

    @Test func nettopRunsWithoutPermission() throws {
        let flows = try #require(AppTraffic.read())
        // This test process has no connections, but the system always has some.
        #expect(!flows.isEmpty)
    }
}

@Suite struct AlertCulpritTests {
    /// Real processes: the busiest one by memory is found, never MacHorus' own
    /// process (here: the test runner).
    @Test func theCulpritIsAnotherProcess() throws {
        let culprit = try #require(AlertCulprit.find(by: .memory))
        #expect(culprit.identity.pid != getpid())
        #expect(culprit.memory > 0)
    }
}

@Suite struct VPNStatusTests {
    @Test func connectedServicesAreReadFromScutil() {
        let output = """
            Available network connection services in the current set (*=enabled):
            * (Disconnected)   6C40 VPN (io.tailscale.ipn.macos) "Tailscale"   [VPN:io.tailscale.ipn.macos]
            * (Connected)      7A11 PPP --> L2TP "Office VPN"                  [PPP:L2TP]
            """
        #expect(VPNStatus.connectedServices(fromList: output) == ["Office VPN"])
    }

    @Test func commonClientsAreRecognisedByProcessName() {
        #expect(VPNStatus.isClient("OpenVPN Connect"))
        #expect(VPNStatus.isClient("IPNExtension"))
        #expect(!VPNStatus.isClient("Google Chrome He"))
    }
}
