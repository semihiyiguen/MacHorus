// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusTools
import Observation

/// Clipboard history like Windows' Win+V: everything copied is kept in
/// memory only (never on disk), newest first, and a click puts it back on
/// the clipboard. The rules live in `ClipboardHistory`; this class watches
/// the pasteboard, filters what must never be kept and watches the app's
/// memory.
@MainActor
@Observable
final class ClipboardController {
    static let limitKey = "clipboardMemoryLimit"
    /// The whole app's memory (Activity Monitor's "Memory"), in MB.
    static let limits = [100, 250, 500]
    static let defaultLimit = 250
    /// Bigger single copies are not kept (huge images or files' data).
    static let largestEntry = 50 * 1_048_576

    var isEnabled = false
    private(set) var history = ClipboardHistory()
    /// Opens the panel on the history; set up from the gear in the card.
    let shortcut = ClipboardShortcut()
    /// Why the last copy was not recorded (password manager, marked as
    /// private, too big); nil after a recorded one. Shown on the card, so a
    /// copy never goes missing silently.
    private(set) var lastSkip: ClipboardReader.Skip?
    private(set) var limit = ClipboardController.storedLimit()
    /// Previews of copied images (aspect kept, readable from a distance)
    /// and their pixel size, by entry.
    @ObservationIgnored private(set) var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private(set) var pixelSizes: [UUID: String] = [:]

    @ObservationIgnored private let screen: ScreenAvailability
    @ObservationIgnored private let pasteboard: NSPasteboard
    /// `-debug.clipboardTrace <file>`: entry kinds and sizes after each change
    /// (contents only for test copies starting with "MHTEST").
    @ObservationIgnored private let tracePath = UserDefaults.standard.string(forKey: "debug.clipboardTrace")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = -1
    /// The change MacHorus made itself by putting an entry back.
    @ObservationIgnored private var ownChangeCount = -1

    /// The general pasteboard pauses with the screen; a test pasteboard does not.
    @ObservationIgnored private let followsScreen: Bool

    /// `pasteboard`: the general one; checks use a named one (`-debug.clipboardName`)
    /// so they never touch the user's clipboard, also with a locked screen.
    init(screen: ScreenAvailability, pasteboard: NSPasteboard = .general) {
        self.screen = screen
        self.pasteboard = pasteboard
        followsScreen = pasteboard.name == NSPasteboard.general.name
    }

    func start() {
        isEnabled = true
        shortcut.activate()
        // What is on the clipboard now is the first entry.
        capture()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Switching the feature off forgets the whole history.
    func stop() {
        isEnabled = false
        shortcut.deactivate()
        timer?.invalidate()
        timer = nil
        clear()
        lastChangeCount = -1
    }

    func clear() {
        history.removeAll()
        thumbnails = [:]
        pixelSizes = [:]
        Self.returnFreedMemory()
    }

    func remove(_ id: UUID) {
        history.remove(id)
        thumbnails[id] = nil
        pixelSizes[id] = nil
        Self.returnFreedMemory()
    }

    /// Returns what malloc still holds from the read itself.
    private static func returnFreedMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    func setLimit(_ megabytes: Int) {
        limit = megabytes
        UserDefaults.standard.set(megabytes, forKey: Self.limitKey)
        enforceMemoryLimit()
    }

    /// Puts an entry back on the clipboard; it moves to the top.
    func pick(_ id: UUID) {
        defer { writeTrace() }
        guard let entry = history.promote(id, at: Date()) else { return }
        pasteboard.clearContents()
        let items = entry.content.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = ownChangeCount
    }

    /// Bytes the history holds (shown under the list).
    var byteCount: Int { history.byteCount }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        history.setPinned(id, pinned)
    }

    /// Only the text, without fonts, colours or links: for pasting into a
    /// document that should keep its own style. File entries give their paths.
    func pickPlain(_ id: UUID) {
        guard let entry = history.entries.first(where: { $0.id == id }), let text = Self.plainText(entry) else {
            return
        }
        history.promote(id, at: Date())
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = ownChangeCount
    }

