// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CAtomics

/// Lock-free values shared with the audio render thread (relaxed order is
/// enough: each value stands alone). Works on macOS 14, unlike
/// Synchronization.Atomic; allocated once, before the thread starts.
final class AtomicUInt32: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(_ value: UInt32) { pointer = catomic_u32_create(value)! }
    deinit { catomic_u32_destroy(pointer) }

    func load() -> UInt32 { catomic_u32_load(pointer) }
    func store(_ value: UInt32) { catomic_u32_store(pointer, value) }
}

final class AtomicUInt64: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(_ value: UInt64) { pointer = catomic_u64_create(value)! }
    deinit { catomic_u64_destroy(pointer) }

    func load() -> UInt64 { catomic_u64_load(pointer) }
    func add(_ value: UInt64) { catomic_u64_add(pointer, value) }
}

final class AtomicFlag: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(_ value: Bool) { pointer = catomic_bool_create(value)! }
    deinit { catomic_bool_destroy(pointer) }

    /// Sets the flag and returns what it was.
    func exchange(_ value: Bool) -> Bool { catomic_bool_exchange(pointer, value) }
}
