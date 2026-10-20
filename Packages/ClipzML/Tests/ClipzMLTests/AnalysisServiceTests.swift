// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os
import Testing
@testable import ClipzCore
@testable import ClipzML

/// Driving AnalysisService with a mock MLPipeline so the DB-writing
/// paths are exercised without invoking Vision (which isn't reliable
/// in CI / headless environments).
@Suite("AnalysisService")
struct AnalysisServiceTests {

    // MARK: - Mock

    final class MockPipeline: MLPipeline, Sendable {
        let image: ImageAnalysis?
        let video: ImageAnalysis?
        let pdf: DocumentAnalysis?
        let doc: DocumentAnalysis?

        /// async-safe counter; NSLock isn't usable across awaits.
        private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)

        var imageCallCount: Int { counter.withLock { $0 } }

        init(
            image: ImageAnalysis? = nil,
            video: ImageAnalysis? = nil,
            pdf: DocumentAnalysis? = nil,
            doc: DocumentAnalysis? = nil
        ) {
            self.image = image
            self.video = video
            self.pdf = pdf
            self.doc = doc
        }

        func analyzeImage(fileURL: URL) async throws -> ImageAnalysis {
            counter.withLock { $0 += 1 }
            return image ?? ImageAnalysis()
        }

        func analyzeVideo(fileURL: URL) async throws -> ImageAnalysis {
            video ?? ImageAnalysis()
        }

        func analyzePDF(fileURL: URL) async throws -> DocumentAnalysis {
            pdf ?? DocumentAnalysis(fullText: "")
        }

