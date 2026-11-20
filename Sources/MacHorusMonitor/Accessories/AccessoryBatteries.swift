// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit

/// Battery of a keyboard, mouse or trackpad, as the I/O Registry reports
/// it for connected Apple accessories. Read-only, no Bluetooth permission
/// (the name is not read; the kind comes from the product ID).
public struct AccessoryBattery: Equatable, Sendable {
    public enum Kind: Sendable {
        case keyboard
        case mouse
        case trackpad
        case other
    }

    public let kind: Kind
    public let percent: Int
    /// How it is connected, as macOS reports it ("Bluetooth", "USB" …).
    public let transport: String?

    public init(kind: Kind, percent: Int, transport: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.transport = transport
    }

    public var isBluetooth: Bool { transport?.localizedCaseInsensitiveContains("bluetooth") == true }
}

public enum AccessoryBatteries {
    /// Apple product IDs (Bluetooth vendor 0x004C, USB vendor 0x05AC).
    static let keyboards: Set<Int> = [0x0255, 0x0256, 0x0267, 0x026C, 0x029A, 0x029C, 0x029F, 0x0320, 0x0321, 0x0322]
    static let mice: Set<Int> = [0x030D, 0x0269, 0x0323]
    static let trackpads: Set<Int> = [0x0265, 0x0314, 0x0324]

    static func kind(vendor: Int?, product: Int?) -> AccessoryBattery.Kind {
        guard let vendor, vendor == 0x004C || vendor == 0x05AC, let product else { return .other }
        if keyboards.contains(product) { return .keyboard }
        if mice.contains(product) { return .mouse }
        if trackpads.contains(product) { return .trackpad }
        return .other
    }

    /// Connected accessories with a battery, lowest charge first.
    public static func read() -> [AccessoryBattery] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var batteries: [AccessoryBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue
            }
            guard let percent = number("BatteryPercent"), (0...100).contains(percent) else { continue }
            let transport =
                IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            batteries.append(
                AccessoryBattery(
                    kind: kind(vendor: number("VendorID"), product: number("ProductID")), percent: percent,
                    transport: transport))
        }
        return batteries.sorted { $0.percent < $1.percent }
    }
}
