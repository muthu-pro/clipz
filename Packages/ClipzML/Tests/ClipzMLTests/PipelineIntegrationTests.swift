// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Testing
import ClipzCore
@testable import ClipzML

/// Full-pipeline smoke test: a real `ClipboardService.capture()` call
/// feeds a real `AnalysisService` (with the real `VisionMLPipeline`);
/// once analysis lands, `SearchEngine.search()` must find the image
/// by its OCR'd text. If this passes, the whole "copy an image →
/// search by what's in it" user flow is working end-to-end.
@Suite("Analysis pipeline integration")
struct PipelineIntegrationTests {

    @Test("Capture → Vision → FTS → search finds OCR'd phrase")
    func captureAndSearchRoundTrip() async throws {
        let phrase = "ClipzFlow2026"

        // Stand up a full stack against an in-memory DB + tmp FileStore.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipz-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try AppDatabase.makeInMemory()
        let fileStore = try FileStore(rootDir: tmp)
        let settings = SettingsStore(database: db)
        let broadcaster = EventBroadcaster()
        let analysis = AnalysisService(database: db, fileStore: fileStore)
        let clipboard = ClipboardService(
            database: db,
            fileStore: fileStore,
            broadcaster: broadcaster,
            settings: settings,
            analysisEnqueuer: analysis
        )
        let search = SearchEngine(database: db)

        // Render a PNG with known text and capture it as an image clip.
        let pngURL = try renderText(phrase)
        let pngData = try Data(contentsOf: pngURL)
        let payload = ClassifiedPayload(
            kind: .image,
            data: .imageData(pngData, ext: "png")
        )
        let captured = try #require(
            await clipboard.capture(payload)
        )

        // Run the analysis job synchronously so the test doesn't race
        // the background loop.
        await analysis.process(AnalysisJob(itemID: captured.id, kind: .image))

        // Now search by the OCR'd phrase. With `clipboard_fts` using
        // trigram tokenization, a partial substring match is enough.
        let results = try await search.search(
            query: phrase,
            kindFilter: nil
        )
        let hitIDs = results.results.map(\.item.id)
        #expect(hitIDs.contains(captured.id),
                "Search for \(phrase) should surface the captured image; got \(hitIDs)")
    }

    @Test("Detected object class name is searchable")
    func detectedObjectIsSearchable() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipz-obj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try AppDatabase.makeInMemory()
        let fileStore = try FileStore(rootDir: tmp)
        let settings = SettingsStore(database: db)
        let broadcaster = EventBroadcaster()

        // Mock the pipeline so the test is deterministic (doesn't depend on
        // Vision actually finding an "umbrella" in the pixels) — we only
        // care that a written detection class becomes searchable.
        let mock = AnalysisServiceTests.MockPipeline(image: ImageAnalysis(
            objects: [
                .init(identifier: "umbrella", confidence: 0.7,
                      bbox: BoundingBox(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
            ]
        ))
        let analysis = AnalysisService(database: db, fileStore: fileStore, pipeline: mock)
        let clipboard = ClipboardService(
            database: db,
            fileStore: fileStore,
            broadcaster: broadcaster,
            settings: settings,
            analysisEnqueuer: analysis
        )
        let search = SearchEngine(database: db)

        let pngData = try Data(contentsOf: try renderText("img"))
        let captured = try #require(
            await clipboard.capture(
                ClassifiedPayload(kind: .image, data: .imageData(pngData, ext: "png"))
            )
        )
        await analysis.process(AnalysisJob(itemID: captured.id, kind: .image))

        let results = try await search.search(query: "umbrella", kindFilter: nil)
        #expect(results.results.map(\.item.id).contains(captured.id),
                "Search for a detected object's class name should surface the image")
    }

    // MARK: - Helpers

    private func renderText(_ phrase: String) throws -> URL {
        let width = 800
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipz-integ-\(UUID().uuidString).png")
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
