// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreAudio
import Testing

@testable import MacHorusTools

/// The render step of the per-app volume, with real buffer lists.
@Suite struct AudioTapRenderTests {
    /// Buffers with interleaved samples; `channels` per buffer.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        init(_ buffers: [(channels: Int, samples: [Float])]) {
            list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            for (index, buffer) in buffers.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(buffer.samples.count, 1))
                data.initialize(from: buffer.samples, count: buffer.samples.count)
                storage.append(data)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(buffer.channels),
                    mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size), mData: data)
            }
        }

        func samples(_ index: Int) -> [Float] {
            let count = Int(list[index].mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: storage[index], count: count))
        }

        deinit {
            for data in storage { data.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    @Test func stereoAtHalfLevel() {
        let input = Buffers([(2, [0.5, -0.5, 1.0, -1.0])])
        let output = Buffers([(2, [9, 9, 9, 9])])
        let peaks = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, gain: 0.5)
        #expect(output.samples(0) == [0.25, -0.25, 0.5, -0.5])
        #expect(peaks.input == 1.0 && peaks.output == 0.5)
    }

    @Test func zeroGainIsSilence() {
        let input = Buffers([(2, [0.8, 0.8])])
        let output = Buffers([(2, [9, 9])])
        _ = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, gain: 0)
        #expect(output.samples(0) == [0, 0])
    }

    @Test func aLevelChangeGlidesOverTheCycle() {
        // Five stereo frames of full scale, the level going from 0 to 1.
        let input = Buffers([(2, Array(repeating: 1, count: 10))])
        let output = Buffers([(2, Array(repeating: 9, count: 10))])
        _ = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, from: 0, to: 1)
        let left = stride(from: 0, to: 10, by: 2).map { output.samples(0)[$0] }
        #expect(left == [0, 0.25, 0.5, 0.75, 1], "no jump: each frame a step of a quarter")
        #expect(output.samples(0)[1] == output.samples(0)[0], "both channels at the same level")
    }

    @Test func monoFeedsBothFrontChannelsAndWiderOutputsStaySilent() {
        let input = Buffers([(1, [0.4, 0.2])])
        let output = Buffers([(4, Array(repeating: 9, count: 8))])
        _ = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 1, gain: 1)
        #expect(output.samples(0) == [0.4, 0.4, 0, 0, 0.2, 0.2, 0, 0])
    }

    @Test func framesBeyondTheSourceAreSilenced() {
        // The output buffer arrives with old audio in it; nothing may play twice.
        let input = Buffers([(2, [0.1, 0.1])])
        let output = Buffers([(2, [9, 9, 9, 9])])
        _ = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, gain: 1)
        #expect(output.samples(0) == [0.1, 0.1, 0, 0])
    }

    @Test func noTapBufferMeansSilence() {
        // The aggregate's own input stream (wrong width) is not the tap.
        let input = Buffers([(6, Array(repeating: 0.7, count: 6)), (6, Array(repeating: 0.7, count: 6))])
        let output = Buffers([(2, [9, 9])])
        let peaks = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, gain: 1)
        #expect(output.samples(0) == [0, 0])
        #expect(peaks.output == 0)
    }

    @Test func splitOutputBuffersGetTheirOwnChannels() {
        let input = Buffers([(2, [0.3, 0.6])])
        let output = Buffers([(1, [9]), (1, [9])])
        _ = AppAudioTap.render(
            input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, tapChannels: 2, gain: 1)
        #expect(output.samples(0) == [0.3] && output.samples(1) == [0.6])
    }
}
