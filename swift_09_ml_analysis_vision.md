# swift_09 — ML Analysis (Apple Vision + PDFKit)

## Purpose

Extract searchable signal from every captured item: text (OCR), scene/object tags (classification), barcodes, PDF page text, Office document text. Persist results into `detections` / `ocr_results` / `document_text` so `swift_08` search can find "the screenshot with the word Stripe" or "the image of a cat".

Replaces the **three helper binaries** (`live-text-extractor`, `obj-detection`, `pdf-extractor`) from the current Electron app. **MAS mandates inlining** — you can't ship standalone executables that run outside the main process in a sandboxed app.

**Model strategy**: all-Apple, all-built-in. No third-party model weights, no licensing concerns, no bundled `.mlmodel` files. Concretely:

| Task | Apple API |
|---|---|
| Image classification (scene + object tags) | `VNClassifyImageRequest` |
| Animal detection (cats / dogs with bboxes) | `VNRecognizeAnimalsRequest` |
| Human detection (with bboxes) | `VNDetectHumanRectanglesRequest` |
| Text in images (OCR) | `VNRecognizeTextRequest` |
| Barcode detection | `VNDetectBarcodesRequest` |
| PDF text / thumbnails | `PDFKit` |
| Word / RTF text | `NSAttributedString` with `.docFormat` |

Trade-off vs the YOLO12x approach in the original plan: **`VNClassifyImageRequest` does whole-image multi-label classification but does not give per-object bounding boxes for the long tail of classes.** We get bounding boxes for the three things we care about most (text, animals, humans) and confidence-ranked tag lists for everything else. In exchange we drop a ~90 MB model bundle, sidestep AGPL licensing, and get model improvements for free on every OS release.

## Current Electron behavior (recap)

- `electron/bin/live-text-extractor` — shells to Vision for OCR. Replaced by inlined `VNRecognizeTextRequest`.
- `electron/bin/obj-detection` — shells to YOLO12x Core ML. Replaced by combination of `VNClassifyImageRequest` + `VNRecognizeAnimalsRequest` + `VNDetectHumanRectanglesRequest`.
- `electron/bin/pdf-extractor` — PDF text extraction. Replaced by inlined `PDFKit`.
- `coco_synonyms.json` — COCO label synonym map. Replaced by `image_tag_synonyms.json` keyed by Apple's classification identifiers.
- IPC handlers preserved (`get-detections`, `get-ocr-results`, etc.) — see swift_26 for the mapping.

## Module layout

Dedicated Swift package `ClipzML`:

```
Packages/ClipzML/
├── Sources/ClipzML/
│   ├── AnalysisService.swift             # coordinator, queue, DB integration
│   ├── OCRAnalyzer.swift                 # VNRecognizeTextRequest
│   ├── ImageClassifier.swift             # VNClassifyImageRequest
│   ├── AnimalDetector.swift              # VNRecognizeAnimalsRequest (cats/dogs, with bbox)
│   ├── HumanDetector.swift               # VNDetectHumanRectanglesRequest (with bbox)
│   ├── BarcodeDetector.swift             # VNDetectBarcodesRequest
│   ├── PDFExtractor.swift                # PDFKit
│   ├── DocumentExtractor.swift           # .docx/.rtf via NSAttributedString
│   ├── SynonymsSeeder.swift              # seeds object_classes + synonyms from image_tag_synonyms.json
│   ├── MLPipeline.swift                  # facade: one entry point per item kind
│   └── Resources/
│       └── image_tag_synonyms.json       # e.g. { "cat": ["kitten","cats","kitty","feline"], "laptop": [...] }
```

No `YOLO12x.mlmodelc` resource. No model bundle shipping. Package is pure-API.

## Top-level service

