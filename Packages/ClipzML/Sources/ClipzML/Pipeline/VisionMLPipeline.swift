// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import ImageIO
import AVFoundation
import ClipzCore

/// Production `MLPipeline`. Runs the five image analyzers in parallel
/// against each image, and hands PDF / document work to the PDFKit and
/// NSAttributedString extractors.
public struct VisionMLPipeline: MLPipeline {
    private let ocr: OCRAnalyzer
    private let classifier: ImageClassifier
    private let animals: AnimalDetector
    private let humans: HumanDetector
    private let barcodes: BarcodeDetector
    private let objects: ObjectDetector
    private let pdf: PDFExtractor
    private let documents: DocumentExtractor

    public init(
        ocr: OCRAnalyzer = OCRAnalyzer(),
        classifier: ImageClassifier = ImageClassifier(),
        animals: AnimalDetector = AnimalDetector(),
        humans: HumanDetector = HumanDetector(),
        barcodes: BarcodeDetector = BarcodeDetector(),
        objects: ObjectDetector = ObjectDetector(),
        pdf: PDFExtractor = PDFExtractor(),
        documents: DocumentExtractor = DocumentExtractor()
    ) {
        self.ocr = ocr
        self.classifier = classifier
        self.animals = animals
        self.humans = humans
        self.barcodes = barcodes
        self.objects = objects
        self.pdf = pdf
        self.documents = documents
    }

    // MARK: - Image

    public func analyzeImage(fileURL: URL) async throws -> ImageAnalysis {
        guard let cgImage = Self.loadCGImage(from: fileURL) else {
            throw AnalysisError.imageDecodeFailed
        }
        return try await analyze(cgImage: cgImage)
    }

    /// Run every image analyzer in parallel over a single decoded frame.
    /// Shared by `analyzeImage` and the per-frame loop in `analyzeVideo`.
    func analyze(cgImage: CGImage) async throws -> ImageAnalysis {
        async let ocrOut = ocr.recognize(cgImage: cgImage)
        async let tagsOut = classifier.classify(cgImage: cgImage)
        async let animalsOut = animals.detect(cgImage: cgImage)
        async let humansOut = humans.detect(cgImage: cgImage)
        async let barcodesOut = barcodes.detect(cgImage: cgImage)
        async let objectsOut = objects.detect(cgImage: cgImage)

        let (o, t, a, h, b, obj) = try await (
            ocrOut, tagsOut, animalsOut, humansOut, barcodesOut, objectsOut
        )

        return ImageAnalysis(
            ocr: o.filter { !$0.text.isEmpty }.map {
                .init(text: $0.text, confidence: $0.confidence, bbox: $0.bbox)
            },
            barcodes: b.map {
                .init(symbology: $0.symbology, payload: $0.payload,
                      confidence: $0.confidence, bbox: $0.bbox)
            },
            tags: t.map {
                .init(identifier: $0.identifier, confidence: $0.confidence)
            },
            animals: a.map {
                .init(identifier: $0.identifier, confidence: $0.confidence, bbox: $0.bbox)
            },
            humans: h.map {
                .init(identifier: "person", confidence: $0.confidence, bbox: $0.bbox)
            },
            objects: obj.map {
                .init(identifier: $0.identifier, confidence: $0.confidence, bbox: $0.bbox)
            }
        )
    }

    // MARK: - Video

    /// Sample frames across the video (1 every 2s, capped at 30), run the
    /// image analyzers over each, and merge the results so on-screen text
    /// and detected objects become searchable. Frames are processed
    /// sequentially to bound memory; the analyzers within a frame still
    /// run in parallel.
    public func analyzeVideo(fileURL: URL) async throws -> ImageAnalysis {
        let frames = try await Self.sampleFrames(
            url: fileURL,
            everySeconds: 2.0,
            maxFrames: 30,
            maxPixel: 1920
        )
        guard !frames.isEmpty else { return ImageAnalysis() }

        var perFrame: [ImageAnalysis] = []
        perFrame.reserveCapacity(frames.count)
        for (frame, time) in frames {
            if Task.isCancelled { break }
            if let analysis = try? await analyze(cgImage: frame) {
                // Stamp OCR hits with the frame's timestamp so a search hit
                // can later seek the player there.
                perFrame.append(analysis.taggingOCR(time: time))
            }
        }
        return Self.merge(perFrame)
    }

