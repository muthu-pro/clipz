// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision
import CoreGraphics
import ClipzCore

/// General-purpose object detection built entirely on Apple Vision — no
/// CoreML model bundled. Two stages, both on-device and offline:
///
///   1. `VNGenerateObjectnessBasedSaliencyImageRequest` locates the most
///      salient object regions and returns their bounding boxes.
///   2. Each region is cropped out and run through `VNClassifyImageRequest`
///      to attach a label (e.g. "laptop", "coffee", "plant").
///
/// Saliency surfaces only the handful of most prominent objects rather
/// than an exhaustive scene parse, but it yields *labeled bounding boxes
/// for arbitrary objects* — which the built-in `AnimalDetector` /
/// `HumanDetector` (cats, dogs, people only) and the whole-image
/// `ImageClassifier` (labels but no boxes) can't do on their own.
public struct ObjectDetector: Sendable {
    /// Salient regions below this objectness confidence are dropped.
    public let minSaliencyConfidence: Double
    /// Hard cap on boxes returned per image (saliency rarely exceeds ~3).
    public let maxObjects: Int
    /// Reused to label each cropped region. A low threshold / top-1 config
    /// since we only want the single best guess for the crop.
    private let classifier: ImageClassifier

    public init(
        minSaliencyConfidence: Double = 0.10,
        maxObjects: Int = 5,
        classifier: ImageClassifier = ImageClassifier(minConfidence: 0.15, maxResults: 1)
    ) {
        self.minSaliencyConfidence = minSaliencyConfidence
        self.maxObjects = maxObjects
        self.classifier = classifier
    }

    public func detect(cgImage: CGImage) async throws -> [ObjectDetection] {
        let boxes = try await salientBoxes(in: cgImage)
        var out: [ObjectDetection] = []
        for box in boxes.prefix(maxObjects) {
            // `box.rect` is normalized with a bottom-left origin.
            let label = await labelForRegion(box.rect, in: cgImage)
            out.append(
                ObjectDetection(
                    // Fall back to a generic "object" so a salient region we
                    // can't confidently label still gets a box.
                    identifier: label?.identifier ?? "object",
                    confidence: label?.confidence ?? Double(box.confidence),
                    bbox: OCRAnalyzer.normalizedTopLeftBBox(box.rect)
                )
            )
        }
        return out
    }

    // MARK: - Stage 1: saliency

    /// Sendable snapshot of a salient region — `VNRectangleObservation`
    /// itself isn't Sendable, so we lift the box + confidence out inside
    /// the Vision completion handler before crossing the continuation.
    private struct SalientBox: Sendable {
        let rect: CGRect
        let confidence: Float
    }

    private func salientBoxes(in cgImage: CGImage) async throws -> [SalientBox] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNGenerateObjectnessBasedSaliencyImageRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let saliency = (request.results as? [VNSaliencyImageObservation])?.first
                let objects = saliency?.salientObjects ?? []
                let filtered: [SalientBox] = objects
                    .filter { Double($0.confidence) >= self.minSaliencyConfidence }
                    .map { SalientBox(rect: $0.boundingBox, confidence: $0.confidence) }
                cont.resume(returning: filtered)
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Stage 2: per-region label

    private func labelForRegion(
        _ normRect: CGRect, in cgImage: CGImage
    ) async -> ImageClassifier.ImageTag? {
        guard let crop = Self.crop(cgImage, to: normRect),
              let tags = try? await classifier.classify(cgImage: crop)
        else { return nil }
        return tags.first
    }

    /// Crop `cgImage` to a Vision-normalized rect (origin bottom-left).
    /// CGImage pixels use a top-left origin, so the Y axis is flipped.
    /// Returns nil for degenerate or out-of-bounds rects.
    static func crop(_ cgImage: CGImage, to normRect: CGRect) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normRect.origin.x * w,
            y: (1 - normRect.origin.y - normRect.height) * h,
            width: normRect.width * w,
            height: normRect.height * h
        ).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return cgImage.cropping(to: pixelRect)
    }

    public struct ObjectDetection: Sendable {
        /// Vision classifier label for the region (e.g. `laptop`), or
        /// `"object"` when no confident label was found. Stored in
        /// `object_classes.class_name`.
        public let identifier: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
