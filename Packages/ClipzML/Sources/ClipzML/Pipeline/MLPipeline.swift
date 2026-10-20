// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ClipzCore

/// Composite result of running every image analyzer against a single
/// image. Feeds `AnalysisService` which writes the individual rows to
/// the analysis tables.
public struct ImageAnalysis: Sendable {
    public let ocr: [OCRHit]
    public let barcodes: [BarcodeHit]
    public let tags: [TagHit]
    public let animals: [DetectionHit]
    public let humans: [DetectionHit]
    /// Arbitrary salient objects with labeled bounding boxes
    /// (saliency + per-region classification). Distinct from `tags`,
    /// which are whole-image labels with no box.
    public let objects: [DetectionHit]

    public init(
        ocr: [OCRHit] = [],
        barcodes: [BarcodeHit] = [],
        tags: [TagHit] = [],
        animals: [DetectionHit] = [],
        humans: [DetectionHit] = [],
        objects: [DetectionHit] = []
    ) {
        self.ocr = ocr
        self.barcodes = barcodes
        self.tags = tags
        self.animals = animals
        self.humans = humans
        self.objects = objects
    }

    /// Returns a copy with every OCR hit stamped with `time` (used by the
    /// video pipeline to record which frame each line came from).
    public func taggingOCR(time: Double) -> ImageAnalysis {
        ImageAnalysis(
            ocr: ocr.map {
                .init(text: $0.text, confidence: $0.confidence, bbox: $0.bbox, time: time)
            },
            barcodes: barcodes,
            tags: tags,
            animals: animals,
            humans: humans,
            objects: objects
        )
    }

    public struct OCRHit: Sendable {
        public let text: String
        public let confidence: Double
        public let bbox: BoundingBox
        /// Seconds into the source video this text was read from. `nil` for
        /// still images; set per-frame by `analyzeVideo`.
        public let time: Double?
        public init(text: String, confidence: Double, bbox: BoundingBox, time: Double? = nil) {
            self.text = text
            self.confidence = confidence
            self.bbox = bbox
            self.time = time
        }
    }

    public struct BarcodeHit: Sendable {
        public let symbology: String
        public let payload: String
        public let confidence: Double
        public let bbox: BoundingBox
        public init(symbology: String, payload: String, confidence: Double, bbox: BoundingBox) {
            self.symbology = symbology
            self.payload = payload
            self.confidence = confidence
            self.bbox = bbox
        }
    }

    /// Whole-image classification result — no bounding box.
    public struct TagHit: Sendable {
        public let identifier: String
        public let confidence: Double
        public init(identifier: String, confidence: Double) {
            self.identifier = identifier
            self.confidence = confidence
        }
    }

    /// Animal or human detection — identifier + confidence + bbox.
    public struct DetectionHit: Sendable {
        public let identifier: String
        public let confidence: Double
        public let bbox: BoundingBox
        public init(identifier: String, confidence: Double, bbox: BoundingBox) {
            self.identifier = identifier
            self.confidence = confidence
            self.bbox = bbox
        }
    }
}

/// Output of PDF / document extraction. `pages` is empty for docx/rtf;
/// `fullText` always holds the entire body (joined across pages for PDFs).
public struct DocumentAnalysis: Sendable, Equatable {
    public let fullText: String
    public let pages: [String]

    public init(fullText: String, pages: [String] = []) {
        self.fullText = fullText
        self.pages = pages
    }
}

/// Injection seam. `VisionMLPipeline` is the production implementation
/// that runs Apple Vision + PDFKit; tests pass a mock returning
/// pre-built ImageAnalysis values so the DB-writing paths are exercised
/// without actually running Vision (which needs GPU).
public protocol MLPipeline: Sendable {
    func analyzeImage(fileURL: URL) async throws -> ImageAnalysis
    /// Sample frames from a video and run the image analyzers over each,
    /// returning the merged/deduped result so on-screen text and objects
    /// become searchable.
    func analyzeVideo(fileURL: URL) async throws -> ImageAnalysis
    func analyzePDF(fileURL: URL) async throws -> DocumentAnalysis
    func analyzeDocument(fileURL: URL) async throws -> DocumentAnalysis
}

public extension MLPipeline {
    /// Default no-op so existing conformers (e.g. test mocks) don't have
    /// to implement video analysis. `VisionMLPipeline` overrides it.
    func analyzeVideo(fileURL: URL) async throws -> ImageAnalysis { ImageAnalysis() }
}
