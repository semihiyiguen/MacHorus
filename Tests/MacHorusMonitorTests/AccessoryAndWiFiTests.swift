// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Testing

@testable import MacHorusMonitor

@Suite struct AccessoryAndWiFiTests {
    private let calm = RestartAdvice(level: .none, reasons: [])

    @Test func appleProductIDsNameTheKind() {
        #expect(AccessoryBatteries.kind(vendor: 0x004C, product: 0x0267) == .keyboard)
        #expect(AccessoryBatteries.kind(vendor: 0x05AC, product: 0x0269) == .mouse)
        #expect(AccessoryBatteries.kind(vendor: 0x004C, product: 0x0265) == .trackpad)
        #expect(AccessoryBatteries.kind(vendor: 0x004C, product: 0x9999) == .other)
        #expect(AccessoryBatteries.kind(vendor: 0x046D, product: 0x0267) == .other, "not Apple: no guess")
    }

    @Test func lowAccessoryBatteriesBecomePoints() {
        let items = StatusSummary.items(
            restart: calm, disk: nil, battery: nil, thermal: nil, alerts: [], updates: nil,
            accessories: [
                AccessoryBattery(kind: .mouse, percent: 4), AccessoryBattery(kind: .keyboard, percent: 12),
                AccessoryBattery(kind: .trackpad, percent: 60),
            ])
        #expect(items.map(\.severity) == [.critical, .warning])
        #expect(items.first?.kind == .accessoryBattery(AccessoryBattery(kind: .mouse, percent: 4)))
    }

    @Test func weakWiFiCountsOnlyWhenItCarriesTheTraffic() {
        let weak = WiFiQuality(interface: "en0", rssi: -80, noise: -92, rateMbps: 24, bandGHz: 2.4, channel: 6)
        #expect(weak.level == .weak)
        let onCable = StatusSummary.items(
            restart: calm, disk: nil, battery: nil, thermal: nil, alerts: [], updates: nil, wifi: weak,
            wifiIsPrimary: false)
        #expect(onCable.isEmpty)
        let onWiFi = StatusSummary.items(
            restart: calm, disk: nil, battery: nil, thermal: nil, alerts: [], updates: nil, wifi: weak,
            wifiIsPrimary: true)
        #expect(onWiFi.map(\.kind) == [.weakWiFi(rssi: -80)])
    }

    @Test func signalLevels() {
        func level(_ rssi: Int) -> WiFiQuality.Level {
            WiFiQuality(interface: "en0", rssi: rssi, noise: -90, rateMbps: 1, bandGHz: nil, channel: nil).level
        }
        #expect(level(-52) == .good)
        #expect(level(-60) == .good)
        #expect(level(-65) == .fair)
        #expect(level(-70) == .fair)
        #expect(level(-71) == .weak)
    }
}
