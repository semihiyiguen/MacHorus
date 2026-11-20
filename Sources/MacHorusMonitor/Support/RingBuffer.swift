// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

/// Fixed-capacity history: appending never allocates once full and the
/// oldest value is dropped (Vorssaint used Array.removeFirst, which is O(n)).
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: ContiguousArray<Element>
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer needs a positive capacity")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest first.
    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }
}
