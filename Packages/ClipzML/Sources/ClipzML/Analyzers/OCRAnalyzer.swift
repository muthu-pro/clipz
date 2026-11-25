// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision
import ClipzCore

/// Wraps `VNRecognizeTextRequest`. One recognize-call per image; the
/// caller decides whether to run it alongside classification / animal /
/// human / barcode requests (see `VisionMLPipeline`).
public struct OCRAnalyzer: Sendable {
    public enum Level: Sendable { case fast, accurate }

    public let level: Level
    public let languages: [String]

    public init(level: Level = .accurate, languages: [String] = ["en-US"]) {
        self.level = level
        self.languages = languages
    }

    public func recognize(cgImage: CGImage) async throws -> [RecognizedText] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = (level == .fast) ? .fast : .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = languages
        req.minimumTextHeight = 0.015

        // Vision's `perform` is synchronous and populates `req.results`; using
        // a completion handler *and* catching the throw resumed the old
        // continuation twice (SWIFT TASK CONTINUATION MISUSE) when Vision
        // rejected an input — e.g. a too-small image. One throwing call, one
        // read: no double-resume possible.
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])

        let observations = req.results ?? []
        return observations.compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            return RecognizedText(
                text: best.string,
                confidence: Double(best.confidence),
                bbox: Self.normalizedTopLeftBBox(obs.boundingBox)
            )
        }
    }

    public struct RecognizedText: Sendable {
        public let text: String
        public let confidence: Double
        public let bbox: BoundingBox
    }

    /// Vision returns normalized CGRect with origin bottom-left. We flip
    /// to top-left origin so SwiftUI renders the bbox overlay without
    /// per-render coordinate conversion.
    static func normalizedTopLeftBBox(_ rect: CGRect) -> BoundingBox {
        BoundingBox(
            x: rect.origin.x,
            y: 1 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
