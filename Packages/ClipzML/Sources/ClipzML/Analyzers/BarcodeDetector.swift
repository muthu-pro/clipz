// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Vision
import ClipzCore

/// `VNDetectBarcodesRequest` — reads QR, UPC, EAN, Code128/39, PDF417,
/// DataMatrix, Aztec. Stored in `ocr_results` with `kind = 'barcode'`
/// alongside text OCR — same table because both are "text-at-a-location
/// inside an image."
public struct BarcodeDetector: Sendable {
    public init() {}

    public func detect(cgImage: CGImage) async throws -> [BarcodeHit] {
        // Synchronous perform + read results — avoids the double continuation
        // resume (completion handler + catch) that crashed on Vision errors.
        let req = VNDetectBarcodesRequest()
        req.symbologies = [
            .qr, .ean8, .ean13, .code128, .code39,
            .pdf417, .dataMatrix, .aztec,
        ]
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])

        let observations = req.results ?? []
        return observations.compactMap { obs in
            guard let payload = obs.payloadStringValue else { return nil }
            return BarcodeHit(
                symbology: obs.symbology.rawValue,
                payload: payload,
                confidence: Double(obs.confidence),
                bbox: OCRAnalyzer.normalizedTopLeftBBox(obs.boundingBox)
            )
        }
    }

    public struct BarcodeHit: Sendable {
        public let symbology: String
        public let payload: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
