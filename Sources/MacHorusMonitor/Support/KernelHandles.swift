// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import IOKit

/// Send right to the host port. `mach_host_self()` adds a reference on every
/// call, so a long-running sampler takes it once and releases it on deinit
/// (Vorssaint leaked one per sample before 2.10.0).
final class HostPort {
    let port: mach_port_t

    init() {
        port = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, port)
    }
}

/// Owns an IOKit object and releases it exactly once.
final class IOObject {
    let object: io_object_t

    init?(_ object: io_object_t) {
        guard object != IO_OBJECT_NULL else { return nil }
        self.object = object
    }

    deinit {
        IOObjectRelease(object)
    }
}

/// Reads a sysctl value of fixed size, e.g. `hw.memsize`.
func sysctlValue<Value>(_ name: String, as _: Value.Type = Value.self) -> Value? {
    var size = MemoryLayout<Value>.size
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Value>.alignment)
    defer { pointer.deallocate() }
    guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<Value>.size else { return nil }
    return pointer.load(as: Value.self)
}