    /// Text for "copy as plain text"; nil for images.
    static func plainText(_ entry: ClipboardHistory.Entry) -> String? {
        let representations = entry.content.items.flatMap { $0 }
        if entry.kind == .file {
            let paths = representations.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
                .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:))?.path }
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        }
        guard entry.kind != .image, !entry.text.isEmpty else { return nil }
        return entry.text
    }

    /// Puts recognised text on the clipboard; it becomes a new entry.
    func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// QR codes and text in an image entry, read off the main thread; never
    /// opens anything.
    func recognize(_ id: UUID) async -> ImageText? {
        guard let entry = history.entries.first(where: { $0.id == id }), entry.kind == .image else { return nil }
        let imageTypes: Set<String> = [
            NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue,
        ]
        guard let data = entry.content.items.flatMap({ $0 }).first(where: { imageTypes.contains($0.type) })?.data
        else { return nil }
        return await OffMain.run { ImageText.read(imageData: data) }
    }

    // MARK: Watching

    /// The change count costs one cheap call; contents are read only when
    /// it changed. Nothing is read while the screen is locked or asleep.
    private func check() {
        guard screen.isAvailable || !followsScreen else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        capture()
    }

    private func capture() {
        lastChangeCount = pasteboard.changeCount
        guard lastChangeCount != ownChangeCount else { return }
        let source = NSWorkspace.shared.frontmostApplication
        let read: ClipboardReader.Read
        switch ClipboardReader.read(pasteboard, sourceBundleID: source?.bundleIdentifier) {
        case .read(let result): read = result
        case .skipped(let reason):
            skip(reason)
            return
        case .empty: return
        }
        guard read.content.byteCount <= Self.largestEntry else {
            Log.features.notice(
                "Clipboard: a copy of \(read.content.byteCount / 1_048_576, privacy: .public) MB is not kept")
            skip(.tooLarge)
            return
        }
        if lastSkip != nil { lastSkip = nil }
        let now = Date()
        guard
            let entry = history.add(
                read.content, text: read.text, kind: read.kind, source: source?.localizedName, at: now)
        else { return }
        if entry.kind == .image, thumbnails[entry.id] == nil, let image = read.image, image.isValid {
            thumbnails[entry.id] = ClipThumbnail.make(image, fitting: ClipThumbnail.size)
            if let rep = image.representations.first, rep.pixelsWide > 0 {
                pixelSizes[entry.id] = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
            } else {
                // PDF and other vector copies have no pixels: their size in points.
                pixelSizes[entry.id] = "\(Int(image.size.width)) × \(Int(image.size.height))"
            }
        }
        history.trim(uptime: Self.timeSinceBoot(), now: now)
        let kept = Set(history.entries.map(\.id))
        thumbnails = thumbnails.filter { kept.contains($0.key) }
        pixelSizes = pixelSizes.filter { kept.contains($0.key) }
        enforceMemoryLimit()
        writeTrace()
    }

    private func skip(_ reason: ClipboardReader.Skip) {
        Log.features.notice("Clipboard: a copy was not recorded (\(String(describing: reason), privacy: .public))")
        if lastSkip != reason { lastSkip = reason }
    }

    /// When the whole app reaches the limit, the oldest 50 MB of the
    /// history go. The rest of the app's memory is what it takes besides the
    /// history; the history may use what is left up to the limit. Counting
    /// the history's own bytes (not the footprint again) keeps one eviction
    /// from cascading: freed memory reaches the footprint only later.
    private func enforceMemoryLimit() {
        guard let footprint = SelfUsageSampler.footprint(), footprint >= UInt64(limit) * 1_048_576 else { return }
        let rest = Int(footprint) - history.byteCount
        let freed = history.fit(budget: limit * 1_048_576 - rest)
        guard freed > 0 else { return }
        Self.returnFreedMemory()
        let kept = Set(history.entries.map(\.id))
        thumbnails = thumbnails.filter { kept.contains($0.key) }
        pixelSizes = pixelSizes.filter { kept.contains($0.key) }
        Log.features.notice(
            "Clipboard: app at \(footprint / 1_048_576, privacy: .public) MB, oldest \(freed / 1_048_576, privacy: .public) MB removed"
        )
        evictions.append("evicted \(freed / 1_048_576) MB at app \(footprint / 1_048_576) MB")
    }

    @ObservationIgnored private var evictions: [String] = []

    private func writeTrace() {
        guard let tracePath else { return }
        var lines = evictions
        let footprint = SelfUsageSampler.footprint().map { "\($0 / 1_048_576) MB" } ?? "-"
        lines.append("entries=\(history.entries.count) bytes=\(history.byteCount) app=\(footprint)")
        for entry in history.entries {
            let shown = entry.text.hasPrefix("MHTEST") ? entry.text : "len=\(entry.text.count)"
            lines.append("  \(entry.kind.rawValue) \(shown) bytes=\(entry.content.byteCount)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: tracePath, atomically: true, encoding: .utf8)
    }

    private static func storedLimit() -> Int {
        let stored = UserDefaults.standard.integer(forKey: limitKey)
        return limits.contains(stored) ? stored : defaultLimit
    }

    /// Wall-clock time since the Mac started (sleep included).
    static func timeSinceBoot() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}

/// What is kept of a copy, and what is never kept.
@MainActor
enum ClipboardReader {
    struct Read {
        let content: ClipContent
        let text: String
        let kind: ClipboardHistory.Kind
        let image: NSImage?
    }

    enum Skip: Equatable {
        /// Copied while a password manager was in front.
        case passwordManager
        /// Marked by the source app as private or temporary (nspasteboard.org).
        case markedPrivate
        case tooLarge
    }

    enum Outcome {
        case read(Read)
        case skipped(Skip)
        /// Nothing MacHorus keeps (e.g. only app-private formats).
        case empty
    }

    /// Kept per item, in this order: what apps need to paste text, rich
    /// text, images, files and links. App-private formats are left out
    /// (Windows' history keeps text, HTML and images too).
    static let keptTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .html, .png, .tiff, .fileURL, .URL,
    ]

    /// Marked by password managers and other apps as not for a history
    /// (nspasteboard.org); such copies are never read.
    static let privateMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    /// Password managers: anything copied while they are in front is skipped.
    static let privateSources: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop", "com.nordpass.macos.NordPass",
    ]

    static func read(_ pasteboard: NSPasteboard, sourceBundleID: String?) -> Outcome {
        if let sourceBundleID, privateSources.contains(sourceBundleID) { return .skipped(.passwordManager) }
        let allTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        guard allTypes.isDisjoint(with: privateMarkers) else { return .skipped(.markedPrivate) }
        let items = pasteboard.pasteboardItems ?? []
        var representations: [[ClipContent.Representation]] = []
        for item in items {
            let available = Set(item.types)
            var kept: [ClipContent.Representation] = []
            for type in keptTypes where available.contains(type) {
                // TIFF only when there is no PNG: the same image, often 10× bigger.
                if type == .tiff, available.contains(.png) { continue }
                if let data = item.data(forType: type) {
                    kept.append(.init(type: type.rawValue, data: ClipStorage.keep(data)))
                }
            }
            representations.append(kept)
        }
        let content = ClipContent(items: representations)
        guard !content.isEmpty else { return .empty }

        let fileNames = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent }
        let string = items.first?.string(forType: .string)
        let hasImage =
            allTypes.contains(NSPasteboard.PasteboardType.png.rawValue)
            || allTypes.contains(NSPasteboard.PasteboardType.tiff.rawValue)
        let kind: ClipboardHistory.Kind
        let text: String
        if !fileNames.isEmpty {
            kind = .file
            text = fileNames.joined(separator: ", ")
        } else if let string, !string.isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if allTypes.contains(NSPasteboard.PasteboardType.URL.rawValue) || isWebLink(trimmed) {
                kind = .link
            } else if allTypes.contains(NSPasteboard.PasteboardType.rtf.rawValue)
                || allTypes.contains(NSPasteboard.PasteboardType.html.rawValue)
            {
                kind = .richText
            } else {
                kind = .text
            }
            text = string
        } else if hasImage {
            kind = .image
            text = ""
        } else {
            kind = .text
            text = items.first?.string(forType: .URL) ?? ""
        }
        let image = kind == .image ? NSImage(pasteboard: pasteboard) : nil
        return .read(Read(content: content, text: text, kind: kind, image: image))
    }

    private static func isWebLink(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}

