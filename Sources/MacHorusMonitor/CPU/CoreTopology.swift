// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import IOKit

/// Which logical CPU is a performance or an efficiency core, read once from
/// the device tree (`IODeviceTree:/cpus/cpuN`, keys `logical-cpu-id` and
/// `cluster-type`). If anything is inconsistent, all cores are `.unknown`.
enum CoreTopology {
    static func kinds() -> [CoreKind] {
        let count = sysctlValue("hw.ncpu", as: Int32.self).map(Int.init) ?? 0
        guard count > 0 else { return [] }
        var kinds = [CoreKind](repeating: .unknown, count: count)
        guard let cpus = IOObject(IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")) else {
            return kinds
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus.object, kIODeviceTreePlane, &iterator) == KERN_SUCCESS,
            let children = IOObject(iterator)
        else { return kinds }
        while let child = IOObject(IOIteratorNext(children.object)) {
            guard let id = integer(child, "logical-cpu-id"), (0..<count).contains(id),
                let cluster = string(child, "cluster-type")
            else { continue }
            switch cluster {
            case "P": kinds[id] = .performance
            case "E": kinds[id] = .efficiency
            default: break
            }
        }
        // Must agree with the kernel's own counts, otherwise show no labels.
        let performance = sysctlValue("hw.perflevel0.logicalcpu", as: Int32.self).map(Int.init)
        let efficiency = sysctlValue("hw.perflevel1.logicalcpu", as: Int32.self).map(Int.init)
        let found = (kinds.filter { $0 == .performance }.count, kinds.filter { $0 == .efficiency }.count)
        guard found.0 == performance, found.1 == efficiency ?? 0 else {
            return [CoreKind](repeating: .unknown, count: count)
        }
        return kinds
    }

    private static func property(_ entry: IOObject, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry.object, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func integer(_ entry: IOObject, _ key: String) -> Int? {
        switch property(entry, key) {
        case let number as NSNumber: return number.intValue
        case let data as Data where data.count >= 4:
            return Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        default: return nil
        }
    }

    private static func string(_ entry: IOObject, _ key: String) -> String? {
        switch property(entry, key) {
        case let text as String: return text
        case let data as Data:
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default: return nil
        }
    }
}
