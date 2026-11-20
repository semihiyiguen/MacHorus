// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Keeps the GPU busy for scripts/dev/verify-monitor.py --thermal.
// Usage: gpu-load <seconds>

import Foundation
import Metal

guard let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init),
    let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
else {
    FileHandle.standardError.write(Data("usage: gpu-load <seconds> (needs a Metal GPU)\n".utf8))
    exit(2)
}
let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void load(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float x = float(id);
        for (int i = 0; i < 20000; i++) { x = sin(fma(x, 1.0001f, 0.5f)) * cos(x) + sqrt(abs(x)); }
        out[id] = x;
    }
    """
let pipeline = try device.makeComputePipelineState(
    function: try device.makeLibrary(source: source, options: nil).makeFunction(name: "load")!)
let count = 1 << 20
let buffer = device.makeBuffer(length: count * 4, options: .storageModePrivate)!
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(
        MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
}
