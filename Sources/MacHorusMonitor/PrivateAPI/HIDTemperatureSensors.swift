// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// Temperature sensors of the Apple Silicon chip, read through the HID
/// event system, the same way the system's thermal management sees them.
/// Each sensor has a descriptive name (e.g. `pACC MTR Temp Sensor2` for a
/// sensor in the performance cores), so no per-chip key tables are needed.
///
/// Private interface: `IOHIDEventSystemClient` has no public header on
/// macOS. Loaded with dlopen; if a symbol is missing or the policy disables
/// it (`DisabledPrivateAPIs` = `HIDSensors`), `init` returns nil and no
/// temperatures are shown. Needs no permission.
final class HIDTemperatureSensors {
    private typealias CreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFunction = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFunction = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFunction = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyPropertyFunction = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias FloatValueFunction = @convention(c) (AnyObject, Int32) -> Double

    /// kIOHIDEventTypeTemperature and its level field.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let client: AnyObject
    private let sensors: [(name: String, service: AnyObject)]
    private let copyEvent: CopyEventFunction
    private let floatValue: FloatValueFunction

    /// `include` picks the sensors by name once; only those are read later.
    init?(include: (String) -> Bool) {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func function<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = function("IOHIDEventSystemClientCreate", CreateFunction.self),
            let setMatching = function("IOHIDEventSystemClientSetMatching", SetMatchingFunction.self),
            let copyServices = function("IOHIDEventSystemClientCopyServices", CopyServicesFunction.self),
            let copyEvent = function("IOHIDServiceClientCopyEvent", CopyEventFunction.self),
            let copyProperty = function("IOHIDServiceClientCopyProperty", CopyPropertyFunction.self),
            let floatValue = function("IOHIDEventGetFloatValue", FloatValueFunction.self),
            let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // Vendor page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        sensors = services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                include(name)
            else { return nil }
            return (name, service)
        }
        self.client = client
        self.copyEvent = copyEvent
        self.floatValue = floatValue
    }

    var names: [String] { sensors.map(\.name) }

    /// Current value of every included sensor in °C. A sensor without an
    /// event (e.g. powered down) is left out.
    func read() -> [(name: String, celsius: Double)] {
        sensors.compactMap { sensor in
            guard let event = copyEvent(sensor.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else {
                return nil
            }
            return (sensor.name, floatValue(event, Self.temperatureField))
        }
    }
}
