// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin
import Foundation

/// A process as it was when sampled. Actions check it again first, so a
/// recycled PID never hits another process.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    /// Start time in Mach absolute time (`ri_proc_start_abstime`).
    public let started: UInt64

    public init(pid: pid_t, started: UInt64) {
        self.pid = pid
        self.started = started
    }
}

/// One row: an app with its helper processes, or a single process.
public struct ProcessUsage: Equatable, Sendable, Identifiable {
    public let identity: ProcessIdentity
    /// Kernel name of the responsible process; the app layer prefers the
    /// app's own name.
    public let name: String
    /// Share of one core, like Activity Monitor and top (1 = 100 %).
    public let cpu: Double
    /// Physical footprint in bytes (Activity Monitor's "Memory" column).
    public let memory: UInt64
    /// Processes summed in this row.
    public let processCount: Int
    /// CPU time all its processes used since they started, in seconds.
    public let cpuSeconds: Double
    /// The highest memory each of its processes ever reached, summed.
    public let peakMemory: UInt64

    public var id: ProcessIdentity { identity }

    public init(
        identity: ProcessIdentity, name: String, cpu: Double, memory: UInt64, processCount: Int,
        cpuSeconds: Double = 0, peakMemory: UInt64 = 0
    ) {
        self.identity = identity
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.processCount = processCount
        self.cpuSeconds = cpuSeconds
        self.peakMemory = peakMemory
    }
}

public enum ProcessOrder: String, Sendable, CaseIterable {
    case cpu
    case memory
    /// Network rate per app; the rows come from `AppTraffic`, not from here.
    case network
}

public struct ProcessesSnapshot: Equatable, Sendable {
    /// Every row (apps with their helpers, single processes), named.
    public let rows: [ProcessUsage]
    /// Processes that were read.
    public let visibleCount: Int
    /// Processes of other users (system services) macOS does not let a
    /// normal app read (macOS 27).
    public let hiddenCount: Int
    /// The row each readable process counts towards (helpers → their app).
    public let owners: [pid_t: ProcessIdentity]

    public init(
        rows: [ProcessUsage], visibleCount: Int, hiddenCount: Int, owners: [pid_t: ProcessIdentity] = [:]
    ) {
        self.rows = rows
        self.visibleCount = visibleCount
        self.hiddenCount = hiddenCount
        self.owners = owners
    }

    /// The busiest rows that pass `matching`; rows without load are left
    /// out. Equal values keep a fixed order, so rows do not swap places.
    public func top(
        _ order: ProcessOrder, limit: Int, matching: (ProcessUsage) -> Bool = { _ in true }
    ) -> [ProcessUsage] {
        let value: (ProcessUsage) -> Double
        switch order {
        case .cpu: value = { $0.cpu }
        case .memory: value = { Double($0.memory) }
        case .network: return []
        }
        return ProcessMath.top(rows.filter(matching), by: value, limit: limit)
    }

    public var topCPU: [ProcessUsage] { top(.cpu, limit: ProcessSampler.limit) }
    public var topMemory: [ProcessUsage] { top(.memory, limit: ProcessSampler.limit) }
}

/// One process as read from libproc.
struct ProcessReading {
    let identity: ProcessIdentity
    /// User + system CPU time in nanoseconds.
    let cpuTime: UInt64
    let memory: UInt64
    var peakMemory: UInt64 = 0
}

enum ProcessMath {
    /// Rows for each owner: CPU from the time delta since the last reading of
    /// the same process (a new process has no rate yet), memory as now.
    static func rows(
        _ readings: [ProcessReading], previous: [ProcessIdentity: UInt64], elapsedNanoseconds: UInt64,
        owner: (ProcessIdentity) -> ProcessIdentity
    ) -> [ProcessUsage] {
        var groups: [ProcessIdentity: (cpu: Double, memory: UInt64, count: Int, time: UInt64, peak: UInt64)] = [:]
        for reading in readings {
            var cpu = 0.0
            if elapsedNanoseconds > 0, let before = previous[reading.identity], reading.cpuTime >= before {
                cpu = Double(reading.cpuTime - before) / Double(elapsedNanoseconds)
            }
            let key = owner(reading.identity)
            let sum = groups[key] ?? (0, 0, 0, 0, 0)
            groups[key] = (
                sum.cpu + cpu, sum.memory + reading.memory, sum.count + 1, sum.time &+ reading.cpuTime,
                sum.peak &+ max(reading.peakMemory, reading.memory)
            )
        }
        // Names are looked up later, only for the rows shown.
        return groups.map { key, sum in
            ProcessUsage(
                identity: key, name: "", cpu: sum.cpu, memory: sum.memory, processCount: sum.count,
                cpuSeconds: Double(sum.time) / 1_000_000_000, peakMemory: sum.peak)
        }
    }

    static func top(_ rows: [ProcessUsage], by value: (ProcessUsage) -> Double, limit: Int) -> [ProcessUsage] {
        let sorted = rows.filter { value($0) > 0 }.sorted {
            let (left, right) = (value($0), value($1))
            return left != right ? left > right : $0.identity.pid < $1.identity.pid
        }
        return Array(sorted.prefix(limit))
    }

    static func named(_ rows: [ProcessUsage], _ name: (ProcessIdentity) -> String) -> [ProcessUsage] {
        rows.map {
            ProcessUsage(
                identity: $0.identity, name: name($0.identity), cpu: $0.cpu, memory: $0.memory,
                processCount: $0.processCount, cpuSeconds: $0.cpuSeconds, peakMemory: $0.peakMemory)
        }
    }
}

/// Reads every process of this user with libproc: one list call and one
/// `proc_pid_rusage` per process (it also gives the start time), no
/// subprocess. The responsible app is looked up once per process.
public final class ProcessSampler {
    public static let limit = 5

