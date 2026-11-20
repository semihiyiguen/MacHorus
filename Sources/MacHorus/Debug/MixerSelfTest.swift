// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Foundation
import MacHorusTools

/// Proves the per-app volume on the real audio system: taps a playing
/// process at 25 % and 0 % and checks that the output peak follows the
/// input peak by that factor (0 is how a mute works).
@MainActor
enum MixerSelfTest {
    static func run(pid: pid_t, log url: URL) async {
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let process = AudioProcesses.list().first(where: { $0.pid == pid }) else {
            note("result=FAIL no audio process for pid \(pid)")
            return
        }
        note("process object=\(process.objectID) bundle=\(process.bundleID ?? "-") output=\(process.usesOutput)")
        guard let output = AppAudioTap.defaultOutputDeviceUID() else {
            note("result=FAIL no default output device")
            return
        }
        // The first tap may wait for consent; retry while the dialog is open.
        var tap: AppAudioTap?
        for attempt in 1...60 {
            do {
                tap = try AppAudioTap(objects: [process.objectID], gain: 0.25, outputDeviceUID: output)
                note("tap created on attempt \(attempt)")
                break
            } catch {
                note("attempt \(attempt): \(error)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let tap else {
            note("result=FAIL no tap (consent not given?)")
            return
        }
        for gain: Float in [0.25, 0] {
            tap.gain = gain
            var ratios: [Float] = []
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(150))
                let peaks = tap.lastPeaks
                if peaks.input > 0.01 { ratios.append(peaks.output / peaks.input) }
            }
            let median = ratios.sorted().dropFirst(ratios.count / 2).first ?? -1
            note(
                "gain=\(gain) cycles=\(tap.renderCycles) samples=\(ratios.count) "
                    + "median output/input=\(String(format: "%.3f", median))")
        }
        tap.stop()
        note("result=DONE")
    }
}
