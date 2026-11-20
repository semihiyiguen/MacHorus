// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation

/// An audio device the user can pick as the Mac's output or input.
public struct AudioDevice: Equatable, Identifiable, Sendable {
    public let id: AudioObjectID
    public let name: String

    public init(id: AudioObjectID, name: String) {
        self.id = id
        self.name = name
    }
}

/// The Mac's default output and input, as Control Center switches them:
/// only devices that can be the default in that direction (no hidden ones,
/// no MacHorus taps). Changing the default records nothing and needs no
/// permission.
public enum AudioDevices {
    public enum Direction: Sendable {
        case output
        case input

        var scope: AudioObjectPropertyScope {
            self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        }

        var defaultSelector: AudioObjectPropertySelector {
            self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        }
    }

    private static let main = kAudioObjectPropertyElementMain
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func list(_ direction: Direction) -> [AudioDevice] {
        deviceIDs().filter { canBeDefault($0, direction) }.map {
            AudioDevice(id: $0, name: name($0) ?? "–")
        }
    }

    public static func defaultDevice(_ direction: Direction) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultSelector, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    /// Makes `id` the default; reads it back. Output also moves the alert
    /// sounds, as Control Center does.
    @discardableResult
    public static func setDefault(_ id: AudioObjectID, _ direction: Direction) -> Bool {
        guard canBeDefault(id, direction) else { return false }
        var device = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultSelector, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        guard AudioObjectSetPropertyData(system, &address, 0, nil, size, &device) == noErr else { return false }
        if direction == .output, canBeSystemDefault(id) {
            address.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
            AudioObjectSetPropertyData(system, &address, 0, nil, size, &device)
        }
        return defaultDevice(direction) == id
    }

    /// The device's output level (0…1) as the volume keys set it, or nil
    /// when the device has no adjustable level (HDMI, some docks).
    public static func volume(_ id: AudioObjectID) -> Float? {
        for address in volumeAddresses(id) {
            var address = address
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    /// Sets the output level as the volume keys do; reads nothing back.
    @discardableResult
    public static func setVolume(_ level: Float, _ id: AudioObjectID) -> Bool {
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        var done = false
        for address in volumeAddresses(id) {
            var address = address
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            done = AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr || done
            // One main control is enough; channel controls need both sides.
            if address.mElement == main, done { break }
        }
        if done, value > 0, isMuted(id) == true { setMuted(false, id) }
        return done
    }

    public static func isMuted(_ id: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: main)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    public static func setMuted(_ muted: Bool, _ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: main)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The main volume control if the device has one, else its first two
    /// channels (built-in speakers on some Macs, USB headsets).
    private static func volumeAddresses(_ id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let candidates = [main, 1, 2].map {
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: $0)
        }
        let present = candidates.filter { address in
            var address = address
            return AudioObjectHasProperty(id, &address)
        }
        return present.first?.mElement == main ? [present[0]] : present
    }

    /// Calls `handler` on the main queue when devices come or go or a
    /// default changes. Pass the returned token to `stopObserving`.
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, block)
        }
        return block
    }

    public static func stopObserving(_ block: @escaping AudioObjectPropertyListenerBlock) {
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
        }
    }

    private static let selectors = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    // MARK: CoreAudio access

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func canBeDefault(_ id: AudioObjectID, _ direction: Direction) -> Bool {
        !flag(id, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal)
            && flag(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, direction.scope)
    }

    private static func canBeSystemDefault(_ id: AudioObjectID) -> Bool {
        flag(id, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput)
    }

    private static func flag(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: main)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}
