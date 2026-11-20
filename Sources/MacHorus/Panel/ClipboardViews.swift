// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusTools
import SwiftUI

/// The clipboard history on the overview, between the monitor rings and the
/// sound box: a search field and a scrolling list about five lines high,
/// in the compact and the wide panel alike. Everything since the last
/// restart is in it, pinned entries first; images show as recognisable
/// previews. A click (or ↩ on the selected line) puts an entry back on the
/// clipboard and closes the panel, so ⌘V pastes it. The gear sets the
/// shortcut that opens this card from anywhere.
struct ClipboardCard: View {
    let controller: ClipboardController
    /// The quick window from the shortcut focuses its search field at once
    /// and closes itself after a pick; the menu bar panel closes the popover.
    var focusesSearchOnAppear = false
    var close: () -> Void = { PanelFocus.close() }
    @State private var query = ""
    @State private var selection: UUID?
    @State private var showsSettings = false
    @State private var recognized: Recognized?
    @FocusState private var searchFocused: Bool

    /// Five text lines; an image line is taller.
    static let listHeight: CGFloat = 5 * 26

    struct Recognized: Equatable {
        let id: UUID
        /// nil while reading.
        var result: ImageText??
    }

    var body: some View {
        let matches = controller.history.search(query)
        PanelCard(spacing: 8) {
            header
            if showsSettings { ClipboardShortcutSettings(shortcut: controller.shortcut) }
            if let skip = controller.lastSkip {
                Label {
                    Text(verbatim: ClipboardTexts.skip(skip)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if controller.history.entries.isEmpty {
                Text("clipboard.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ClipboardSearchField(text: $query, focused: $searchFocused)
                    .onKeyPress(.downArrow) {
                        move(1, in: matches)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1, in: matches)
                        return .handled
                    }
                    .onSubmit {
                        if let entry = matches.first(where: { $0.id == selection }) ?? matches.first { pick(entry.id) }
                    }
                if matches.isEmpty {
                    Text("clipboard.noMatch").font(.caption).foregroundStyle(.secondary)
                } else {
                    list(matches)
                }
            }
            if let recognized {
                RecognizedTextView(recognized: recognized, controller: controller) { self.recognized = nil }
            }
        }
        .onChange(of: query) { selection = nil }
        .task {
            guard focusesSearchOnAppear else { return }
            // After the window has become key.
            try? await Task.sleep(for: .milliseconds(80))
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconTile(symbol: "doc.on.clipboard", size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("clipboard.title").font(.callout.weight(.semibold)).lineLimit(1)
                Text(
                    verbatim: [summary, controller.shortcut.combo?.display].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !controller.history.entries.isEmpty {
                HeaderButton(symbol: "trash", help: "clipboard.clear") {
                    controller.clear()
                    recognized = nil
                }
            }
            HeaderButton(symbol: showsSettings ? "gearshape.fill" : "gearshape", help: "clipboard.settings") {
                showsSettings.toggle()
                if !showsSettings { controller.shortcut.stopRecording() }
            }
        }
    }

    private var summary: String {
        let count = controller.history.entries.count
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(controller.byteCount), countStyle: .memory)
        return String(
            format: count == 1
                ? String(localized: "clipboard.summary.one %@") : String(localized: "clipboard.summary %@ %@"),
            count == 1 ? bytes : String(count), bytes)
    }

    private func list(_ matches: [ClipboardHistory.Entry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(matches) { entry in
                        ClipRow(
                            entry: entry, thumbnail: controller.thumbnails[entry.id],
                            pixelSize: controller.pixelSizes[entry.id],
                            isCurrent: entry.id == controller.history.entries.first?.id,
                            isSelected: entry.id == selection,
                            actions: actions(for: entry)
                        )
                        .id(entry.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            // As high as the lines, at most about five of them.
            .frame(height: min(Self.listHeight, matches.reduce(0) { $0 + ($1.kind == .image ? 54 : 26) }))
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func actions(for entry: ClipboardHistory.Entry) -> ClipRow.Actions {
        ClipRow.Actions(
            pick: { pick(entry.id) },
            pickPlain: ClipboardController.plainText(entry) == nil || entry.kind == .text
                ? nil
                : {
                    controller.pickPlain(entry.id)
                    query = ""
                    close()
                },
            togglePin: { controller.setPinned(entry.id, !entry.isPinned) },
            recognize: entry.kind == .image ? { recognize(entry.id) } : nil,
            remove: {
                controller.remove(entry.id)
                if recognized?.id == entry.id { recognized = nil }
            })
    }

    private func pick(_ id: UUID) {
        controller.pick(id)
        query = ""
        selection = nil
        close()
    }

    private func move(_ step: Int, in matches: [ClipboardHistory.Entry]) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : matches.count)
        selection = matches[min(max(index + step, 0), matches.count - 1)].id
    }

    private func recognize(_ id: UUID) {
        recognized = Recognized(id: id, result: nil)
        Task {
            let result = await controller.recognize(id)
            if recognized?.id == id { recognized = Recognized(id: id, result: .some(result)) }
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// The shortcut that opens the history: shown, recorded, suggested or removed.
private struct ClipboardShortcutSettings: View {
    let shortcut: ClipboardShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("clipboard.shortcut.title").font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Button {
                    shortcut.isRecording ? shortcut.stopRecording() : shortcut.startRecording()
                } label: {
                    Text(
                        verbatim: shortcut.isRecording
                            ? String(localized: "clipboard.shortcut.recording")
                            : shortcut.combo?.display ?? String(localized: "clipboard.shortcut.none")
                    )
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(shortcut.isRecording ? Theme.goldText : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(shortcut.isRecording ? Theme.gold.opacity(0.18) : .primary.opacity(0.07))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text("clipboard.shortcut.record"))
                .accessibilityLabel(Text("clipboard.shortcut.record"))
            }
            HStack(spacing: 6) {
                ForEach(KeyCombo.suggestions, id: \.stored) { combo in
                    Chip(text: combo.display, selected: combo == shortcut.combo) { shortcut.set(combo) }
                }
                Chip(text: String(localized: "clipboard.shortcut.remove"), selected: shortcut.combo == nil) {
                    shortcut.set(nil)
                }
            }
            if let problem = shortcut.problem {
                Label(problemText(problem), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("clipboard.shortcut.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }

    private func problemText(_ problem: ClipboardShortcut.Problem) -> LocalizedStringKey {
        switch problem {
        case .taken: "clipboard.shortcut.taken"
        case .failed: "clipboard.shortcut.failed"
        case .needsModifier: "clipboard.shortcut.needsModifier"
        }
    }

    private struct Chip: View {
        let text: String
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(verbatim: text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Theme.goldText : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Theme.gold.opacity(0.18) : .primary.opacity(0.05)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// What Vision found in an image: codes and text, shown as text only. A
/// link is never opened (a QR code could lead anywhere); it can be copied.
private struct RecognizedTextView: View {
    let recognized: ClipboardCard.Recognized
    let controller: ClipboardController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("clipboard.recognize.title", systemImage: "text.viewfinder")
                    .font(.caption.weight(.semibold))
                Spacer()
                HeaderButton(symbol: "xmark", help: "clipboard.recognize.close", action: close)
            }
            switch recognized.result {
            case .none:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("clipboard.recognize.working").font(.caption).foregroundStyle(.secondary)
                }
            case .some(.none):
                Text("clipboard.recognize.none").font(.caption).foregroundStyle(.secondary)
            case .some(.some(let text)) where text.isEmpty:
                Text("clipboard.recognize.none").font(.caption).foregroundStyle(.secondary)
            case .some(.some(let text)):
                ForEach(Array(text.codes.enumerated()), id: \.offset) { _, code in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: code.isLink ? "link" : "qrcode").font(.caption)
                            Text(verbatim: code.payload)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            copyButton(code.payload)
                        }
                        if code.isLink {
                            Text("clipboard.recognize.link")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !text.lines.isEmpty {
                    let joined = text.lines.joined(separator: "\n")
                    HStack(alignment: .top, spacing: 6) {
                        ScrollView {
                            Text(verbatim: joined)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                        copyButton(joined)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }

    private func copyButton(_ text: String) -> some View {
        Button("clipboard.recognize.copy") { controller.copyText(text) }
            .buttonStyle(PillButtonStyle())
            .font(.caption)
    }
}

/// One line per copy: preview, text, age; the current one tinted, the
/// keyboard selection outlined, pinned ones marked. The context menu holds
/// the rarer actions. No hover effects: any hover handler makes SwiftUI
/// hit-test the whole panel on every pointer move (measured 3 % CPU).
private struct ClipRow: View {
    struct Actions {
        let pick: () -> Void
        /// nil when the entry has no richer form than its text.
        let pickPlain: (() -> Void)?
        let togglePin: () -> Void
        /// Only for images.
        let recognize: (() -> Void)?
        let remove: () -> Void
    }

    let entry: ClipboardHistory.Entry
    let thumbnail: NSImage?
    let pixelSize: String?
    let isCurrent: Bool
    let isSelected: Bool
    let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Button(action: actions.pick) {
                HStack(spacing: 8) {
                    preview
                    Text(verbatim: title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.goldText)
                            .accessibilityLabel(Text("clipboard.pinned"))
                    }
                    Text(verbatim: age)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: helpText))
            Button(action: actions.remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("clipboard.remove"))
            .accessibilityLabel(Text("clipboard.remove"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCurrent ? Theme.gold.opacity(0.14) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Theme.gold : .clear, lineWidth: 1.5)
        )
        .contextMenu {
            Button("clipboard.menu.pick", action: actions.pick)
            if let pickPlain = actions.pickPlain { Button("clipboard.menu.plain", action: pickPlain) }
            Button(entry.isPinned ? "clipboard.menu.unpin" : "clipboard.menu.pin", action: actions.togglePin)
            if let recognize = actions.recognize { Button("clipboard.menu.recognize", action: recognize) }
            Divider()
            Button("clipboard.remove", role: .destructive, action: actions.remove)
        }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            // The whole image, aspect kept, big enough to recognise.
            Image(nsImage: thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        } else {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(isCurrent ? Theme.goldText : Color.secondary)
                .frame(width: 18)
        }
    }

    private var symbol: String { ClipLabel.symbol(entry.kind) }
    private var title: String { ClipLabel.title(entry, pixelSize: pixelSize) }
    private var age: String { ClipLabel.age(entry) }

    private var helpText: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.content.byteCount), countStyle: .memory)
        let from = entry.source.map { " · \($0)" } ?? ""
        return String(localized: "clipboard.pick.help") + from + " · " + size
    }
}

/// How an entry reads in the history and in the widget: what it is
/// (an image says so, with its size and the app it came from), when.
@MainActor
enum ClipLabel {
    static func symbol(_ kind: ClipboardHistory.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .file: "doc"
        case .link: "link"
        }
    }

    /// The first 200 characters on one line: long copies cost no layout.
    static func title(_ entry: ClipboardHistory.Entry, pixelSize: String?) -> String {
        switch entry.kind {
        case .image:
            [String(localized: "clipboard.kind.image"), pixelSize, entry.source].compactMap { $0 }
                .joined(separator: " · ")
        default:
            String(
                entry.text.prefix(200).split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces))
        }
    }

    static func age(_ entry: ClipboardHistory.Entry) -> String {
        let now = Date()
        return now.timeIntervalSince(entry.used) < 5
            ? String(localized: "clipboard.justNow") : relative.localizedString(for: entry.used, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// Typing filters at once, ↑↓ choose a line, ↩ takes it; clicking the
/// field makes the panel key (a text field asks for that itself).
private struct ClipboardSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("clipboard.search", text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("monitor.processes.search.clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }
}

enum ClipboardTexts {
    static func skip(_ skip: ClipboardReader.Skip) -> String {
        switch skip {
        case .passwordManager: String(localized: "clipboard.skip.passwordManager")
        case .markedPrivate: String(localized: "clipboard.skip.markedPrivate")
        case .tooLarge: String(localized: "clipboard.skip.tooLarge")
        }
    }
}