    /// Decode up to `maxFrames` frames, one every `everySeconds`, capped in
    /// resolution to `maxPixel` on the long edge (keeps OCR/detection fast
    /// on 4K screen recordings). Uses the async `image(at:)` generator API.
    /// Each frame is paired with its timestamp (seconds).
    static func sampleFrames(
        url: URL,
        everySeconds: Double,
        maxFrames: Int,
        maxPixel: CGFloat
    ) async throws -> [(CGImage, Double)] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(duration)

        var times: [CMTime] = []
        if seconds.isFinite, seconds > 0 {
            var t = 0.0
            while t < seconds && times.count < maxFrames {
                times.append(CMTime(seconds: t, preferredTimescale: 600))
                t += everySeconds
            }
        }
        if times.isEmpty {
            times = [CMTime(seconds: 0, preferredTimescale: 600)]
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A little tolerance lets the generator snap to nearby keyframes,
        // which is much faster than exact-time decoding.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [(CGImage, Double)] = []
        for time in times {
            if Task.isCancelled { break }
            if let result = try? await generator.image(at: time) {
                // Use the *requested* time: `actualTime` can come back
                // non-finite, and a NaN second is stored by SQLite as NULL,
                // which would break seeking. Requested time is always finite
                // and is within the 0.5s tolerance of the decoded frame.
                let seconds = CMTimeGetSeconds(time)
                frames.append((result.image, seconds.isFinite ? seconds : 0))
            }
        }
        return frames
    }

    /// Collapse per-frame analyses into one deduped result: unique OCR
    /// lines, unique barcodes, highest-confidence tag per label, and one
    /// detection per class name. Bounding boxes aren't meaningful across a
    /// moving video, so we just keep a representative box per class.
    static func merge(_ analyses: [ImageAnalysis]) -> ImageAnalysis {
        var ocrSeen = Set<String>()
        var ocr: [ImageAnalysis.OCRHit] = []
        var barcodeSeen = Set<String>()
        var barcodes: [ImageAnalysis.BarcodeHit] = []
        var bestTag: [String: ImageAnalysis.TagHit] = [:]
        var animalSeen = Set<String>()
        var animals: [ImageAnalysis.DetectionHit] = []
        var humanSeen = Set<String>()
        var humans: [ImageAnalysis.DetectionHit] = []
        var objectSeen = Set<String>()
        var objects: [ImageAnalysis.DetectionHit] = []

        for a in analyses {
            for hit in a.ocr {
                let key = hit.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, ocrSeen.insert(key).inserted else { continue }
                ocr.append(hit)
            }
            for hit in a.barcodes where barcodeSeen.insert(hit.payload).inserted {
                barcodes.append(hit)
            }
            for hit in a.tags {
                if let cur = bestTag[hit.identifier], cur.confidence >= hit.confidence { continue }
                bestTag[hit.identifier] = hit
            }
            for hit in a.animals where animalSeen.insert(hit.identifier).inserted {
                animals.append(hit)
            }
            for hit in a.humans where humanSeen.insert(hit.identifier).inserted {
                humans.append(hit)
            }
            for hit in a.objects where objectSeen.insert(hit.identifier).inserted {
                objects.append(hit)
            }
        }

        return ImageAnalysis(
            // Cap OCR so a text-heavy recording can't write thousands of rows.
            ocr: Array(ocr.prefix(300)),
            barcodes: barcodes,
            tags: Array(bestTag.values),
            animals: animals,
            humans: humans,
            objects: objects
        )
    }

    // MARK: - Documents

    public func analyzePDF(fileURL: URL) async throws -> DocumentAnalysis {
        let extracted = pdf.extract(from: fileURL)
        return DocumentAnalysis(fullText: extracted.fullText, pages: extracted.pages)
    }

    public func analyzeDocument(fileURL: URL) async throws -> DocumentAnalysis {
        // NSAttributedString-based readers must run on the main thread
        // when they involve the officeOpenXML document type (WebKit
        // internals).
        let text = await MainActor.run { documents.extract(from: fileURL) }
        return DocumentAnalysis(fullText: text, pages: [])
    }

    // MARK: - Helpers

    static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
