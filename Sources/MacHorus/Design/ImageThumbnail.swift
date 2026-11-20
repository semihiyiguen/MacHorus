// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit

/// Small bitmaps of large icons, drawn once. Letting SwiftUI scale a
/// 1024-pixel icon cost a high-quality resample on every redraw (about
/// 8 ms per panel opening for the header icon alone).
@MainActor
enum ImageThumbnail {
    static let appIcon = make(NSApp.applicationIconImage, points: 34)

    static func make(_ source: NSImage, points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return source }
        // The point size must be set before the context exists, otherwise
        // the context works in pixels and the icon fills a quarter.
        bitmap.size = NSSize(width: points, height: points)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
