// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision

/// Whole-image multi-label classification via `VNClassifyImageRequest`.
/// No bounding boxes — Apple's classifier reports what's in the image,
/// not where. For things-with-location (animals, humans, text, barcodes)
/// use the dedicated detectors.
public struct ImageClassifier: Sendable {
    public let minConfidence: Double
    public let maxResults: Int

    public init(minConfidence: Double = 0.30, maxResults: Int = 10) {
        self.minConfidence = minConfidence
        self.maxResults = maxResults
    }

    public func classify(cgImage: CGImage) async throws -> [ImageTag] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNClassifyImageRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let obs = (request.results as? [VNClassificationObservation]) ?? []
                let tags: [ImageTag] = obs
                    .filter { Double($0.confidence) >= self.minConfidence }
                    .prefix(self.maxResults)
                    .map {
                        ImageTag(
                            identifier: $0.identifier,
                            confidence: Double($0.confidence)
                        )
                    }
                cont.resume(returning: tags)
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:])
                    .perform([req])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    public struct ImageTag: Sendable {
        public let identifier: String
        public let confidence: Double
    }
}