```swift
// Packages/ClipzML/Sources/ClipzML/AnalysisService.swift

public actor AnalysisService {
    private let database: AppDatabase
    private let fileStore: FileStore
    private let pipeline: MLPipeline
    private var queue: [AnalysisJob] = []
    private var worker: Task<Void, Never>?
    private let maxConcurrency = 2

    public init(database: AppDatabase, fileStore: FileStore, pipeline: MLPipeline) {
        self.database = database
        self.fileStore = fileStore
        self.pipeline = pipeline
    }

    public func start() async {
        guard worker == nil else { return }
        await seedObjectClassesIfNeeded()
        worker = Task.detached(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
        await enqueuePendingItems()
    }

    public func stop() async {
        worker?.cancel(); worker = nil
        queue.removeAll()
    }

    public func enqueue(itemID: String, kind: ClipboardKind) {
        queue.append(AnalysisJob(itemID: itemID, kind: kind))
    }

    public func reanalyze(itemID: String) async {
        try? await database.write { db in
            _ = try DetectionRow.filter(Column("item_id") == itemID).deleteAll(db)
            _ = try OCRResultRow.filter(Column("item_id") == itemID).deleteAll(db)
            _ = try DocumentTextRow.filter(Column("item_id") == itemID).deleteAll(db)
            try db.execute(sql: """
                UPDATE clipboard_items
                SET analysis_text_done=0, analysis_object_done=0, analysis_updatedAt=NULL
                WHERE id=?
            """, arguments: [itemID])
        }
        if let row = try? await database.read({ try ClipboardItemRow.fetchOne($0, key: itemID) }),
           let kind = ClipboardKind(rawValue: row.type) {
            enqueue(itemID: itemID, kind: kind)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard !queue.isEmpty else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            let batch = Array(queue.prefix(maxConcurrency))
            queue.removeFirst(batch.count)
            await withTaskGroup(of: Void.self) { group in
                for job in batch { group.addTask { await self.process(job) } }
            }
        }
    }

    private func process(_ job: AnalysisJob) async {
        do {
            switch job.kind {
            case .image, .screenshot:
                try await processImage(itemID: job.itemID)
            case .pdf:
                try await processPDF(itemID: job.itemID)
            case .doc, .docx:
                try await processWordDoc(itemID: job.itemID)
            case .xls, .xlsx, .numbers:
                try await processSpreadsheet(itemID: job.itemID)
            case .text, .html, .video:
                try await markDone(itemID: job.itemID, textDone: true, objectDone: true)
            }
        } catch {
            Log.error("analysis failed for \(job.itemID): \(error)")
        }
    }
}
```

## OCR (Vision framework)

```swift
// Packages/ClipzML/Sources/ClipzML/OCRAnalyzer.swift
import Vision

public struct OCRAnalyzer {
    public enum Level { case fast, accurate }

    public func recognize(cgImage: CGImage, level: Level = .accurate)
        async throws -> [RecognizedText] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let results: [RecognizedText] = observations.compactMap { obs in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    return RecognizedText(
                        text: best.string,
                        confidence: Double(best.confidence),
                        bbox: BoundingBox(
                            x: obs.boundingBox.origin.x,
                            y: 1 - obs.boundingBox.origin.y - obs.boundingBox.height,
                            width: obs.boundingBox.width,
                            height: obs.boundingBox.height
                        )
                    )
                }
                cont.resume(returning: results)
            }
            req.recognitionLevel = (level == .fast) ? .fast : .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["en-US"]
            req.minimumTextHeight = 0.015

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    public struct RecognizedText: Sendable {
        public let text: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
```

**Recognition level**: `.accurate` default. M1+ runs it sub-second on typical screenshots.

**Languages**: default English; future enhancement to read `Locale.preferredLanguages`.

## Image classification (whole-image tags, no bbox)

```swift
// Packages/ClipzML/Sources/ClipzML/ImageClassifier.swift
import Vision

public struct ImageClassifier {
    /// Whole-image classification via VNClassifyImageRequest. Returns top-N tags with
    /// confidence, no bounding boxes. Tag identifiers are Apple's own taxonomy strings
    /// (e.g. "cat", "laptop", "outdoor", "building", "beverage"), stable across OS updates.
    public func classify(cgImage: CGImage,
                         minConfidence: Double = 0.30,
                         maxResults: Int = 10) async throws -> [ImageTag] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNClassifyImageRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let obs = (request.results as? [VNClassificationObservation]) ?? []
                let tags: [ImageTag] = obs
                    .filter { Double($0.confidence) >= minConfidence }
                    .prefix(maxResults)
                    .map { ImageTag(identifier: $0.identifier,
                                     confidence: Double($0.confidence)) }
                cont.resume(returning: tags)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    public struct ImageTag: Sendable {
        public let identifier: String     // e.g. "cat", "laptop"
        public let confidence: Double     // 0...1
    }
}
```

Notes:

