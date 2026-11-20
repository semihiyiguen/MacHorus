// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Dispatch
import Foundation
import os

/// Total bytes received and sent over physical interfaces (Wi-Fi, wired,
/// cellular), summed over all TCP and UDP connections.
///
/// Why: network filters and VPN clients (seen: ESET, OpenVPN Connect)
/// re-inject traffic, so interface counters stay at zero for incoming data,
/// and per-connection totals count proxied data twice. Counting only the
/// physical-interface bytes per connection matches
/// `nettop -t wifi -t wired` exactly (docs/MEASUREMENTS.md).
///
/// Private interface: NetworkStatistics.framework (the one nettop and
/// Activity Monitor use). Loaded with dlopen; if a symbol is missing or the
/// policy disables it (`DisabledPrivateAPIs`), `init` returns nil and the
/// caller falls back to interface counters. Only byte counters are read;
/// process names and addresses in the dictionaries are never looked at.
final class NetworkStatisticsAdapter: Sendable {
    struct Totals: Sendable, Equatable {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var uptime: TimeInterval = 0
    }

    private typealias SourceBlock = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias CountsBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void
    private typealias CreateFunction =
        @convention(c) (CFAllocator?, UnsafeMutableRawPointer, @escaping SourceBlock) -> UnsafeMutableRawPointer?
    private typealias AddAllFunction = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt64) -> Int32
    private typealias SetCountsFunction = @convention(c) (UnsafeMutableRawPointer, @escaping CountsBlock) -> Void
    private typealias SetBlockFunction = @convention(c) (UnsafeMutableRawPointer, @escaping VoidBlock) -> Void
    private typealias IdentifierFunction = @convention(c) (UnsafeMutableRawPointer) -> UInt64
    private typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct State {
        /// Last physical counts per connection, keyed by the framework's id.
        var connections: [UInt64: (received: UInt64, sent: UInt64)] = [:]
        /// Sum of all count increases, including closed connections.
        var running = Totals()
    }

    /// One lock (macOS 13+, unlike Mutex) the closures share through this box.
    private final class StateBox: Sendable {
        let mutex = OSAllocatedUnfairLock(initialState: State())
    }

    /// Lets exactly one of the query completion and the timeout through.
    private final class Once: Sendable {
        private let used = OSAllocatedUnfairLock(initialState: false)

        func claim() -> Bool {
            used.withLock { used in
                defer { used = true }
                return !used
            }
        }
    }

    private final class ResultBox: Sendable {
        let value = OSAllocatedUnfairLock<Totals?>(initialState: nil)
    }

    /// The framework's opaque manager handle; only used on `queue`. Blocks
    /// on `queue` never capture `self`, so `deinit` never runs there.
    private struct Handle: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
    }

    private let queue = DispatchQueue(label: "app.machorus.monitor.networkstatistics", qos: .utility)
    private let state = StateBox()
    private let manager: Handle
    private let queryAll: SetBlockFunction
    private let destroy: DestroyFunction

    init?() {
        let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func function<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        func key(_ name: String) -> CFString? {
            dlsym(handle, name).map { $0.assumingMemoryBound(to: CFString.self).pointee }
        }
        guard let create = function("NStatManagerCreate", CreateFunction.self),
            let addTCP = function("NStatManagerAddAllTCPWithFilter", AddAllFunction.self),
            let addUDP = function("NStatManagerAddAllUDPWithFilter", AddAllFunction.self),
            let setCounts = function("NStatSourceSetCountsBlock", SetCountsFunction.self),
            let setRemoved = function("NStatSourceSetRemovedBlock", SetBlockFunction.self),
            let identifier = function("NStatSourceIdentifier", IdentifierFunction.self),
            let queryAll = function("NStatManagerQueryAllSources", SetBlockFunction.self),
            let destroy = function("NStatManagerDestroy", DestroyFunction.self),
            let receivedKeys = [
                "kNStatSrcKeyRxWiFiBytes", "kNStatSrcKeyRxWiredBytes", "kNStatSrcKeyRxCellularBytes",
            ].map(key) as [CFString?]?, !receivedKeys.contains(nil),
            let sentKeys = [
                "kNStatSrcKeyTxWiFiBytes", "kNStatSrcKeyTxWiredBytes", "kNStatSrcKeyTxCellularBytes",
            ].map(key) as [CFString?]?, !sentKeys.contains(nil)
        else {
            dlclose(handle)
            return nil
        }
        let received = receivedKeys.compactMap { $0 }
        let sent = sentKeys.compactMap { $0 }
        let state = self.state
        let sourceAdded: SourceBlock = { source, _ in
            guard let source else { return }
            let id = identifier(source)
            setRemoved(source) { state.mutex.withLock { _ = $0.connections.removeValue(forKey: id) } }
            setCounts(source) { counts in
                guard let counts else { return }
                // Six lookups instead of bridging all ~40 entries per connection.
                let now = (received: Self.sum(received, in: counts), sent: Self.sum(sent, in: counts))
                state.mutex.withLock { state in
                    let before = state.connections[id] ?? (0, 0)
                    // A smaller value means a new connection reused the id.
                    state.running.received +=
                        now.received >= before.received ? now.received - before.received : now.received
                    state.running.sent += now.sent >= before.sent ? now.sent - before.sent : now.sent
                    state.connections[id] = now
                }
            }
        }
        guard let manager = create(nil, Unmanaged.passUnretained(queue).toOpaque(), sourceAdded) else {
            dlclose(handle)
            return nil
        }
        _ = addTCP(manager, 0, 0)
        _ = addUDP(manager, 0, 0)
        self.manager = Handle(pointer: manager)
        self.queryAll = queryAll
        self.destroy = destroy
    }

    private static func sum(_ keys: [CFString], in counts: CFDictionary) -> UInt64 {
        keys.reduce(UInt64(0)) { total, key in
            guard let raw = CFDictionaryGetValue(counts, Unmanaged.passUnretained(key).toOpaque()) else { return total }
            let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return total }
            var number: Int64 = 0
            guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &number), number > 0 else {
                return total
            }
            return total + UInt64(number)
        }
    }

    deinit {
        let manager = self.manager
        let destroy = self.destroy
        // The framework calls back on our queue; tear down there.
        queue.sync { destroy(manager.pointer) }
    }

    /// Asks every connection for its counts and calls `completion` once:
    /// with the totals when the answer is complete, or with nil after
    /// `timeout` (the framework never answering must not stall sampling).
    func query(timeout: TimeInterval, completion: @escaping @Sendable (Totals?) -> Void) {
        let state = self.state
        let once = Once()
        queue.async { [manager, queryAll] in
            queryAll(manager.pointer) {
                let totals = state.mutex.withLock { state in
                    state.running.uptime = ProcessInfo.processInfo.systemUptime
                    return state.running
                }
                if once.claim() { completion(totals) }
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if once.claim() { completion(nil) }
        }
    }

    func refresh(timeout: TimeInterval = 1) async -> Totals? {
        await withCheckedContinuation { continuation in
            query(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Blocking variant for the command-line probe and tests.
    func refreshWaiting(timeout: TimeInterval = 1) -> Totals? {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        query(timeout: timeout) { totals in
            result.value.withLock { $0 = totals }
            done.signal()
        }
        done.wait()
        return result.value.withLock { $0 }
    }
}
