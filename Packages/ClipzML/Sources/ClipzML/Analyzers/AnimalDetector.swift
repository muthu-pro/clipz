// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision
import ClipzCore

/// `VNRecognizeAnimalsRequest` — returns bboxes for cats and dogs. The
/// only two classes this request recognizes (as of macOS 14+). Anything
/// else falls through to whole-image classification.
public struct AnimalDetector: Sendable {
    public let minConfidence: Double

    public init(minConfidence: Double = 0.40) {
        self.minConfidence = minConfidence
    }

    public func detect(cgImage: CGImage) async throws -> [AnimalDetection] {
        // Synchronous perform + read results — avoids the double continuation
        // resume (completion handler + catch) that crashed on Vision errors.
        let req = VNRecognizeAnimalsRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])

        let obs = req.results ?? []
        return obs.compactMap { o in
            guard let best = o.labels.first,
                  Double(best.confidence) >= self.minConfidence
            else { return nil }
            return AnimalDetection(
                identifier: best.identifier.lowercased(),
                confidence: Double(best.confidence),
                bbox: OCRAnalyzer.normalizedTopLeftBBox(o.boundingBox)
            )
        }
    }

    public struct AnimalDetection: Sendable {
        /// `"cat"` or `"dog"` (normalized to lowercase). Stored in the
        /// `object_classes.class_name` column — the synonym expander in
        /// swift_08 uses "kitten" / "puppy" to match these.
        public let identifier: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
