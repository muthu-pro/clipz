// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision
import ClipzCore

/// `VNDetectHumanRectanglesRequest` — bounding boxes around people in
/// the image. Stored under a synthetic class name `"person"` so search
/// for "people" / "selfie" via the synonym expander lands on these.
public struct HumanDetector: Sendable {
    public let minConfidence: Double
    public let upperBodyOnly: Bool

    public init(minConfidence: Double = 0.40, upperBodyOnly: Bool = false) {
        self.minConfidence = minConfidence
        self.upperBodyOnly = upperBodyOnly
    }

    public func detect(cgImage: CGImage) async throws -> [HumanDetection] {
        // Synchronous perform + read results — avoids the double continuation
        // resume (completion handler + catch) that crashed on Vision errors.
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = upperBodyOnly
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])

        let obs = req.results ?? []
        return obs
            .filter { Double($0.confidence) >= self.minConfidence }
            .map {
                HumanDetection(
                    confidence: Double($0.confidence),
                    bbox: OCRAnalyzer.normalizedTopLeftBBox($0.boundingBox)
                )
            }
    }

    public struct HumanDetection: Sendable {
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
