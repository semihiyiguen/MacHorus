// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MacHorusTools

@Suite struct ImageTextTests {
    /// A real QR code, drawn by Core Image, read back by Vision.
    @Test func readsAQRCodeAndMarksTheLinkWithoutOpeningIt() throws {
        let payload = "https://example.org/machorus?test=1"
        let data = try #require(Self.qrPNG(payload))
        let result = try #require(ImageText.read(imageData: data))
        #expect(result.codes == [ImageText.Code(payload: payload, isLink: true)])
    }

    @Test func linksNeedASchemeAndContent() {
        #expect(ImageText.isLink("https://example.org"))
        #expect(ImageText.isLink("WIFI:S:Net;T:WPA;P:x;;"))
        #expect(!ImageText.isLink("just words"))
        #expect(!ImageText.isLink("https:"))
    }

    @Test func noImageNoResult() {
        #expect(ImageText.read(imageData: Data("not an image".utf8)) == nil)
    }

    private static func qrPNG(_ text: String) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let small = filter.outputImage else { return nil }
        // Scaled up with a quiet zone, like a screenshot of a QR code.
        let image = small.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        let padded = image.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(
                over: CIImage(color: .white).cropped(
                    to: image.extent.insetBy(dx: -40, dy: -40).offsetBy(dx: 40, dy: 40)))
        guard let cg = context.createCGImage(padded, from: padded.extent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