/// A copied image scaled into `size` with its aspect kept (a square crop
/// made screenshots unrecognisable), drawn once at capture.
@MainActor
enum ClipThumbnail {
    static let size = NSSize(width: 96, height: 44)

    static func make(_ source: NSImage, fitting box: NSSize) -> NSImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(box.width / source.size.width, box.height / source.size.height, 1)
        let size = NSSize(width: max(source.size.width * scale, 1), height: max(source.size.height * scale, 1))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // The point size must be set before the context exists.
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// Large copies (images) live in their own mapped memory: removing them from
/// the history unmaps it, and the app's memory drops at once. malloc kept
/// freed large blocks for reuse, so the app stayed at its peak (measured:
/// 257 MB with one 30 MB entry left).
enum ClipStorage {
    static let mappedFrom = 1_048_576

    static func keep(_ data: Data) -> Data {
        guard data.count >= mappedFrom else { return data }
        let size = data.count
        guard
            let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
            memory != MAP_FAILED
        else { return data }
        data.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: size)
        return Data(bytesNoCopy: memory, count: size, deallocator: .custom { pointer, count in munmap(pointer, count) })
    }
}

@MainActor
final class ClipboardFeature: FeatureModule {
    private let controller: ClipboardController

    init(controller: ClipboardController) {
        self.controller = controller
    }

    func start() { controller.start() }
    func stop() { controller.stop() }

    static func register(in registry: FeatureRegistry, controller: ClipboardController) {
        registry.register(FeatureDescriptor(id: "clipboard.history", category: .clipboard)) {
            ClipboardFeature(controller: controller)
        }
    }
}
