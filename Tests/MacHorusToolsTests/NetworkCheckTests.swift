// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Testing

@testable import MacHorusTools

@Suite struct NetworkCheckTests {
    private func check(
        _ connection: NetworkCheck.Outcome, _ router: NetworkCheck.Outcome, _ dns: NetworkCheck.Outcome,
        _ internet: NetworkCheck.Outcome, loginPage: Bool = false
    ) -> NetworkCheck {
        NetworkCheck(
            outcomes: [.connection: connection, .router: router, .dns: dns, .internet: internet], interface: "en0",
            address: "10.0.0.2", router: "10.0.0.1", vpnInterfaces: [], loginPageSuspected: loginPage)
    }

    private let ok = NetworkCheck.Outcome.passed(milliseconds: 5)

    @Test func theVerdictNamesTheFirstRealProblem() {
        #expect(check(ok, ok, ok, ok).verdict == .allGood)
        #expect(check(ok, .failed, ok, ok).verdict == .routerSilent, "many routers ignore pings")
        #expect(check(.failed, .skipped, .skipped, .skipped).verdict == .noConnection)
        #expect(check(ok, .failed, .failed, .failed).verdict == .noRouter)
        #expect(check(ok, ok, .failed, .failed).verdict == .noDNS)
        #expect(check(ok, ok, ok, .failed).verdict == .noInternet)
        #expect(check(ok, ok, ok, .failed, loginPage: true).verdict == .loginPage)
    }

    @Test func echoRequestsCarryAValidChecksum() {
        let packet = NetworkCheck.echoRequest(identifier: 0x1234, sequence: 1)
        #expect(packet[0] == 8)
        // A packet including its checksum sums to zero.
        #expect(NetworkCheck.internetChecksum(packet) == 0)
    }

    /// The loopback answers without leaving the Mac; proves ICMP works
    /// without administrator rights.
    @Test func pingWorksWithoutAdministratorRights() {
        #expect(NetworkCheck.ping("127.0.0.1") != nil)
    }
}