- `VNClassifyImageRequest` returns **hundreds** of possible identifiers ranked by confidence. We clamp to top-10 above 0.30 — plenty for search coverage.
- Identifiers are lowercase underscore-free tokens (e.g. `cat`, `indoor`, `electronic_device` depending on macOS version). Verify identifier stability when testing against each OS.
- Runs Neural Engine on M-series; typical latency 20–60 ms per image.

## Animal detector (with bounding boxes)

```swift
// Packages/ClipzML/Sources/ClipzML/AnimalDetector.swift
import Vision

public struct AnimalDetector {
    public func detect(cgImage: CGImage, minConfidence: Double = 0.40)
        async throws -> [AnimalDetection] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeAnimalsRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let obs = (request.results as? [VNRecognizedObjectObservation]) ?? []
                let results: [AnimalDetection] = obs.compactMap { o in
                    guard let best = o.labels.first,
                          Double(best.confidence) >= minConfidence else { return nil }
                    return AnimalDetection(
                        identifier: best.identifier,   // "Cat" or "Dog"
                        confidence: Double(best.confidence),
                        bbox: BoundingBox(
                            x: o.boundingBox.origin.x,
                            y: 1 - o.boundingBox.origin.y - o.boundingBox.height,
                            width: o.boundingBox.width,
                            height: o.boundingBox.height
                        )
                    )
                }
                cont.resume(returning: results)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    public struct AnimalDetection: Sendable {
        public let identifier: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
```

`VNRecognizeAnimalsRequest` only identifies **cats and dogs** as of macOS 14. Narrow but precise; returns bounding boxes suitable for overlay.

## Human detector (with bounding boxes)

```swift
// Packages/ClipzML/Sources/ClipzML/HumanDetector.swift
import Vision

public struct HumanDetector {
    public func detect(cgImage: CGImage, minConfidence: Double = 0.40)
        async throws -> [HumanDetection] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectHumanRectanglesRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let obs = (request.results as? [VNHumanObservation]) ?? []
                let results: [HumanDetection] = obs
                    .filter { Double($0.confidence) >= minConfidence }
                    .map { o in
                        HumanDetection(
                            confidence: Double(o.confidence),
                            bbox: BoundingBox(
                                x: o.boundingBox.origin.x,
                                y: 1 - o.boundingBox.origin.y - o.boundingBox.height,
                                width: o.boundingBox.width,
                                height: o.boundingBox.height
                            )
                        )
                    }
                cont.resume(returning: results)
            }
            req.upperBodyOnly = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    public struct HumanDetection: Sendable {
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
```

## Barcode detector

```swift
// Packages/ClipzML/Sources/ClipzML/BarcodeDetector.swift
import Vision

public struct BarcodeDetector {
    public func detect(cgImage: CGImage) async throws -> [BarcodeHit] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectBarcodesRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let observations = (request.results as? [VNBarcodeObservation]) ?? []
                let hits: [BarcodeHit] = observations.compactMap { obs in
                    guard let payload = obs.payloadStringValue else { return nil }
                    return BarcodeHit(
                        symbology: obs.symbology.rawValue,
                        payload: payload,
                        confidence: Double(obs.confidence),
                        bbox: BoundingBox(
                            x: obs.boundingBox.origin.x,
                            y: 1 - obs.boundingBox.origin.y - obs.boundingBox.height,
                            width: obs.boundingBox.width,
                            height: obs.boundingBox.height
                        )
                    )
                }
                cont.resume(returning: hits)
            }
            req.symbologies = [.qr, .ean8, .ean13, .upcE, .code128, .code39,
                               .pdf417, .dataMatrix, .aztec]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    public struct BarcodeHit: Sendable {
        public let symbology: String
        public let payload: String
        public let confidence: Double
        public let bbox: BoundingBox
    }
}
```

## Image analysis orchestration

Runs all five image requests concurrently on the same `VNImageRequestHandler` is possible — Apple supports batched requests — but we run them as separate handlers to simplify error isolation. Latency is parallelized via `async let`.

