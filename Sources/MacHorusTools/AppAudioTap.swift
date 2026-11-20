// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Foundation

/// Turns one app's sound down or off with a Core Audio process tap
/// (macOS 14.2+, the minimum MacHorus runs on). The approach follows Vorssaint's `AppVolumeMixer`
/// (GPL-3.0): a tap that mutes the app's own output while it is read, and a
/// private aggregate device that plays the tapped sound again at the chosen
/// level. MacHorus never raises a level above 100 %, so no limiter is needed.
///
/// macOS asks once for "System Audio Recording" (only for the first tap);
/// without consent creating the tap fails and the app plays unchanged. A tap
/// lives only as long as this process: if MacHorus ends, macOS gives every
/// app its sound back.
public final class AppAudioTap: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// Usually no consent for system audio recording.
        case tapRefused(OSStatus)
        case setupFailed(OSStatus)
    }

    /// Values the audio thread reads and the main thread writes, one word
    /// each, so neither ever waits.
    private final class Shared: Sendable {
        let gainBits = AtomicUInt32(Float(1).bitPattern)
        /// The level the last cycle ended at (audio thread only): a change
        /// glides over one cycle instead of jumping (no clicks while dragging).
        let appliedGainBits = AtomicUInt32(Float.nan.bitPattern)
        let cycles = AtomicUInt64(0)
        let inputPeakBits = AtomicUInt32(0)
        let outputPeakBits = AtomicUInt32(0)
    }

    public let objects: [AudioObjectID]
    /// The device the app plays on through this tap.
    public let outputDeviceUID: String?
    private let shared = Shared()
    /// Only touched on the creating thread and in `stop`, which callers run
    /// on one serial queue; the audio thread never sees them.
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let stopped = AtomicFlag(false)

    private static let teardownQueue = DispatchQueue(label: "app.machorus.tools.audio.teardown", qos: .utility)

    /// Plays the app at `gain` (0…1) on the device with `outputDeviceUID`.
    public init(objects: [AudioObjectID], gain: Float, outputDeviceUID: String) throws(Failure) {
        self.objects = objects
        self.outputDeviceUID = outputDeviceUID
        self.gain = gain
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != 0 else { throw .tapRefused(status) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacHorus",
            kAudioAggregateDeviceUIDKey: "app.machorus.tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var device = AudioObjectID(0)
        var result = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard result == noErr, device != 0 else {
            stop()
            throw .setupFailed(result)
        }
        aggregateID = device

        let tapChannels = Self.channels(ofTap: tap)
        // A stereo mixdown loses level on outputs wider than stereo; this
        // gives it back (Vorssaint measured it, `tapLevelCompensation`).
        let compensation = Float(min(max(Double(Self.firstStreamWidth(of: device)) / 2, 1), 4))
        let shared = self.shared
        var proc: AudioDeviceIOProcID?
        result = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            let gain = Float(bitPattern: shared.gainBits.load()) * compensation
            let applied = Float(bitPattern: shared.appliedGainBits.load())
            let peaks = Self.render(
                input: input, output: output, tapChannels: tapChannels, from: applied.isNaN ? gain : applied, to: gain)
            shared.appliedGainBits.store(gain.bitPattern)
            shared.cycles.add(1)
            shared.inputPeakBits.store(peaks.input.bitPattern)
            shared.outputPeakBits.store(peaks.output.bitPattern)
        }
        guard result == noErr, let proc else {
            stop()
            throw .setupFailed(result)
        }
        ioProc = proc
        result = AudioDeviceStart(device, proc)
        guard result == noErr else {
            stop()
            throw .setupFailed(result)
        }
    }

    deinit { stop() }

    /// Asks macOS for "System Audio Recording" without touching any app's
    /// sound: a private global tap that plays on unchanged is created and
    /// removed at once. Shows the consent dialog only while undecided; can
    /// wait for the answer, so never call it on the main thread.
    public static func requestAccess() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != 0 else { return false }
        AudioHardwareDestroyProcessTap(tap)
        return true
    }

    /// 0…1; ignored by a mute.
    public var gain: Float {
        get { Float(bitPattern: shared.gainBits.load()) }
        set { shared.gainBits.store(min(max(newValue, 0), 1).bitPattern) }
    }

    /// Completed audio cycles. A count that stops while the app plays means
    /// the device stopped rendering; then the app would stay silent.
    public var renderCycles: UInt64 { shared.cycles.load() }

    /// Loudest sample of the last cycle before and after the level, for the
    /// self-test (`--mixer-selftest`).
    public var lastPeaks: (input: Float, output: Float) {
        (
            Float(bitPattern: shared.inputPeakBits.load()),
            Float(bitPattern: shared.outputPeakBits.load())
        )
    }

    /// Hands the sound back at once; the rest of the teardown, which can
    /// wait on a busy audio system, runs off the caller's thread.
    public func stop() {
        guard !stopped.exchange(true) else { return }
        let tap = tapID
        let device = aggregateID
        let proc = ioProc
        if let proc, device != 0 { AudioDeviceStop(device, proc) }
        Self.teardownQueue.async {
            if let proc, device != 0 { AudioDeviceDestroyIOProcID(device, proc) }
            if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
            if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        }
    }

    // MARK: Rendering (audio thread: no allocation, no locks)

    static func render(
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, tapChannels: Int,
        gain: Float
    ) -> (input: Float, output: Float) {
        render(input: input, output: output, tapChannels: tapChannels, from: gain, to: gain)
    }

    /// Copies the tap's samples into the output, the level moving linearly
    /// from `start` to `end` over the cycle; frames and channels without a
    /// source are silenced (the buffer arrives dirty).
    static func render(
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, tapChannels: Int,
        from start: Float, to end: Float
    ) -> (input: Float, output: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var sourceIndex: Int?
        for index in stride(from: inputs.count - 1, through: 0, by: -1)
        where inputs[index].mData != nil && Int(inputs[index].mNumberChannels) == tapChannels {
            sourceIndex = index
            break
        }
        if sourceIndex == nil, inputs.count == 1, inputs[0].mData != nil { sourceIndex = 0 }
        guard let sourceIndex, let source = inputs[sourceIndex].mData?.assumingMemoryBound(to: Float.self) else {
            silence(outputs)
            return (0, 0)
        }
        let sourceChannels = max(1, Int(inputs[sourceIndex].mNumberChannels))
        let sourceFrames = Int(inputs[sourceIndex].mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
        var inputPeak: Float = 0
        var outputPeak: Float = 0
        var firstChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                firstChannel += channels
                continue
            }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let step = frames > 1 ? (end - start) / Float(frames - 1) : 0
            for frame in 0..<frames {
                let gain = frames > 1 ? start + step * Float(frame) : end
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    guard frame < sourceFrames, let from = sourceChannel(firstChannel + channel, of: sourceChannels)
                    else {
                        destination[index] = 0
                        continue
                    }
                    let sample = source[frame * sourceChannels + from]
                    let level = sample * gain
                    destination[index] = level
                    inputPeak = max(inputPeak, abs(sample))
                    outputPeak = max(outputPeak, abs(level))
                }
            }
            firstChannel += channels
        }
        return (inputPeak, outputPeak)
    }

    /// The tap channel feeding an output channel: same index, a mono source
    /// in both front channels, nothing for channels beyond the source.
    static func sourceChannel(_ outputChannel: Int, of sourceChannels: Int) -> Int? {
        if outputChannel < sourceChannels { return outputChannel }
        if sourceChannels == 1, outputChannel == 1 { return 0 }
        return nil
    }

    private static func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    // MARK: Device facts

    private static func channels(ofTap tap: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mChannelsPerFrame > 0
        else { return 2 }
        return Int(format.mChannelsPerFrame)
    }

    /// Channels of the first output stream; 2 when it cannot be read.
    private static func firstStreamWidth(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 2 }
        let list = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 2 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.first.map { max(Int($0.mNumberChannels), 2) } ?? 2
    }

    /// The UID of the current default output device.
    public static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != 0
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
