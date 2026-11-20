// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation

/// A process the audio system knows: it has an audio session, and may be
/// playing sound or using a microphone right now.
public struct AudioProcess: Equatable, Sendable {
    /// The Core Audio object, needed to tap this process.
    public let objectID: AudioObjectID
    public let pid: pid_t
    /// e.g. "com.google.Chrome.helper"; nil for processes without a bundle.
    public let bundleID: String?
    /// Records from an input device right now.
    public let usesInput: Bool
    /// Plays to an output device right now.
    public let usesOutput: Bool
}

/// Reads Core Audio's process objects (macOS 14.2+): which processes play
/// sound or use a microphone. Needs no permission; only states are read,
/// never audio.
public enum AudioProcesses {
    public static func list() -> [AudioProcess] {
        objectIDs().compactMap { id in
            guard let pid: pid_t = value(id, kAudioProcessPropertyPID), pid > 0 else { return nil }
            let input: UInt32 = value(id, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcess(
                objectID: id, pid: pid, bundleID: string(id, kAudioProcessPropertyBundleID), usesInput: input != 0,
                usesOutput: output != 0)
        }
    }

    /// Calls `handler` on the main queue when processes get or lose an audio
    /// session. Starting and stopping playback is a separate property per
    /// process; callers that show live state re-read on their own schedule.
    public static func observeList(_ handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    public static func stopObservingList(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    // MARK: Core Audio access

    private static func objectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var text: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &text) == noErr,
            let value = text?.takeRetainedValue() as String?, !value.isEmpty
        else { return nil }
        return value
    }
}
