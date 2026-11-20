// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation

/// One copied thing as the pasteboard held it: per pasteboard item, the
/// data of each kept type (plain text, RTF, HTML, image, file or web link).
public struct ClipContent: Equatable, Sendable {
    public struct Representation: Equatable, Sendable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// One array per pasteboard item (several files copied at once are
    /// several items).
    public let items: [[Representation]]

    public init(items: [[Representation]]) {
        self.items = items
    }

    public var byteCount: Int {
        items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
    }

    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }
}

/// The clipboard history, newest first. Only in memory: it starts empty with
/// every launch (and so with every restart of the Mac). Rules:
/// - copying something that is already in the history (1:1 the same data)
///   moves that entry to the top instead of adding a second one,
/// - an entry picked from the history becomes the clipboard and moves to the
///   top,
/// - after 21 days without a restart only the last 7 days are kept,
/// - when the app's memory reaches its limit, the oldest 50 MB go; the
///   newest entry (what is on the clipboard) always stays,
/// - pinned entries are exempt from the 7 days and go last under the memory
///   limit (only in memory too: a restart empties the history, pins included).
public struct ClipboardHistory: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let content: ClipContent
        /// Searchable text: the plain text, or the file names or link.
        public let text: String
        public let kind: Kind
        /// The app it was copied in, if known.
        public let source: String?
        /// When it was last copied or picked.
        public internal(set) var used: Date
        /// Kept at the top of the list and through trimming.
        public internal(set) var isPinned = false
    }

    public enum Kind: String, Sendable {
        case text
        case richText
        case image
        case file
        case link
    }

    public static let uptimeBeforeTrimming: TimeInterval = 21 * 24 * 60 * 60
    public static let keptAfterTrimming: TimeInterval = 7 * 24 * 60 * 60
    public static let evictionBytes = 50 * 1_048_576

    public private(set) var entries: [Entry] = []

    public init() {}

    public var byteCount: Int { entries.reduce(0) { $0 + $1.content.byteCount } }

    /// Records a copy. Returns the entry now on top.
    @discardableResult
    public mutating func add(
        _ content: ClipContent, text: String, kind: Kind, source: String?, at now: Date
    ) -> Entry? {
        guard !content.isEmpty else { return nil }
        if let index = entries.firstIndex(where: { $0.content == content }) {
            var entry = entries.remove(at: index)
            entry.used = now
            entries.insert(entry, at: 0)
            return entry
        }
        let entry = Entry(id: UUID(), content: content, text: text, kind: kind, source: source, used: now)
        entries.insert(entry, at: 0)
        return entry
    }

    /// The user picked an entry: it becomes the newest.
    @discardableResult
    public mutating func promote(_ id: UUID, at now: Date) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var entry = entries.remove(at: index)
        entry.used = now
        entries.insert(entry, at: 0)
        return entry
    }

    public mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned = pinned
    }

    /// Pinned entries first, each group newest first: the order the list shows.
    public var ordered: [Entry] { entries.filter(\.isPinned) + entries.filter { !$0.isPinned } }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// After 21 days without a restart, keeps only what was used in the last
    /// 7 days. Returns how many entries went.
    @discardableResult
    public mutating func trim(uptime: TimeInterval, now: Date) -> Int {
        guard uptime >= Self.uptimeBeforeTrimming else { return 0 }
        let before = entries.count
        let cutoff = now.addingTimeInterval(-Self.keptAfterTrimming)
        entries.removeAll { !$0.isPinned && $0.used < cutoff }
        return before - entries.count
    }

    /// Removes the oldest entries until at least `bytes` are freed. The
    /// newest entry, the current clipboard, is never removed. Returns the
    /// bytes freed.
    @discardableResult
    public mutating func evictOldest(bytes: Int = evictionBytes) -> Int {
        var freed = 0
        while freed < bytes, entries.count > 1 {
            // The oldest unpinned entry; pinned ones only when nothing else is left.
            let candidates = entries.indices.dropFirst()
            guard let index = candidates.last(where: { !entries[$0].isPinned }) ?? candidates.last else { break }
            freed += entries[index].content.byteCount
            entries.remove(at: index)
        }
        return freed
    }

    /// Keeps the history within `budget` bytes by removing the oldest 50 MB
    /// at a time (never the newest entry). Returns the bytes freed.
    @discardableResult
    public mutating func fit(budget: Int) -> Int {
        var freed = 0
        while byteCount > max(budget, 0), entries.count > 1 {
            freed += evictOldest()
        }
        return freed
    }

    /// Entries whose text or source contains every word of `query`,
    /// ignoring case and diacritics; all entries for an empty query.
    public func search(_ query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ordered }
        return ordered.filter { entry in
            let haystack = entry.text + " " + (entry.source ?? "")
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
