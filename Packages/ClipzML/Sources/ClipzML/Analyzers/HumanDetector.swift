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
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectHumanRectanglesRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let obs = (request.results as? [VNHumanObservation]) ?? []
                let results: [HumanDetection] = obs
                    .filter { Double($0.confidence) >= self.minConfidence }
                    .map {
                        HumanDetection(
                            confidence: Double($0.confidence),
                            bbox: OCRAnalyzer.normalizedTopLeftBBox($0.boundingBox)
                        )
                    }
                cont.resume(returning: results)
            }
            req.upperBodyOnly = upperBodyOnly
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:])
                    .perform([req])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    public struct HumanDetection: Sendable {
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
