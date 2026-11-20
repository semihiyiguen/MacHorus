// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreWLAN
import Foundation

/// How good the Wi-Fi link is: signal, noise and rate, without the network
/// name (that needs the location permission). Read on request only.
public struct WiFiQuality: Equatable, Sendable {
    public enum Level: Sendable {
        case good
        case fair
        case weak
    }

    public let interface: String
    /// Signal strength in dBm (e.g. -52).
    public let rssi: Int
    public let noise: Int
    /// Current transmit rate in Mbit/s.
    public let rateMbps: Double
    /// 2.4, 5 or 6 (GHz); nil if unknown.
    public let bandGHz: Double?
    public let channel: Int?

    public init(interface: String, rssi: Int, noise: Int, rateMbps: Double, bandGHz: Double?, channel: Int?) {
        self.interface = interface
        self.rssi = rssi
        self.noise = noise
        self.rateMbps = rateMbps
        self.bandGHz = bandGHz
        self.channel = channel
    }

    /// Usual thresholds: from -60 dBm good, from -70 dBm usable, below weak.
    public var level: Level {
        switch rssi {
        case (-60)...: .good
        case (-70)...: .fair
        default: .weak
        }
    }

    /// Nil when Wi-Fi is off or not connected (no signal reading).
    public static func read() -> WiFiQuality? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi < 0 else { return nil }
        let band: Double? =
            switch interface.wlanChannel()?.channelBand {
            case .band2GHz: 2.4
            case .band5GHz: 5
            case .band6GHz: 6
            default: nil
            }
        return WiFiQuality(
            interface: interface.interfaceName ?? "en0", rssi: rssi, noise: interface.noiseMeasurement(),
            rateMbps: interface.transmitRate(), bandGHz: band, channel: interface.wlanChannel()?.channelNumber)
    }
}