    private let responsibility: ProcessResponsibility?
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var previousUptime: UInt64?
    /// Responsible PID per process; it does not change while it runs.
    private var owners: [ProcessIdentity: pid_t] = [:]
    /// Kernel name per process, read once (it does not change either).
    private var names: [ProcessIdentity: String] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(allowResponsibility: Bool = true) {
        responsibility = allowResponsibility ? ProcessResponsibility() : nil
    }

    func sample() -> ProcessesSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let (readings, hidden) = readAll()
        let byPID = Dictionary(readings.map { ($0.identity.pid, $0.identity) }, uniquingKeysWith: { first, _ in first })
        var current: [ProcessIdentity: pid_t] = [:]
        current.reserveCapacity(readings.count)
        for reading in readings {
            let identity = reading.identity
            current[identity] = owners[identity] ?? responsibility?.owner(of: identity.pid) ?? identity.pid
        }
        owners = current
        // Group under the responsible process only if it is readable too
        // (it belongs to this user); otherwise the process stands alone.
        let owner: (ProcessIdentity) -> ProcessIdentity = { identity in
            guard let pid = current[identity], let owner = byPID[pid] else { return identity }
            return owner
        }
        let rows = ProcessMath.rows(
            readings, previous: previous, elapsedNanoseconds: previousUptime.map { now - $0 } ?? 0, owner: owner)
        previous = Dictionary(readings.map { ($0.identity, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
        previousUptime = now
        // Every row is named so the list can be searched; only new
        // processes cost a lookup.
        var known: [ProcessIdentity: String] = [:]
        known.reserveCapacity(rows.count)
        let named = ProcessMath.named(rows) { identity in
            let name = names[identity] ?? ProcessInspector.name(of: identity.pid)
            known[identity] = name
            return name
        }
        names = known
        var ownerOf: [pid_t: ProcessIdentity] = [:]
        ownerOf.reserveCapacity(readings.count)
        for reading in readings { ownerOf[reading.identity.pid] = owner(reading.identity) }
        return ProcessesSnapshot(rows: named, visibleCount: readings.count, hiddenCount: hidden, owners: ownerOf)
    }

    /// Readable processes and the number macOS refused (other users).
    func readAll() -> ([ProcessReading], Int) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], 0) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return ([], 0) }
        var readings: [ProcessReading] = []
        readings.reserveCapacity(Int(count))
        var hidden = 0
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let usage = ProcessInspector.usage(of: pid) else {
                hidden += 1
                continue
            }
            // CPU times are Mach absolute time units on Apple Silicon.
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            let nanoseconds = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
            guard !nanoseconds.overflow, timebase.denom > 0 else { continue }
            readings.append(
                ProcessReading(
                    identity: ProcessIdentity(pid: pid, started: usage.ri_proc_start_abstime),
                    cpuTime: nanoseconds.partialValue / UInt64(timebase.denom), memory: usage.ri_phys_footprint,
                    peakMemory: usage.ri_lifetime_max_phys_footprint))
        }
        return (readings, hidden)
    }
}

/// Checks on a single process, used before acting on it.
public enum ProcessInspector {
    /// When the process started, from its start time in Mach units.
    public static func startDate(of identity: ProcessIdentity, now: Date = Date()) -> Date? {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let current = mach_absolute_time()
        guard identity.started > 0, identity.started <= current, timebase.denom > 0 else { return nil }
        let elapsed = (current - identity.started).multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !elapsed.overflow else { return nil }
        return now.addingTimeInterval(-Double(elapsed.partialValue / UInt64(timebase.denom)) / 1_000_000_000)
    }

    /// Nil for processes of other users: macOS refuses to describe them.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        usage(of: pid).map { ProcessIdentity(pid: pid, started: $0.ri_proc_start_abstime) }
    }

    static func usage(of pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage : nil
    }

    /// The process's owner, to refuse acting on another user's process.
    public static func userID(of pid: pid_t) -> uid_t? {
        bsdInfo(pid)?.pbi_uid
    }

    /// Processes whose end would log the user out.
    static let protectedNames: Set<String> = ["loginwindow", "launchd"]

    /// True only for a process of this user that is still the one sampled
    /// (same start time), not MacHorus itself and not protected.
    public static func canSignal(_ identity: ProcessIdentity) -> Bool {
        guard identity.pid > 1, identity.pid != getpid(), identity == Self.identity(of: identity.pid),
            userID(of: identity.pid) == getuid()
        else { return false }
        return !protectedNames.contains(name(of: identity.pid))
    }

    /// Checks again and sends the signal; false if refused or failed.
    @discardableResult
    public static func send(_ signal: Int32, to identity: ProcessIdentity) -> Bool {
        canSignal(identity) && kill(identity.pid, signal) == 0
    }

    public static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "\(pid)" }
        return NetworkSampler.string(fromNullTerminated: buffer)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}

/// The app behind an alert: the busiest row by CPU (two readings `interval`
/// apart) or by memory. Blocking for `interval`: call off the main thread.
public enum AlertCulprit {
    public static func find(by order: ProcessOrder, interval: TimeInterval = 1) -> ProcessUsage? {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        if order == .cpu { Thread.sleep(forTimeInterval: interval) }
        let snapshot = sampler.sample()
        // MacHorus itself is never the culprit it reports.
        let own = getpid()
        let rows = snapshot.rows.filter { $0.identity.pid != own }
        let filtered = ProcessesSnapshot(rows: rows, visibleCount: snapshot.visibleCount, hiddenCount: 0)
        return filtered.top(order == .memory ? .memory : .cpu, limit: 1).first
    }
}
