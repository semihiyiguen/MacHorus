// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// QR and bar codes and text in a copied image, read on the Mac with
/// Vision (no network, no permission). The result is only shown: a link in
/// a code is never opened, so a malicious QR code cannot lead anywhere by
/// itself.
public struct ImageText: Equatable, Sendable {
    public struct Code: Equatable, Sendable {
        public let payload: String
        /// The payload parses as a web or other link (shown, not opened).
        public let isLink: Bool
    }

    public let codes: [Code]
    /// Recognised text lines, top to bottom.
    public let lines: [String]

    public var isEmpty: Bool { codes.isEmpty && lines.isEmpty }

    /// Images larger than this many pixels on the long side are scaled down
    /// first: text stays readable and Vision needs far less memory.
    static let maximumSide = 4_096

    /// Blocking (tens to hundreds of ms): call off the main thread.
    public static func read(imageData: Data) -> ImageText? {
        guard let image = cgImage(from: imageData) else { return nil }
        let barcodes = VNDetectBarcodesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([barcodes, text])
        } catch {
            return nil
        }
        var seen = Set<String>()
        let codes = (barcodes.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
            .map { Code(payload: $0, isLink: isLink($0)) }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ImageText(codes: codes, lines: lines)
    }

    /// A scheme and something after it, e.g. https://…, mailto:…, WIFI:…
    static func isLink(_ payload: String) -> Bool {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme, !scheme.isEmpty
        else { return false }
        return payload.count > scheme.count + 1
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
