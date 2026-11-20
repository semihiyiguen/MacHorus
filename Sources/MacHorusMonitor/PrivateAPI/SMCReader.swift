// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// The AppleSMC user-client layout (80-byte parameter block, selector 2,
// commands 5 and 9) is the same one Vorssaint's SMCClient uses
// (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint).

import Foundation
import IOKit

/// Read-only access to the System Management Controller. There is no write
/// path at all: fan control is out of scope.
///
/// Private interface: the AppleSMC protocol is undocumented. It needs no
/// permission. Disabled by the policy (`DisabledPrivateAPIs` = `SMC`), the
/// caller simply shows no fan data.
final class SMCReader {
    private struct KeyInfo {
        let size: UInt32
        let type: String
    }

    private let connection: io_connect_t
    private var keyInfo: [String: KeyInfo?] = [:]

    private static let selector: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// The key's value as a number, or nil if the key does not exist or
    /// has a type this reader does not decode.
    func value(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        var input = Parameters()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.size
        input.command = Self.readKey
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return SMCValue.decode(bytes, type: info.type)
    }

    private func info(_ key: String) -> KeyInfo? {
        if let cached = keyInfo[key] { return cached }
        var input = Parameters()
        input.key = Self.code(key)
        input.command = Self.readKeyInfo
        let info = call(&input).flatMap { output -> KeyInfo? in
            let size = output.keyInfo.dataSize
            guard size > 0, size <= 32 else { return nil }
            return KeyInfo(size: size, type: Self.string(output.keyInfo.dataType))
        }
        keyInfo[key] = info
        return info
    }

    private func call(_ input: inout Parameters) -> Parameters? {
        var output = Parameters()
        var size = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.selector, &input, MemoryLayout<Parameters>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
    }

    /// Wire format of the AppleSMC user client (80 bytes).
    private struct Parameters {
        struct Version {
            var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        struct PowerLimit {
            var version: UInt16 = 0, length: UInt16 = 0
            var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
        }
        struct KeyInfo {
            var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
        }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
}

/// SMC value encodings that occur on Apple Silicon.
enum SMCValue {
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            // Little-endian IEEE float.
            return Double(Float(bitPattern: bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
        case "ioft" where bytes.count == 8:
            // Little-endian 48.16 fixed point.
            return Double(Int64(bitPattern: bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })) / 65_536
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ", "ui16", "ui32":
            guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }
}