```swift
private func processImage(itemID: String) async throws {
    guard let row = try await database.read({ db in
        try ClipboardItemRow.fetchOne(db, key: itemID)
    }), let filename = row.content, !filename.isEmpty else { return }

    let imageURL = fileStore.mediaURL(for: filename)
    guard let cgImage = CGImageLoader.load(from: imageURL) else {
        throw AnalysisError.imageDecodeFailed
    }

    async let ocr       = OCRAnalyzer().recognize(cgImage: cgImage)
    async let tags      = ImageClassifier().classify(cgImage: cgImage)
    async let animals   = AnimalDetector().detect(cgImage: cgImage)
    async let humans    = HumanDetector().detect(cgImage: cgImage)
    async let barcodes  = BarcodeDetector().detect(cgImage: cgImage)

    let (ocrResults, tagResults, animalResults, humanResults, barcodeResults)
        = try await (ocr, tags, animals, humans, barcodes)

    try await database.write { db in
        // OCR rows
        for r in ocrResults where !r.text.isEmpty {
            var row = OCRResultRow(
                id: nil, item_id: itemID, kind: "text", text: r.text,
                symbology: nil, payload: nil,
                confidence: r.confidence,
                bbox_x: r.bbox.x, bbox_y: r.bbox.y,
                bbox_w: r.bbox.width, bbox_h: r.bbox.height
            )
            try row.insert(db)
        }
        // Barcode rows
        for b in barcodeResults {
            var row = OCRResultRow(
                id: nil, item_id: itemID, kind: "barcode", text: nil,
                symbology: b.symbology, payload: b.payload,
                confidence: b.confidence,
                bbox_x: b.bbox.x, bbox_y: b.bbox.y,
                bbox_w: b.bbox.width, bbox_h: b.bbox.height
            )
            try row.insert(db)
        }
        // Tags: whole-image, no bbox
        for t in tagResults {
            let classID = try upsertClass(db: db, identifier: t.identifier)
            var det = DetectionRow(
                id: nil, item_id: itemID, class_id: classID,
                confidence: t.confidence,
                bbox_x: nil, bbox_y: nil, bbox_w: nil, bbox_h: nil
            )
            try det.insert(db)
        }
        // Animals: with bboxes
        for a in animalResults {
            let classID = try upsertClass(db: db, identifier: a.identifier.lowercased())
            var det = DetectionRow(
                id: nil, item_id: itemID, class_id: classID,
                confidence: a.confidence,
                bbox_x: a.bbox.x, bbox_y: a.bbox.y,
                bbox_w: a.bbox.width, bbox_h: a.bbox.height
            )
            try det.insert(db)
        }
        // Humans: with bboxes, synthetic class "person"
        for h in humanResults {
            let classID = try upsertClass(db: db, identifier: "person")
            var det = DetectionRow(
                id: nil, item_id: itemID, class_id: classID,
                confidence: h.confidence,
                bbox_x: h.bbox.x, bbox_y: h.bbox.y,
                bbox_w: h.bbox.width, bbox_h: h.bbox.height
            )
            try det.insert(db)
        }
        // Mark done
        try db.execute(sql: """
            UPDATE clipboard_items
            SET analysis_text_done=1, analysis_object_done=1, analysis_updatedAt=?
            WHERE id=?
        """, arguments: [Int64(Date().timeIntervalSince1970 * 1000), itemID])
    }

    await broadcaster.emit(.analysisUpdated(itemID: itemID))
}

/// Ensures a row exists in object_classes for the given identifier; returns its class_id.
/// Seeds synonyms if this is the first time we're seeing this identifier.
private func upsertClass(db: Database, identifier: String) throws -> Int {
    if let existing = try Int.fetchOne(db, sql: """
        SELECT class_id FROM object_classes WHERE class_name = ?
    """, arguments: [identifier]) {
        return existing
    }
    try db.execute(sql: """
        INSERT INTO object_classes(class_name) VALUES (?)
    """, arguments: [identifier])
    let id = Int(db.lastInsertedRowID)

    // Seed default synonym (the identifier itself)
    try db.execute(sql: """
        INSERT INTO object_synonyms(class_id, synonym) VALUES (?, ?)
    """, arguments: [id, identifier])

    // Seed additional synonyms from bundled JSON if available
    if let extras = SynonymsSeeder.synonymsForIdentifier(identifier) {
        for syn in extras {
            try db.execute(sql: """
                INSERT INTO object_synonyms(class_id, synonym) VALUES (?, ?)
            """, arguments: [id, syn])
        }
    }
    return id
}
```

### Schema adaptation

The `object_classes` table (swift_05) originally used `class_id INTEGER PRIMARY KEY` with externally-assigned COCO IDs. With Apple Vision identifiers, we **autoincrement class_id** and treat `class_name` as the unique Apple-provided identifier. Minor schema tweak in the v1 migration:

