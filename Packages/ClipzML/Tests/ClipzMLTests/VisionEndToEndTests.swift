// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClipzML

/// End-to-end smoke test for the real `VisionMLPipeline`. Renders a
/// PNG with known text and verifies that OCR reads it back. This is
/// the test that would catch "the whole analysis pipeline is wired
/// but Vision silently returns nothing" — the unit tests in
/// `AnalysisServiceTests` use a mock pipeline and can't see that.
@Suite("VisionMLPipeline end-to-end")
struct VisionEndToEndTests {

    @Test("OCR reads back text that was rendered into a PNG")
    func ocrRoundTripsRenderedText() async throws {
        let phrase = "CLIPZ OCR TEST"
        let url = try renderText(phrase, toTempPNG: "ocr_roundtrip.png")
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await VisionMLPipeline().analyzeImage(fileURL: url)

        let recognised = analysis.ocr
            .map { $0.text.uppercased() }
            .joined(separator: " ")
        #expect(recognised.contains("CLIPZ"),
                "Expected Vision OCR to find the rendered phrase; got \(analysis.ocr.map(\.text))")
    }

    // MARK: - Helpers

    /// Draws `phrase` into an offscreen CGContext and writes a PNG to
    /// a temporary file. Uses CoreText directly instead of
    /// `NSImage.lockFocus` because the latter needs a display context
    /// and fails when tests run under `swift test`.
    private func renderText(_ phrase: String, toTempPNG name: String) throws -> URL {
        let width = 800
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.contextFailed }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let attributed = NSAttributedString(string: phrase, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, ctx)
        let x = (CGFloat(width) - bounds.width) / 2 - bounds.origin.x
        let y = (CGFloat(height) - bounds.height) / 2 - bounds.origin.y
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { throw TestError.contextFailed }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipzMLTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw TestError.encodeFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestError.encodeFailed }
        return url
    }

    private enum TestError: Error {
        case contextFailed
        case encodeFailed
    }
}
