// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CCups
import Foundation

/// The printers and the user's print jobs, through the printing system's
/// own library (no permission; cancelling works for the user's own jobs
/// only, like the system's print queue window).
public enum PrintQueue {
    public struct Printer: Equatable, Sendable, Identifiable {
        public let name: String
        public let displayName: String
        public let isStopped: Bool
        /// The printer's own reasons ("media-empty", "offline-report" …), as
        /// the system reports them; "none" is left out.
        public let reasons: [String]
        public var id: String { name }
    }

    public struct Job: Equatable, Sendable, Identifiable {
        public enum State: Sendable, Equatable {
            case pending
            case held
            case printing
            case stopped
        }

        public let id: Int32
        public let printer: String
        public let title: String
        public let state: State
        public let created: Date
        public let bytes: Int
    }

    /// A job that has not moved for this long counts as stuck.
    public static let stuckAfter: TimeInterval = 3 * 60

    public static func isStuck(_ job: Job, printers: [Printer], now: Date = Date()) -> Bool {
        if job.state == .stopped || job.state == .held { return true }
        if printers.first(where: { $0.name == job.printer })?.isStopped == true { return true }
        return now.timeIntervalSince(job.created) >= stuckAfter
    }

    /// Blocking (the print system may be slow): call off the main thread.
    public static func printers() -> [Printer] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests(&dests)
        guard count > 0, let dests else { return [] }
        defer { cupsFreeDests(count, dests) }
        return (0..<Int(count)).map { index in
            let dest = dests[index]
            let name = String(cString: dest.name)
            func option(_ key: String) -> String? {
                cupsGetOption(key, dest.num_options, dest.options).map { String(cString: $0) }
            }
            let reasons = (option("printer-state-reasons") ?? "").split(separator: ",").map(String.init)
                .filter { $0 != "none" }
            return Printer(
                name: name, displayName: option("printer-info").flatMap { $0.isEmpty ? nil : $0 } ?? name,
                isStopped: option("printer-state") == "5", reasons: reasons)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The user's unfinished jobs on every printer.
    public static func jobs() -> [Job] {
        var jobs: UnsafeMutablePointer<cups_job_t>?
        let count = cupsGetJobs2(nil, &jobs, nil, 1, CUPS_WHICHJOBS_ACTIVE)
        guard count > 0, let jobs else { return [] }
        defer { cupsFreeJobs(count, jobs) }
        return (0..<Int(count)).map { index in
            let job = jobs[index]
            return Job(
                id: job.id, printer: String(cString: job.dest), title: job.title.map { String(cString: $0) } ?? "",
                state: state(job.state), created: Date(timeIntervalSince1970: TimeInterval(job.creation_time)),
                bytes: Int(job.size) * 1_024)
        }
        .sorted { $0.created < $1.created }
    }

    /// Cancels one of the user's own jobs; false if refused.
    public static func cancel(_ job: Job) -> Bool {
        cupsCancelJob2(nil, job.printer, job.id, 0) == IPP_STATUS_OK
    }

    static func state(_ state: ipp_jstate_t) -> Job.State {
        switch state {
        case IPP_JSTATE_HELD: .held
        case IPP_JSTATE_PROCESSING: .printing
        case IPP_JSTATE_STOPPED: .stopped
        default: .pending
        }
    }
}
