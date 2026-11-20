// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import Testing

@testable import MacHorusTools

private func text(_ string: String) -> ClipContent {
    ClipContent(items: [[.init(type: "public.utf8-plain-text", data: Data(string.utf8))]])
}

private func blob(_ megabytes: Int, fill: UInt8) -> ClipContent {
    ClipContent(items: [[.init(type: "public.png", data: Data(repeating: fill, count: megabytes * 1_048_576))]])
}

private let day: TimeInterval = 24 * 60 * 60
private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct ClipboardHistoryTests {
    @Test func newestComesFirst() {
        var history = ClipboardHistory()
        history.add(text("a"), text: "a", kind: .text, source: nil, at: start)
        history.add(text("b"), text: "b", kind: .text, source: nil, at: start + 1)
        #expect(history.entries.map(\.text) == ["b", "a"])
    }

    @Test func copyingTheSameAgainMovesItUpInsteadOfAddingIt() {
        var history = ClipboardHistory()
        let first = history.add(text("a"), text: "a", kind: .text, source: nil, at: start)
        history.add(text("b"), text: "b", kind: .text, source: nil, at: start + 1)
        let again = history.add(text("a"), text: "a", kind: .text, source: nil, at: start + 2)
        #expect(history.entries.map(\.text) == ["a", "b"])
        #expect(again?.id == first?.id)
        #expect(history.entries[0].used == start + 2)
    }

    @Test func onlyAnExactCopyCounts() {
        var history = ClipboardHistory()
        history.add(text("a"), text: "a", kind: .text, source: nil, at: start)
        // Same text, but also as RTF: a different copy.
        let rich = ClipContent(items: [
            [
                .init(type: "public.utf8-plain-text", data: Data("a".utf8)),
                .init(type: "public.rtf", data: Data("{a}".utf8)),
            ]
        ])
        history.add(rich, text: "a", kind: .richText, source: nil, at: start + 1)
        history.add(text("A"), text: "A", kind: .text, source: nil, at: start + 2)
        #expect(history.entries.count == 3)
    }

    @Test func pickingAnEntryMovesItToTheTop() {
        var history = ClipboardHistory()
        let a = history.add(text("a"), text: "a", kind: .text, source: nil, at: start)!
        history.add(text("b"), text: "b", kind: .text, source: nil, at: start + 1)
        history.add(text("c"), text: "c", kind: .text, source: nil, at: start + 2)
        history.promote(a.id, at: start + 3)
        #expect(history.entries.map(\.text) == ["a", "c", "b"])
        #expect(history.entries[0].used == start + 3)
    }

    @Test func emptyCopiesAreIgnored() {
        var history = ClipboardHistory()
        #expect(history.add(ClipContent(items: [[]]), text: "", kind: .text, source: nil, at: start) == nil)
        #expect(history.entries.isEmpty)
    }

    @Test func nothingIsTrimmedBeforeThreeWeeksOfUptime() {
        var history = ClipboardHistory()
        history.add(text("old"), text: "old", kind: .text, source: nil, at: start)
        let removed = history.trim(uptime: 20 * day, now: start + 20 * day)
        #expect(removed == 0)
        #expect(history.entries.count == 1)
    }

    @Test func afterThreeWeeksOnlyTheLastWeekStays() {
        var history = ClipboardHistory()
        history.add(text("old"), text: "old", kind: .text, source: nil, at: start)
        // Eight days before the trim: older than a week.
        history.add(text("eight days"), text: "eight days", kind: .text, source: nil, at: start + 14 * day)
        // Exactly seven days before: still within the week.
        history.add(text("week"), text: "week", kind: .text, source: nil, at: start + 15 * day)
        history.add(text("new"), text: "new", kind: .text, source: nil, at: start + 21 * day)
        let removed = history.trim(uptime: 22 * day, now: start + 22 * day)
        #expect(removed == 2)
        #expect(history.entries.map(\.text) == ["new", "week"])
    }

    @Test func usingAnOldEntryAgainKeepsItAfterTrimming() {
        var history = ClipboardHistory()
        let old = history.add(text("old"), text: "old", kind: .text, source: nil, at: start)!
        history.promote(old.id, at: start + 21 * day)
        history.trim(uptime: 22 * day, now: start + 22 * day)
        #expect(history.entries.map(\.text) == ["old"])
    }

    @Test func evictionRemovesTheOldestFiftyMegabytes() {
        var history = ClipboardHistory()
        for (offset, size) in [30, 30, 10, 5].enumerated() {
            history.add(
                blob(size, fill: UInt8(offset)), text: "", kind: .image, source: nil, at: start + Double(offset))
        }
        #expect(history.byteCount == 75 * 1_048_576)
        let freed = history.evictOldest()
        // The two oldest (30 + 30 MB) go, the newer ones stay.
        #expect(freed == 60 * 1_048_576)
        #expect(history.entries.map(\.content.byteCount) == [5 * 1_048_576, 10 * 1_048_576])
    }

    @Test func theNewestEntryIsNeverEvicted() {
        var history = ClipboardHistory()
        history.add(blob(60, fill: 1), text: "", kind: .image, source: nil, at: start)
        #expect(history.evictOldest() == 0)
        #expect(history.entries.count == 1)
    }

    @Test func fittingABudgetRemovesFiftyMegabyteSteps() {
        var history = ClipboardHistory()
        for offset in 0..<6 {
            history.add(blob(20, fill: UInt8(offset)), text: "", kind: .image, source: nil, at: start + Double(offset))
        }
        // 120 MB in six entries, budget 70 MB: one step of 60 MB (three oldest).
        let freed = history.fit(budget: 70 * 1_048_576)
        #expect(freed == 60 * 1_048_576)
        #expect(history.entries.count == 3)
        // A budget below the newest entry keeps that entry anyway.
        history.fit(budget: 0)
        #expect(history.entries.count == 1)
    }

    @Test func searchMatchesEveryWordInTextOrSource() {
        var history = ClipboardHistory()
        history.add(text("Rechnung März"), text: "Rechnung März", kind: .text, source: "Mail", at: start)
        history.add(text("Server Liste"), text: "Server Liste", kind: .text, source: "Terminal", at: start + 1)
        #expect(history.search("rechnung marz").map(\.text) == ["Rechnung März"])
        #expect(history.search("liste terminal").map(\.text) == ["Server Liste"])
        #expect(history.search("  ").count == 2)
        #expect(history.search("fehlt").isEmpty)
    }

    @Test func pinnedEntriesComeFirstAndSurviveTrimming() {
        var history = ClipboardHistory()
        let old = history.add(text("pinned"), text: "pinned", kind: .text, source: nil, at: start)
        history.add(text("old"), text: "old", kind: .text, source: nil, at: start + day)
        history.add(text("new"), text: "new", kind: .text, source: nil, at: start + 21 * day)
        history.setPinned(try! #require(old?.id), true)
        #expect(history.search("").map(\.text) == ["pinned", "new", "old"])
        history.trim(uptime: 22 * day, now: start + 22 * day)
        #expect(history.entries.map(\.text) == ["new", "pinned"])
        // Copying it again keeps the pin.
        history.add(text("pinned"), text: "pinned", kind: .text, source: nil, at: start + 22 * day)
        #expect(history.entries.first?.isPinned == true)
    }

    @Test func pinnedEntriesAreEvictedLast() {
        var history = ClipboardHistory()
        let pinned = history.add(blob(30, fill: 1), text: "", kind: .image, source: nil, at: start)
        history.add(blob(30, fill: 2), text: "", kind: .image, source: nil, at: start + 1)
        history.add(blob(30, fill: 3), text: "", kind: .image, source: nil, at: start + 2)
        history.setPinned(try! #require(pinned?.id), true)
        // 50 MB to free: the unpinned middle one goes first, then the pinned one.
        let freed = history.evictOldest()
        #expect(freed == 60 * 1_048_576)
        #expect(history.entries.count == 1)
        history.add(blob(30, fill: 4), text: "", kind: .image, source: nil, at: start + 3)
        history.add(blob(30, fill: 5), text: "", kind: .image, source: nil, at: start + 4)
        history.setPinned(history.entries[2].id, true)
        history.evictOldest(bytes: 1)
        #expect(history.entries.count == 2)
        #expect(history.entries.contains { $0.isPinned }, "the unpinned one went")
    }
}