```swift
try db.create(table: "object_classes") { t in
    t.autoIncrementedPrimaryKey("class_id")
    t.column("class_name", .text).notNull().unique()
}
```

No migration needed mid-life; this is the v1 definition out of the gate.

**`detections.bbox_*` columns become nullable** — for whole-image tags from `VNClassifyImageRequest`, bbox is `NULL`. For animal/human rows, bbox is populated. The `OCRBoxOverlay` (swift_12) simply skips rows with `NULL` bbox.

## Synonyms seeding

```swift
// Packages/ClipzML/Sources/ClipzML/SynonymsSeeder.swift

public enum SynonymsSeeder {
    private static let map: [String: [String]] = loadMap()

    public static func synonymsForIdentifier(_ id: String) -> [String]? {
        map[id]
    }

    private static func loadMap() -> [String: [String]] {
        guard let url = Bundle.module.url(forResource: "image_tag_synonyms",
                                          withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return dict
    }
}
```

**`image_tag_synonyms.json`** ships in `Packages/ClipzML/Resources/`. Example entries:

```json
{
  "cat":    ["kitten", "kitty", "feline", "cats"],
  "dog":    ["puppy", "doggo", "dogs", "canine"],
  "laptop": ["notebook", "computer", "macbook"],
  "person": ["human", "people", "man", "woman"],
  "car":    ["automobile", "vehicle", "sedan"],
  "food":   ["meal", "dish", "cuisine"]
}
```

Covers the common-search-query expansions. Users searching "kitten" find their cat screenshots. Ships ~50–80 entries at launch; grows from user-reported gaps.

Identifiers not in the synonym map still search fine — the identifier itself (e.g. `outdoor`, `building`) is a default synonym, so searching "outdoor" finds images classified as such.

## PDF extraction (unchanged)

```swift
// Packages/ClipzML/Sources/ClipzML/PDFExtractor.swift
import PDFKit

public struct PDFExtractor {
    public func extract(from url: URL) async throws -> PDFExtractionResult {
        guard let doc = PDFDocument(url: url) else {
            throw AnalysisError.unsupportedFormat(extension: "pdf")
        }
        var pages: [String] = []
        var fullText = ""
        for i in 0..<doc.pageCount {
            let pageText = doc.page(at: i)?.string ?? ""
            pages.append(pageText)
            fullText += pageText + "\n\n"
        }
        return PDFExtractionResult(fullText: fullText, pages: pages,
                                    pageCount: doc.pageCount)
    }

    public func renderThumbnail(url: URL, page: Int = 0,
                                 size: CGSize = CGSize(width: 200, height: 260))
        -> Data? {
        guard let doc = PDFDocument(url: url), let pdfPage = doc.page(at: page) else { return nil }
        let thumb = pdfPage.thumbnail(of: size, for: .mediaBox)
        return thumb.pngData
    }

    public struct PDFExtractionResult: Sendable {
        public let fullText: String
        public let pages: [String]
        public let pageCount: Int
    }
}
```

## Word / RTF extraction (unchanged)

```swift
import AppKit

public struct DocumentExtractor {
    public func extractText(from url: URL) throws -> String {
        let types: [NSAttributedString.DocumentType] = [.docFormat, .officeOpenXML,
                                                         .webArchive, .rtf, .rtfd]
        for type in types {
            if let attr = try? NSAttributedString(
                url: url,
                options: [.documentType: type],
                documentAttributes: nil) {
                return attr.string
            }
        }
        throw AnalysisError.unsupportedFormat(extension: url.pathExtension)
    }
}
```

Spreadsheet formats (.xlsx, .numbers) remain deferred to v1.1 pending CoreXLSX evaluation.

## Re-analyze

UI flow: Settings → Analysis → "Re-analyze all items":

```swift
public func reanalyzeAll() async {
    try? await database.write { db in
        try db.execute(sql: """
            UPDATE clipboard_items
            SET analysis_text_done=0, analysis_object_done=0
        """)
        try db.execute(sql: "DELETE FROM detections")
        try db.execute(sql: "DELETE FROM ocr_results")
        try db.execute(sql: "DELETE FROM document_text")
    }
    await enqueuePendingItems()
}
```

Single-item reanalysis via context menu → fires `reanalyze(itemID:)`.

## Edge cases & gotchas

1. **Bbox coordinate system** — Vision returns bboxes with origin bottom-left, normalized 0..1. We flip y on ingest to origin top-left to match SwiftUI/CoreImage conventions.