        func analyzeDocument(fileURL: URL) async throws -> DocumentAnalysis {
            doc ?? DocumentAnalysis(fullText: "")
        }
    }

    // MARK: - Harness

    final class Bench {
        let tempDir: URL
        let db: AppDatabase
        let fileStore: FileStore
        let service: AnalysisService
        let pipeline: MockPipeline

        init(pipeline: MockPipeline = MockPipeline()) throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipz-ml-\(UUID().uuidString)")
            self.tempDir = tmp
            self.db = try AppDatabase.makeInMemory()
            self.fileStore = try FileStore(rootDir: tmp)
            self.pipeline = pipeline
            self.service = AnalysisService(
                database: db,
                fileStore: fileStore,
                pipeline: pipeline
            )
        }

        deinit { try? FileManager.default.removeItem(at: tempDir) }

        /// Write a clipboard-items row with an accompanying media file so
        /// AnalysisService has something to look up and analyze.
        func seedImageItem(id: String = UUID().uuidString) async throws -> String {
            let filename = "\(id).png"
            try fileStore.writeMedia(data: Data([0x89, 0x50]), filename: filename)
            try await db.write { db in
                try ClipboardItemRow(
                    id: id,
                    type: ClipboardKind.image.rawValue,
                    content: filename,
                    createdAt: Int64(Date().timeIntervalSince1970 * 1000)
                ).insert(db)
            }
            return id
        }

        /// Seed a video-kind row + dummy media file.
        func seedVideoItem(id: String = UUID().uuidString) async throws -> String {
            let filename = "\(id).mov"
            try fileStore.writeMedia(data: Data([0x00, 0x00]), filename: filename)
            try await db.write { db in
                try ClipboardItemRow(
                    id: id,
                    type: ClipboardKind.video.rawValue,
                    content: filename,
                    createdAt: Int64(Date().timeIntervalSince1970 * 1000)
                ).insert(db)
            }
            return id
        }
    }

    // MARK: - Tests

    @Test func videoAnalysisWritesOcrAndDetections() async throws {
        // Mock the frame-merged result so the test doesn't depend on real
        // AVFoundation frame extraction.
        let mock = MockPipeline(video: ImageAnalysis(
            ocr: [
                .init(text: "Build succeeded", confidence: 0.9,
                      bbox: BoundingBox(x: 0.1, y: 0.1, width: 0.4, height: 0.05),
                      time: 12.5)
            ],
            objects: [
                .init(identifier: "keyboard", confidence: 0.6,
                      bbox: BoundingBox(x: 0.2, y: 0.7, width: 0.5, height: 0.2))
            ]
        ))
        let b = try Bench(pipeline: mock)
        let id = try await b.seedVideoItem()
        await b.service.process(AnalysisJob(itemID: id, kind: .video))

        let (ocrCount, detCount, frameTime) = try await b.db.read { db -> (Int, Int, Double?) in
            let ocr = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ? AND kind = 'text'",
                arguments: [id]) ?? 0
            let det = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM detections WHERE item_id = ?",
                arguments: [id]) ?? 0
            let ft = try Double.fetchOne(db,
                sql: "SELECT frame_time FROM ocr_results WHERE item_id = ? AND kind = 'text'",
                arguments: [id])
            return (ocr, det, ft)
        }
        #expect(ocrCount == 1, "video OCR row persisted")
        #expect(detCount == 1, "video object detection persisted")
        #expect(frameTime == 12.5, "OCR frame timestamp persisted for seeking")

        let flags = try await b.db.read { db -> (Int, Int) in
            let row = try #require(try ClipboardItemRow.fetchOne(db, key: id))
            return (row.analysisTextDone, row.analysisObjectDone)
        }
        #expect(flags.0 == 1 && flags.1 == 1)
    }

    @Test func mergeDedupesAcrossFrames() async throws {
        let frameA = ImageAnalysis(
            ocr: [.init(text: "Hello", confidence: 0.8,
                        bbox: BoundingBox(x: 0, y: 0, width: 0.1, height: 0.1))],
            tags: [.init(identifier: "screen", confidence: 0.5)],
            objects: [.init(identifier: "laptop", confidence: 0.6,
                            bbox: BoundingBox(x: 0, y: 0, width: 0.2, height: 0.2))]
        )
        let frameB = ImageAnalysis(
            ocr: [.init(text: "hello", confidence: 0.9,   // dup (case-insensitive)
                        bbox: BoundingBox(x: 0, y: 0, width: 0.1, height: 0.1))],
            tags: [.init(identifier: "screen", confidence: 0.9)],  // higher conf wins
            objects: [.init(identifier: "laptop", confidence: 0.7, // dup class
                            bbox: BoundingBox(x: 0, y: 0, width: 0.2, height: 0.2))]
        )
        let merged = VisionMLPipeline.merge([frameA, frameB])
        #expect(merged.ocr.count == 1, "case-insensitive OCR dedupe")
        #expect(merged.objects.count == 1, "object class deduped across frames")
        #expect(merged.tags.count == 1)
        #expect(merged.tags.first?.confidence == 0.9, "keeps highest-confidence tag")
    }

    @Test func imageAnalysisWritesOcrBarcodeTagsAndDetections() async throws {
        let mock = MockPipeline(image: ImageAnalysis(
            ocr: [
                .init(text: "hello swift",
                      confidence: 0.95,
                      bbox: BoundingBox(x: 0.1, y: 0.1, width: 0.3, height: 0.05))
            ],
            barcodes: [
                .init(symbology: "QR", payload: "https://clipz.tech",
                      confidence: 0.99,
                      bbox: BoundingBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
            ],
            tags: [
                .init(identifier: "laptop", confidence: 0.7),
                .init(identifier: "indoor", confidence: 0.8)
            ],
            animals: [
                .init(identifier: "cat", confidence: 0.85,
                      bbox: BoundingBox(x: 0.2, y: 0.2, width: 0.3, height: 0.4))
            ],
            humans: [
                .init(identifier: "person", confidence: 0.9,
                      bbox: BoundingBox(x: 0, y: 0, width: 0.5, height: 1.0))
            ],
            objects: [
                .init(identifier: "bottle", confidence: 0.6,
                      bbox: BoundingBox(x: 0.6, y: 0.1, width: 0.15, height: 0.4))
            ]
        ))

        let b = try Bench(pipeline: mock)
        let id = try await b.seedImageItem()
        await b.service.process(AnalysisJob(itemID: id, kind: .image))

        let counts = try await b.db.read { db -> (Int, Int, Int, Int) in
            let ocrCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ? AND kind = 'text'",
                arguments: [id]) ?? 0
            let barCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ? AND kind = 'barcode'",
                arguments: [id]) ?? 0
            let detCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM detections WHERE item_id = ?",
                arguments: [id]) ?? 0
            let classCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM object_classes") ?? 0
            return (ocrCount, barCount, detCount, classCount)
        }
        #expect(counts.0 == 1, "one OCR row")
        #expect(counts.1 == 1, "one barcode row")
        // 2 tags + 1 animal + 1 human + 1 object = 5 detection rows.
        #expect(counts.2 == 5)
        // 2 tag classes + cat + person + bottle = 5 distinct classes.
        #expect(counts.3 == 5)

        // The salient-object detection persisted with its bounding box
        // (tags are boxless; objects/animals/humans carry one).
        let boxedObject = try await b.db.read { db -> Int in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM detections d
                JOIN object_classes c ON c.class_id = d.class_id
                WHERE d.item_id = ? AND c.class_name = 'bottle'
                  AND d.bbox_x IS NOT NULL
                """, arguments: [id]) ?? 0
        }
        #expect(boxedObject == 1, "object detection stored with a bbox")

        // The row's analysis_*_done flags flipped.
        let flags = try await b.db.read { db -> (Int, Int) in
            let row = try #require(try ClipboardItemRow.fetchOne(db, key: id))
            return (row.analysisTextDone, row.analysisObjectDone)
        }
        #expect(flags.0 == 1)
        #expect(flags.1 == 1)

        #expect(b.pipeline.imageCallCount == 1)
    }

    @Test func textKindSkipsAnalysisButMarksDone() async throws {
        let b = try Bench()
        let id = UUID().uuidString
        try await b.db.write { db in
            try ClipboardItemRow(
                id: id,
                type: ClipboardKind.text.rawValue,
                content: "just text",
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            ).insert(db)
        }

        await b.service.process(AnalysisJob(itemID: id, kind: .text))

        let flags = try await b.db.read { db -> (Int, Int) in
            let row = try #require(try ClipboardItemRow.fetchOne(db, key: id))
            return (row.analysisTextDone, row.analysisObjectDone)
        }
        #expect(flags.0 == 1)
        #expect(flags.1 == 1)
        #expect(b.pipeline.imageCallCount == 0)
    }

    @Test func pdfAnalysisWritesDocumentTextAndPages() async throws {
        let mock = MockPipeline(pdf: DocumentAnalysis(
            fullText: "Page 1 body\n\nPage 2 body",
            pages: ["Page 1 body", "Page 2 body"]
        ))
        let b = try Bench(pipeline: mock)
        let id = UUID().uuidString
        let filename = "\(id).pdf"
        try b.fileStore.writeMedia(data: Data([0x25, 0x50]), filename: filename)
        try await b.db.write { db in
            try ClipboardItemRow(
                id: id,
                type: ClipboardKind.pdf.rawValue,
                content: filename,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            ).insert(db)
        }

        await b.service.process(AnalysisJob(itemID: id, kind: .pdf))

        let storedText: String? = try await b.db.read { db in
            try String.fetchOne(db,
                sql: "SELECT full_text FROM document_text WHERE item_id = ?",
                arguments: [id])
        }
        #expect(storedText == "Page 1 body\n\nPage 2 body")
    }

    @Test func reanalyzeClearsRowsAndResetsDoneFlags() async throws {
        let mock = MockPipeline(image: ImageAnalysis(
            ocr: [.init(text: "first pass", confidence: 0.9,
                        bbox: BoundingBox(x: 0, y: 0, width: 1, height: 1))]
        ))
        let b = try Bench(pipeline: mock)
        let id = try await b.seedImageItem()

        // First pass — analysis writes 1 OCR row, flips done flags.
        await b.service.process(AnalysisJob(itemID: id, kind: .image))
        let firstCount = try await b.db.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ?",
                arguments: [id]) ?? 0
        }
        #expect(firstCount == 1)

        // reanalyze wipes prior rows and re-queues.
        try await b.service.reanalyze(itemID: id)
        let midCount = try await b.db.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ?",
                arguments: [id]) ?? 0
        }
        #expect(midCount == 0)
        #expect(await b.service.queueDepth() == 1)
    }

    @Test func enqueueIsDedupedByItemID() async throws {
        let b = try Bench()
        await b.service.enqueue(itemID: "x", kind: .text)
        await b.service.enqueue(itemID: "x", kind: .text)
        await b.service.enqueue(itemID: "y", kind: .text)
        #expect(await b.service.queueDepth() == 2)
    }
}
