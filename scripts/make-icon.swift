// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors
//
// Renders the app icon (gold eye on a lapis squircle) into an .iconset and
// converts it to Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]

import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("MacHorus-\(UUID().uuidString).iconset")

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Cannot allocate bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // macOS icon grid: the shape covers ~80 % of the canvas, corner radius ~22.4 %.
    let inset = size * 0.1
    let shape = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(
        roundedRect: shape, xRadius: shape.width * 0.224, yRadius: shape.width * 0.224)
    NSGradient(starting: color(0x2B4FB8), ending: color(0x0B1A45))?.draw(in: squircle, angle: -90)

    // Thin gold rim.
    color(0xE7B940).withAlphaComponent(0.55).setStroke()
    squircle.lineWidth = max(1, size * 0.008)
    squircle.stroke()

    // Gold eye, drawn from the SF Symbol and tinted via a mask.
    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    {
        let symbolSize = symbol.size
        let target = NSRect(
            x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
            width: symbolSize.width, height: symbolSize.height)
        let tinted = NSImage(size: symbolSize, flipped: false) { rect in
            NSGradient(starting: color(0xFBE08A), ending: color(0xC9952B))?.draw(in: rect, angle: -90)
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    return png
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try render(pixels: points * scale).write(to: file)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
