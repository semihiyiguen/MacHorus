// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Independent SMC reader for scripts/dev/verify-monitor.py --thermal. It
// shares no code with the app on purpose: the app reads temperatures from
// the HID sensors, this reads the SMC, a separate firmware path.
// Usage: smc-reference <seconds> <key>...   prints one line per second:
//   time=<epoch> <key>=<value> ...   (keys that do not exist print "-")

import Foundation
import IOKit

struct Parameters {
    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var limit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0
    var padding: UInt16 = 0, result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0, data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}
precondition(MemoryLayout<Parameters>.stride == 80, "AppleSMC expects 80 bytes")

var connection: io_connect_t = 0
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
    FileHandle.standardError.write(Data("AppleSMC not available\n".utf8))
    exit(1)
}

func call(_ input: inout Parameters) -> Parameters? {
    var output = Parameters()
    var size = MemoryLayout<Parameters>.stride
    let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Parameters>.stride, &output, &size)
    return result == kIOReturnSuccess && output.result == 0 ? output : nil
}

func read(_ name: String) -> String {
    var info = Parameters()
    info.key = name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    info.command = 9
    guard let described = call(&info) else { return "-" }
    var request = Parameters()
    request.key = info.key
    request.size = described.size
    request.command = 5
    guard let answer = call(&request) else { return "-" }
    let bytes = withUnsafeBytes(of: answer.bytes) { Array($0.prefix(Int(described.size))) }
    let type = String(decoding: [24, 16, 8, 0].map { UInt8((described.type >> $0) & 0xff) }, as: UTF8.self)
    switch type {
    case "flt " where bytes.count == 4:
        var value: Float = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }  // little-endian
        return String(format: "%.2f", value)
    default:
        return "-"
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let seconds = arguments.first.flatMap(Int.init), arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: smc-reference <seconds> <key>...\n".utf8))
    exit(2)
}
for _ in 0..<seconds {
    let values = arguments.dropFirst().map { "\($0)=\(read($0))" }
    print(String(format: "time=%.3f ", Date().timeIntervalSince1970) + values.joined(separator: " "))
    fflush(stdout)
    Thread.sleep(forTimeInterval: 1)
}
