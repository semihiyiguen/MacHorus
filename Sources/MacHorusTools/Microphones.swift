// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation

/// One audio input device and whether it can be silenced.
public struct Microphone: Equatable, Sendable {
    public let id: AudioObjectID
    /// Stays the same across restarts (the id does not).
    public let uid: String?
    public let name: String
    /// Muted, or its input volume is 0.
    public let isSilent: Bool
    /// How MacHorus can silence it; nil when the device offers neither.
    public let control: Control?

    public enum Control: Equatable, Sendable {
        case mute
        case volume
    }
}

/// Mutes every microphone through the device's own mute switch, or, where a
/// device has none, sets its input volume to 0 and restores it afterwards.
/// Changing these device settings records no audio, so macOS asks for no
/// microphone permission. Only CoreAudio properties are used.
public enum Microphones {
    private static let main = kAudioObjectPropertyElementMain

    /// Physical microphones (built in, USB, Bluetooth, webcams). Virtual
    /// and aggregate devices only pass audio on (Teams' sharing device,
    /// loopbacks); the microphones behind them are muted themselves.
    public static func list() -> [Microphone] {
        deviceIDs().filter { hasInput($0) && !isVirtual($0) }.map { id in
            let control: Microphone.Control? =
                isSettable(id, kAudioDevicePropertyMute)
                ? .mute
                : isSettable(id, kAudioDevicePropertyVolumeScalar) ? .volume : nil
            return Microphone(
                id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                name: string(id, kAudioObjectPropertyName) ?? "–",
                isSilent: isSilent(id), control: control)
        }
    }

    /// Silences `id`; returns the input volume to restore later (volume
    /// devices only). Reads the value back: false when it did not stick.
    @discardableResult
    public static func silence(_ id: AudioObjectID, saving volumes: inout [AudioObjectID: Float32]) -> Bool {
        if isSettable(id, kAudioDevicePropertyMute) {
            return set(id, kAudioDevicePropertyMute, UInt32(1)) && isSilent(id)
        }
        guard isSettable(id, kAudioDevicePropertyVolumeScalar),
            let volume: Float32 = value(id, kAudioDevicePropertyVolumeScalar)
        else { return false }
        if volume > 0 { volumes[id] = volume }
        return set(id, kAudioDevicePropertyVolumeScalar, Float32(0)) && isSilent(id)
    }

    /// Undoes `silence`: unmutes, or restores the saved input volume.
    public static func restore(_ id: AudioObjectID, volumes: [AudioObjectID: Float32]) {
        if isSettable(id, kAudioDevicePropertyMute) {
            set(id, kAudioDevicePropertyMute, UInt32(0))
        } else if let volume = volumes[id] {
            set(id, kAudioDevicePropertyVolumeScalar, volume)
        }
    }

    public static func isSilent(_ id: AudioObjectID) -> Bool {
        if let muted: UInt32 = value(id, kAudioDevicePropertyMute), muted != 0 { return true }
        if let volume: Float32 = value(id, kAudioDevicePropertyVolumeScalar), volume == 0 { return true }
        return false
    }

    /// Calls `handler` on the main queue when microphones come or go.
    public static func observeDevices(_ handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    public static func stopObserving(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    // MARK: CoreAudio access

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isVirtual(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: main)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func inputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: main)
    }

    private static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = inputAddress(selector)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = inputAddress(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    @discardableResult
    private static func set<T: BitwiseCopyable>(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ newValue: T
    ) -> Bool {
        var address = inputAddress(selector)
        return withUnsafePointer(to: newValue) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }
}
