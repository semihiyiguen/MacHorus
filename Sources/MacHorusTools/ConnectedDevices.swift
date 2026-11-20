// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit
import IOKit.ps

/// External drives and connected hardware, read on request. Every read is
/// optional: a value that cannot be read leaves its line out, it never
/// fails the card (docks, adapters and drivers report very differently).
public enum ConnectedDevices {
    public struct Drive: Equatable, Sendable, Identifiable {
        public let url: URL
        public let name: String
        public let totalBytes: Int64?
        public let freeBytes: Int64?
        /// Can be ejected (USB sticks, SD cards, external disks, disk images).
        public let isEjectable: Bool
        public var id: URL { url }
    }

    public struct USBDevice: Equatable, Sendable {
        public let name: String
        public let vendor: String?
        /// A hub: on its own, part of a dock or display.
        public let isHub: Bool
    }

    public struct PowerAdapter: Equatable, Sendable {
        public let watts: Int?
        public let name: String?
    }

    // MARK: Drives

    static let driveKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeIsRootFileSystemKey,
    ]

    /// Mounted local volumes that are not the Mac's own disk: what Finder
    /// shows under "Locations" with an eject button. Blocking: off main.
    public static func externalDrives() -> [Drive] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: driveKeys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Drive? in
            guard let values = try? url.resourceValues(forKeys: Set(driveKeys)) else { return nil }
            return drive(url: url, values: values)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func drive(url: URL, values: URLResourceValues) -> Drive? {
        guard values.volumeIsBrowsable != false, values.volumeIsRootFileSystem != true, values.volumeIsLocal != false,
            !url.path.hasPrefix("/System/Volumes")
        else { return nil }
        let ejectable = values.volumeIsEjectable == true || values.volumeIsRemovable == true
        // The Mac's own disks (and their data volumes) stay out of the list.
        guard ejectable || values.volumeIsInternal == false else { return nil }
        return Drive(
            url: url, name: values.volumeName ?? url.lastPathComponent,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            freeBytes: values.volumeAvailableCapacity.map(Int64.init), isEjectable: true)
    }

    // MARK: USB

    /// USB devices with a product name; the Mac's own internal ones (built
    /// into the case) are left out. Blocking (IORegistry): off main.
    public static func usbDevices() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [USBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            guard let name = property("USB Product Name") as? String, !name.isEmpty else { continue }
            if (property("Built-In") as? Bool) == true { continue }
            let vendor = (property("USB Vendor Name") as? String) ?? (property("kUSBVendorString") as? String)
            let deviceClass = property("bDeviceClass") as? Int
            // A billboard (class 17) only announces a USB-C display mode.
            if deviceClass == 17 { continue }
            let isHub = deviceClass == 9
            devices.append(USBDevice(name: name, vendor: vendor, isHub: isHub))
        }
        return devices
    }

    // MARK: Power

    /// The connected power adapter (watts and name as it reports them).
    public static func powerAdapter() -> PowerAdapter? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let watts = details[kIOPSPowerAdapterWattsKey] as? Int
        let name = details["Name"] as? String
        guard watts != nil || name != nil else { return nil }
        return PowerAdapter(watts: watts, name: name)
    }
}
