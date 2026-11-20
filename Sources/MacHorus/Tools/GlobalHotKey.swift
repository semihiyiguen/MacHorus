// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import Carbon.HIToolbox
import MacHorusCore
import Observation

/// A key combination: a virtual key code plus Carbon modifier flags, as
/// `RegisterEventHotKey` takes them. Stored as "code:modifiers".
struct KeyCombo: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// ⌃⌘V and ⌥⌘V: free in macOS and common apps (⌘⇧V pastes without
    /// formatting in many apps, so it is not offered).
    static let suggestions = [
        KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey)),
        KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey)),
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press while recording; nil without ⌘, ⌃ or ⌥ (a plain
    /// letter as a global shortcut would swallow typing everywhere).
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        // Modifier keys alone are no shortcut.
        let modifierKeys: Set<Int> = [
            kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption, kVK_Control,
            kVK_RightControl, kVK_CapsLock, kVK_Function,
        ]
        guard !modifierKeys.contains(Int(keyCode)) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    var stored: String { "\(keyCode):\(modifiers)" }

    /// "⌃⌘V", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        // F-key codes are not in order (F1 is 122, F20 is 90): a lookup, not a range.
        default: functionKeys[Int(code)] ?? character(code) ?? "#\(code)"
        }
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character the key types on the current keyboard layout.
    private static func character(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// One system-wide shortcut through Carbon's `RegisterEventHotKey`: no
/// permission (unlike a key event monitor, which needs Input Monitoring),
/// and macOS delivers only this combination, never other key presses.
@MainActor
final class GlobalHotKey {
    enum Failure: Error {
        /// Another app registered the same combination.
        case taken
        case other(OSStatus)
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    private static let signature: OSType = 0x4D48_484B  // "MHHK"

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// Replaces the current combination; nil unregisters.
    func register(_ combo: KeyCombo?) throws(Failure) {
        unregister()
        guard let combo else { return }
        try installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), 0, &reference)
        switch status {
        case noErr: hotKey = reference
        case OSStatus(eventHotKeyExistsErr): throw .taken
        default: throw .other(status)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() throws(Failure) {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                // Carbon calls back on the main thread.
                guard let context else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &type, context, &handler)
        guard status == noErr else { throw .other(status) }
    }

    isolated deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}

/// The clipboard's shortcut: ⌃⌘V unless the user recorded another one or
/// removed it (only from the gear in the clipboard card). Registered only
/// while the clipboard history is on.
@MainActor
@Observable
final class ClipboardShortcut {
    static let key = "clipboardShortcut"
    static let noneValue = "none"

    enum Problem: Equatable {
        case taken
        case failed
        case needsModifier
    }

    private(set) var combo: KeyCombo?
    private(set) var problem: Problem?
    private(set) var isRecording = false

    @ObservationIgnored var action: @MainActor () -> Void = {}
    @ObservationIgnored private lazy var hotKey = GlobalHotKey { [weak self] in self?.action() }
    @ObservationIgnored private var isActive = false

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        combo = stored == Self.noneValue ? nil : stored.flatMap(KeyCombo.init(stored:)) ?? KeyCombo.suggestions[0]
    }

    func activate() {
        isActive = true
        register()
    }

    func deactivate() {
        isActive = false
        isRecording = false
        PanelFocus.recorder = nil
        hotKey.unregister()
    }

    func set(_ combo: KeyCombo?) {
        self.combo = combo
        UserDefaults.standard.set(combo?.stored ?? Self.noneValue, forKey: Self.key)
        stopRecording()
        register()
    }

    /// The next key press with ⌘, ⌃ or ⌥ becomes the shortcut; Esc cancels.
    /// The current shortcut is off meanwhile, so it can be pressed again.
    func startRecording() {
        hotKey.unregister()
        problem = nil
        isRecording = true
        PanelFocus.recorder = { [weak self] code, flags in
            guard let self else { return false }
            if code == 53, flags.isEmpty {  // Esc
                stopRecording()
                register()
                return true
            }
            guard let combo = KeyCombo(keyCode: code, flags: flags) else {
                // A modifier alone is still being pressed; a plain key is refused.
                if ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(code)) { problem = .needsModifier }
                return true
            }
            set(combo)
            return true
        }
    }

    func stopRecording() {
        isRecording = false
        PanelFocus.recorder = nil
    }

    private func register() {
        guard isActive, !isRecording else { return }
        do {
            try hotKey.register(combo)
            problem = nil
        } catch .taken {
            problem = .taken
        } catch {
            problem = .failed
            Log.features.error("Clipboard shortcut could not be registered")
        }
    }
}
