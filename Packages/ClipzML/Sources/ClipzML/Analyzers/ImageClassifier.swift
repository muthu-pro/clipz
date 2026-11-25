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
        // Synchronous perform + read results — a completion handler plus a
        // catch-resume resumed the continuation twice on Vision errors.
        let req = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])

        let obs = req.results ?? []
        return obs
            .filter { Double($0.confidence) >= self.minConfidence }
            .prefix(self.maxResults)
            .map { ImageTag(identifier: $0.identifier, confidence: Double($0.confidence)) }
    }

    public struct ImageTag: Sendable {
        public let identifier: String
        public let confidence: Double
    }
}