2. **Huge images** — 4K+ screenshots take noticeable time. Downscale to 2K (max dimension 2048px) for analysis using `CGImageSourceCreateThumbnailAtIndex`; full-res is retained on disk for display.

3. **Low-confidence OCR** — Vision's text observation confidence is often under 0.5 for stylized text. Include results below 0.5 but expose a threshold slider in Settings (v2).

4. **`VNClassifyImageRequest` identifier drift across OS versions** — Apple occasionally adds/renames identifiers between major macOS releases. Acceptable because:
   - Our `object_classes` table stores whatever identifier we see; new identifiers get new rows, old ones stay.
   - Users can trigger `Re-analyze all items` after major macOS updates for refreshed labels.

5. **Re-analysis after Apple Vision updates** — bump an internal "analysis model fingerprint" string each macOS major release; detect mismatch at launch and prompt re-analysis opportunistically.

6. **Analysis off mode** — `analysisEnabled=false` skips queueing. Turning it back on enqueues items where `analysis_*_done == 0`.

7. **Energy impact** — built-in Vision requests are Neural-Engine-accelerated on M-series; far lighter than the YOLO path. Still, respect `ProcessInfo.thermalState`:

   ```swift
   if ProcessInfo.processInfo.thermalState == .critical { return }
   if ProcessInfo.processInfo.isLowPowerModeEnabled { maxConcurrency = 1 }
   ```

8. **Duplicate tag rows** — an image classified as `cat` (0.85) and also containing an animal detected as `Cat` (0.92) produces two `detections` rows: one with bbox NULL (from classifier), one with bbox set (from animal detector). Search treats them identically because both map to the same `class_id`. Minor storage overhead; useful signal.

9. **OCR deduplication** — Vision's line observations already split; collapse runs of identical text before insert.

10. **Password-protected PDFs** — `PDFDocument.isLocked == true`; skip with a log.

11. **DOCX with embedded images** — `NSAttributedString.string` returns text only; embedded figures ignored. Good — we're not OCR'ing doc-embedded images.

12. **Concurrent DB writes** — `DatabasePool` serializes; writes from different analysis jobs queue cleanly.

13. **Cancellation** — `Task.isCancelled` checked in `runLoop` and `process`. Individual Vision requests don't support cancellation mid-flight; we let them complete and discard results if the parent task is cancelled.

14. **"Person" as synthetic class_name** — `VNDetectHumanRectanglesRequest` has no identifier; we use the literal string `"person"`. Document this so users searching "person" get their selfies.

## Performance targets

- Full image pipeline (OCR accurate + classify + animal + human + barcode) on a 2 MP screenshot, M1: **≤ 600 ms**.
- PDF with 50 pages: **≤ 400 ms** text extraction (PDFKit scales linearly).
- Latency is dominated by `VNRecognizeTextRequest.accurate`; consider `.fast` for bulk re-analysis backfills.

## MAS notes

- Vision / Core ML / PDFKit — sandbox-compatible, no entitlement.
- No bundled ML model → no licensing review concerns → no private-API scanning surprises.
- App binary stays small: Apple's Vision frameworks are shared system dylibs, not linked into your bundle.
- App Privacy disclosure: "On-device image analysis for search" under App Functionality; no data collection.

## Open questions

- **Coverage parity with YOLO12x** — YOLO covered 80 COCO classes with bounding boxes. Apple's combo covers ~300 scene/object classifications (no bboxes) + cats/dogs/humans (with bboxes). Net effect for users: richer tags, slightly fewer bboxes. Acceptable trade-off; re-evaluate if users miss the per-object bounding overlays.
- **`VNRecognizeAnimalsRequest` extension** — rumored to gain more species in future macOS releases; no code change required — we pass the identifier through.
- **Custom Core ML model later** — if parity gaps emerge, we can add a license-permissive model (DETR-ResNet50, MIT) in a v1.x. Architecture is ready: `ImageClassifier` is a single file to swap.
- **Multi-language OCR** — add language picker in Settings → Analysis (v1.1). Pass `Locale.preferredLanguages` or user selection to `VNRecognizeTextRequest.recognitionLanguages`.
- **Spreadsheet extraction** — defer to v1.1 with `CoreXLSX` (MIT).
- **Background/idle reanalysis after OS update** — nice quality-of-life; defer.
