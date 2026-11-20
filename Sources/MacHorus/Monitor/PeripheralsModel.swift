// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusMonitor
import Observation

/// Batteries of keyboard, mouse and trackpad, and the Wi-Fi link quality.
/// Read only while the panel shows them, never in the background.
@MainActor
@Observable
final class PeripheralsModel {
    private(set) var accessories: [AccessoryBattery] = []
    private(set) var wifi: WiFiQuality?

    @ObservationIgnored private var accessoriesRead: Date?

    /// The overview appeared: accessories at most once a minute (they change
    /// slowly), Wi-Fi every time.
    func refresh() {
        refreshAccessories(maxAge: 60)
        refreshWiFi()
    }

    /// Accessory batteries if the last read is older than `maxAge` seconds
    /// (the devices card asks more often: a receiver can be unplugged).
    func refreshAccessories(maxAge: TimeInterval) {
        if accessoriesRead.map({ Date().timeIntervalSince($0) >= maxAge }) ?? true {
            accessoriesRead = Date()
            Task {
                let read = await OffMain.run { AccessoryBatteries.read() }
                if read != accessories { accessories = read }
            }
        }
    }

    /// One CoreWLAN read takes about 7 ms (measured): off the main thread.
    func refreshWiFi() {
        guard !isReadingWiFi else { return }
        isReadingWiFi = true
        Task {
            let read = await OffMain.run { WiFiQuality.read() }
            isReadingWiFi = false
            if read != wifi { wifi = read }
        }
    }

    @ObservationIgnored private var isReadingWiFi = false
}

enum PeripheralTexts {
    static func name(_ kind: AccessoryBattery.Kind) -> String {
        switch kind {
        case .keyboard: String(localized: "accessory.keyboard")
        case .mouse: String(localized: "accessory.mouse")
        case .trackpad: String(localized: "accessory.trackpad")
        case .other: String(localized: "accessory.other")
        }
    }

    static func level(_ level: WiFiQuality.Level) -> String {
        switch level {
        case .good: String(localized: "monitor.network.wifi.good")
        case .fair: String(localized: "monitor.network.wifi.fair")
        case .weak: String(localized: "monitor.network.wifi.weak")
        }
    }

    /// "400 Mbit/s · 5 GHz · Kanal 48"
    static func link(_ wifi: WiFiQuality) -> String {
        var parts = ["\(Int(wifi.rateMbps.rounded())) Mbit/s"]
        if let band = wifi.bandGHz {
            parts.append(band == 2.4 ? "2,4 GHz" : "\(Int(band)) GHz")
        }
        if let channel = wifi.channel {
            parts.append(
                Bundle.main.localizedString(forKey: "monitor.network.wifi.channel %@", value: nil, table: nil)
                    .replacingOccurrences(of: "%@", with: String(channel)))
        }
        return parts.joined(separator: " · ")
    }
}
