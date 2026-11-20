// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import SwiftUI

/// The clipboard history on its own, opened by the shortcut where the mouse
/// pointer is (clamped to the screen). A non-activating panel: the app in
/// front stays in front, so ⌘V after a pick pastes there. It closes after a
/// pick, with Esc, the shortcut again, or a click anywhere else.
@MainActor
final class QuickClipboardWindow: NSObject, NSWindowDelegate {
    private var panel: QuickPanel?

    func toggle(controller: ClipboardController) {
        if let panel, panel.isVisible {
            close()
            return
        }
        show(controller: controller)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    private func show(controller: ClipboardController) {
        let root = QuickClipboardView(controller: controller) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, at: NSEvent.mouseLocation))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Top-left corner at the pointer, moved inside the screen's visible area.
    static func origin(for size: NSSize, at point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        var origin = NSPoint(x: point.x - 20, y: point.y - size.height + 10)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }

    // A click into another app or window takes the key status: close.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A borderless panel that can still take the keyboard; Esc closes it.
private final class QuickPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

private struct QuickClipboardView: View {
    let controller: ClipboardController
    let close: () -> Void

    var body: some View {
        ClipboardCard(controller: controller, focusesSearchOnAppear: true, close: close)
            .padding(10)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .tint(Theme.gold)
    }
}
