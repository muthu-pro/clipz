// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB
import ClipzCore

/// Single job in the `AnalysisService` queue. `internal` so the
/// `process(_:)` test seam can accept it; not part of the public API.
struct AnalysisJob: Sendable, Equatable {
    let itemID: String
    let kind: ClipboardKind
}

/// Coordinator for the Vision / PDFKit analysis pipeline. Owns a small
/// FIFO queue, a background run-loop that pulls jobs, and the DB writes
/// that persist results into `detections`, `ocr_results`, and
/// `document_text`. Conforms to `AnalysisEnqueuer` so `ClipboardService`
/// can be wired up without knowing about Vision.
public actor AnalysisService: AnalysisEnqueuer {
    private let database: AppDatabase
    private let fileStore: FileStore
    private let pipeline: any MLPipeline
    private let pollInterval: Duration
    private let broadcaster: EventBroadcaster?
    private let thumbnailer = DocumentThumbnailer()

    private var queue: [AnalysisJob] = []
    private var worker: Task<Void, Never>?

    public init(
        database: AppDatabase,
        fileStore: FileStore,
        pipeline: any MLPipeline = VisionMLPipeline(),
        pollInterval: Duration = .milliseconds(500),
        broadcaster: EventBroadcaster? = nil
    ) {
        self.database = database
        self.fileStore = fileStore
        self.pipeline = pipeline
        self.pollInterval = pollInterval
        self.broadcaster = broadcaster
    }

    // MARK: - Lifecycle

    /// Start the background run-loop. Idempotent. Also enqueues every
    /// item that hasn't been analyzed yet (rows with
    /// `analysis_text_done = 0 OR analysis_object_done = 0`) so a cold
    /// start drains accumulated backlog.
    public func start() async {
        guard worker == nil else { return }
        await backfillObjectSynonyms()
        await requeueStaleVideos()
        await enqueuePendingItems()
        worker = Task.detached(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    /// One-time-per-launch repair: ensure every object class has its own
    /// name indexed as a searchable synonym. Detections written before the
    /// synonym-seeding fix (and any legacy Electron rows) left
    /// `object_synonyms` empty, so free-text search ("person", "laptop")
    /// found nothing even though the detections existed. Idempotent — only
    /// inserts the rows that are missing.
    private func backfillObjectSynonyms() async {
        try? await database.write { db in
            try db.execute(sql: """
                INSERT INTO object_synonyms (class_id, synonym)
                SELECT c.class_id, c.class_name
                FROM object_classes c
                WHERE NOT EXISTS (
                    SELECT 1 FROM object_synonyms s
                    WHERE s.class_id = c.class_id AND s.synonym = c.class_name
                )
                """)
        }
    }

    public func stop() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
    }

    // MARK: - AnalysisEnqueuer

    public func enqueue(itemID: String, kind: ClipboardKind) async {
        // Dedup — if the same item id is already queued, ignore. The
        // typical case is "user captured, ML has already started; user
        // then triggers reanalyze" — we want the reanalyze to wait in
        // line, not double-write.
        if !queue.contains(where: { $0.itemID == itemID }) {
            queue.append(AnalysisJob(itemID: itemID, kind: kind))
        }
    }

    /// Wipe previous analysis output for `itemID` and re-queue it.
    /// Surfaced via the Settings → Analysis "Re-analyze all items"
    /// button and the per-item "Re-analyze" action.
    public func reanalyze(itemID: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM detections WHERE item_id = ?",
                arguments: [itemID]
            )
            try db.execute(
                sql: "DELETE FROM ocr_results WHERE item_id = ?",
                arguments: [itemID]
            )
            try db.execute(
                sql: "DELETE FROM document_text WHERE item_id = ?",
                arguments: [itemID]
            )
            try db.execute(
                sql: """
                UPDATE clipboard_items
                SET analysis_text_done = 0,
                    analysis_object_done = 0,
                    analysis_updatedAt = NULL
                WHERE id = ?
                """,
                arguments: [itemID]
            )
        }
        // Look up the kind so the run-loop processor knows how to
        // analyze. If the item is gone, nothing to do.
        let row: ClipboardItemRow? = try await database.read { db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }
        if let row, let kind = ClipboardKind(rawValue: row.type) {
            await enqueue(itemID: itemID, kind: kind)
        }
    }

    public func queueDepth() -> Int { queue.count }

    // MARK: - Run loop

    private func runLoop() async {
        while !Task.isCancelled {
            guard !queue.isEmpty else {
                try? await Task.sleep(for: pollInterval)
                continue
            }
            let job = queue.removeFirst()
            await process(job)
        }
    }

    /// Single-job processor. Exposed internally so tests can drive it
    /// without starting the background loop.
    internal func process(_ job: AnalysisJob) async {
        do {
            switch job.kind {
            case .image, .screenshot:
                try await processImage(itemID: job.itemID)
            case .pdf:
                try await processPDF(itemID: job.itemID)
            case .doc, .docx:
                try await processWordDoc(itemID: job.itemID)
            case .video:
                try await processVideo(itemID: job.itemID)
            case .xls, .xlsx, .numbers:
                try await processSpreadsheet(itemID: job.itemID)
            case .text, .html:
                // Nothing to analyze; no-op but mark done so the flag
                // reflects reality.
                try await markDone(itemID: job.itemID, textDone: true, objectDone: true)
            }
        } catch {
            Log.logger(.analysis).error(
                "analysis failed for \(job.itemID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Per-kind processors

    private func processImage(itemID: String) async throws {
        guard let row: ClipboardItemRow = try await database.read({ db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }), let filename = row.content, !filename.isEmpty else { return }

        let url = fileStore.mediaURL(filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let analysis = try await pipeline.analyzeImage(fileURL: url)

        try await database.write { [itemID, analysis] db in
            try Self.writeImageAnalysis(db, itemID: itemID, analysis: analysis)
        }
        try await markDone(itemID: itemID, textDone: true, objectDone: true)

        // Nudge any open preview so the freshly-written detection boxes
        // render without waiting for the next capture / manual reload.
        if let broadcaster, let item = try? await loadItem(itemID: itemID) {
            await broadcaster.emit(.updated(item))
        }
    }

    private func processVideo(itemID: String) async throws {
        guard let row: ClipboardItemRow = try await database.read({ db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }), let filename = row.content, !filename.isEmpty else { return }

        let url = fileStore.mediaURL(filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Frame-sampled OCR + object detection, merged across frames. Reuses
        // the same DB writer as images, so text and objects feed the same
        // searchable tables (ocr_results / detections / object_synonyms).
        let analysis = try await pipeline.analyzeVideo(fileURL: url)

        try await database.write { [itemID, analysis] db in
            try Self.writeImageAnalysis(db, itemID: itemID, analysis: analysis)
        }
        try await markDone(itemID: itemID, textDone: true, objectDone: true)
    }

    private func processPDF(itemID: String) async throws {
        guard let row: ClipboardItemRow = try await database.read({ db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }), let filename = row.content, !filename.isEmpty else { return }

        let url = fileStore.mediaURL(filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let analysis = try await pipeline.analyzePDF(fileURL: url)

        try await database.write { [itemID, analysis] db in
            try Self.writeDocumentAnalysis(db, itemID: itemID, analysis: analysis)
        }
        await generateAndPersistThumbnail(itemID: itemID, sourceURL: url, kind: .pdf)
        try await markDone(itemID: itemID, textDone: true, objectDone: true)
    }

    private func processWordDoc(itemID: String) async throws {
        guard let row: ClipboardItemRow = try await database.read({ db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }), let filename = row.content, !filename.isEmpty else { return }

        let url = fileStore.mediaURL(filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let analysis = try await pipeline.analyzeDocument(fileURL: url)

        try await database.write { [itemID, analysis] db in
            try Self.writeDocumentAnalysis(db, itemID: itemID, analysis: analysis)
        }
        await generateAndPersistThumbnail(itemID: itemID, sourceURL: url, kind: .doc)
        try await markDone(itemID: itemID, textDone: true, objectDone: true)
    }

    /// Spreadsheets. Cell/text extraction is deferred (swift_26), but we can
    /// still render a QuickLook preview so .xls/.xlsx/.numbers show a real
    /// thumbnail instead of being stuck on the placeholder glyph.
    private func processSpreadsheet(itemID: String) async throws {
        if let row: ClipboardItemRow = try await database.read({ db in
            try ClipboardItemRow.fetchOne(db, key: itemID)
        }), let filename = row.content, !filename.isEmpty {
            let url = fileStore.mediaURL(filename: filename)
            if FileManager.default.fileExists(atPath: url.path) {
                await generateAndPersistThumbnail(itemID: itemID, sourceURL: url, kind: .xlsx)
            }
        }
        // Mark done regardless so we don't retry extraction on every launch.
        try await markDone(itemID: itemID, textDone: true, objectDone: true)
    }

    /// Render a first-page thumbnail into `FileStore` as `<id>_thumb.png`
    /// and point the row's `thumbnailPath` at it, so the timeline can
    /// show an actual preview for documents instead of the placeholder
    /// glyph. PDFs go through PDFKit directly (fast, exact render); every
    /// other kind routes through QuickLook. Failure is silent — the UI
    /// already has a fallback tile.
    private func generateAndPersistThumbnail(
        itemID: String,
        sourceURL: URL,
        kind: ClipboardKind
    ) async {
        let pngBytes: Data?
        switch kind {
        case .pdf:
            // PDFExtractor's renderer calls into AppKit's drawing
            // machinery, which must run on the main thread.
            let url = sourceURL
            pngBytes = await MainActor.run {
                PDFExtractor().renderThumbnail(from: url)
            }
        default:
            pngBytes = await thumbnailer.renderThumbnail(from: sourceURL)
        }

        guard let pngBytes else { return }
        let thumbFilename = "\(itemID)_thumb.png"
        do {
            try fileStore.writeMedia(data: pngBytes, filename: thumbFilename)
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE clipboard_items SET thumbnailPath = ? WHERE id = ?",
                    arguments: [thumbFilename, itemID]
                )
            }
            // Let any UI subscribers refresh so the new thumbnail
            // shows without requiring another capture / manual reload.
            if let broadcaster,
               let item = try? await loadItem(itemID: itemID) {
                await broadcaster.emit(.updated(item))
            }
        } catch {
            Log.logger(.analysis).error(
                "thumbnail write failed for \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadItem(itemID: String) async throws -> ClipboardItem? {
        try await database.read { db in
            try ClipboardItemRow.fetchOne(db, key: itemID).map(ClipboardItem.init(row:))
        }
    }

    private func markDone(itemID: String, textDone: Bool, objectDone: Bool) async throws {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE clipboard_items
                SET analysis_text_done = ?,
                    analysis_object_done = ?,
                    analysis_updatedAt = ?
                WHERE id = ?
                """,
                arguments: [textDone ? 1 : 0, objectDone ? 1 : 0, ts, itemID]
            )
        }
    }

    /// (Re)queue videos for content analysis. Two cohorts:
    ///   1. Never analyzed — videos used to be skipped entirely.
    ///   2. Analyzed before frame timestamps existed — their OCR rows have
    ///      `frame_time IS NULL`, so search hits can't seek. Re-run to fill
    ///      the timestamps.
    /// Stale analysis rows are deleted first so re-processing doesn't
    /// duplicate them. A recording that yields no text/objects has
    /// `analysis_object_done = 1` and no null-time rows, so it isn't
    /// reprocessed every launch.
    private func requeueStaleVideos() async {
        let ids: [String] = (try? await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM clipboard_items
                WHERE type = 'video' AND (
                    analysis_object_done = 0
                    OR id IN (
                        SELECT item_id FROM ocr_results
                        WHERE kind = 'text' AND frame_time IS NULL
                    )
                )
                """)
        }) ?? []

        for id in ids {
            try? await database.write { db in
                try db.execute(sql: "DELETE FROM detections WHERE item_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM ocr_results WHERE item_id = ?", arguments: [id])
                try db.execute(sql: """
                    UPDATE clipboard_items
                    SET analysis_text_done = 0, analysis_object_done = 0
                    WHERE id = ?
                    """, arguments: [id])
            }
        }
    }

    private func enqueuePendingItems() async {
        let pending: [(String, String)] = (try? await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, type FROM clipboard_items
                WHERE analysis_text_done = 0 OR analysis_object_done = 0
            """).map { (String($0["id"] as String), String($0["type"] as String)) }
        }) ?? []
        for (id, type) in pending {
            guard let kind = ClipboardKind(rawValue: type) else { continue }
            await enqueue(itemID: id, kind: kind)
        }
    }

    // MARK: - DB writers (static so they can be called from write closures)

    private static func writeImageAnalysis(
        _ db: Database, itemID: String, analysis: ImageAnalysis
    ) throws {
        for hit in analysis.ocr where !hit.text.isEmpty {
            let row = OCRResultRow(
                id: nil,
                itemID: itemID,
                kind: "text",
                text: hit.text,
                symbology: nil,
                payload: nil,
                confidence: hit.confidence,
                bboxX: hit.bbox.x, bboxY: hit.bbox.y,
                bboxW: hit.bbox.width, bboxH: hit.bbox.height,
                frameTime: hit.time
            )
            try row.insert(db)
        }
        for hit in analysis.barcodes {
            let row = OCRResultRow(
                id: nil,
                itemID: itemID,
                kind: "barcode",
                text: nil,
                symbology: hit.symbology,
                payload: hit.payload,
                confidence: hit.confidence,
                bboxX: hit.bbox.x, bboxY: hit.bbox.y,
                bboxW: hit.bbox.width, bboxH: hit.bbox.height
            )
            try row.insert(db)
        }
        for hit in analysis.tags {
            let classID = try upsertClass(db, name: hit.identifier)
            let row = DetectionRow(
                id: nil,
                itemID: itemID,
                classID: classID,
                confidence: hit.confidence,
                bboxX: nil, bboxY: nil, bboxW: nil, bboxH: nil
            )
            try row.insert(db)
        }
        for hit in analysis.animals {
            let classID = try upsertClass(db, name: hit.identifier.lowercased())
            let row = DetectionRow(
                id: nil,
                itemID: itemID,
                classID: classID,
                confidence: hit.confidence,
                bboxX: hit.bbox.x, bboxY: hit.bbox.y,
                bboxW: hit.bbox.width, bboxH: hit.bbox.height
            )
            try row.insert(db)
        }
        for hit in analysis.humans {
            let classID = try upsertClass(db, name: "person")
            let row = DetectionRow(
                id: nil,
                itemID: itemID,
                classID: classID,
                confidence: hit.confidence,
                bboxX: hit.bbox.x, bboxY: hit.bbox.y,
                bboxW: hit.bbox.width, bboxH: hit.bbox.height
            )
            try row.insert(db)
        }
        for hit in analysis.objects {
            let classID = try upsertClass(db, name: hit.identifier.lowercased())
            let row = DetectionRow(
                id: nil,
                itemID: itemID,
                classID: classID,
                confidence: hit.confidence,
                bboxX: hit.bbox.x, bboxY: hit.bbox.y,
                bboxW: hit.bbox.width, bboxH: hit.bbox.height
            )
            try row.insert(db)
        }
    }

    private static func writeDocumentAnalysis(
        _ db: Database, itemID: String, analysis: DocumentAnalysis
    ) throws {
        let pagesJSON = analysis.pages.isEmpty ? nil : String(
            data: try JSONEncoder().encode(analysis.pages), encoding: .utf8
        )
        let row = DocumentTextRow(
            itemID: itemID,
            fullText: analysis.fullText,
            pages: pagesJSON
        )
        // INSERT OR REPLACE so reanalyze overwrites cleanly.
        try row.save(db)
    }

    /// Look up (or insert) a class row by name. Returns the class_id —
    /// auto-assigned by SQLite when new — for use in `detections.class_id`.
    private static func upsertClass(_ db: Database, name: String) throws -> Int {
        let classID: Int
        if let existing = try Int.fetchOne(
            db,
            sql: "SELECT class_id FROM object_classes WHERE class_name = ?",
            arguments: [name]
        ) {
            classID = existing
        } else {
            try db.execute(
                sql: "INSERT INTO object_classes (class_name) VALUES (?)",
                arguments: [name]
            )
            classID = Int(db.lastInsertedRowID)
        }
        // Index the class name itself as a searchable synonym. The
        // SearchEngine's free-text query (`object_synonyms_fts`) joins
        // detections → object_synonyms, NOT object_classes directly — so
        // without seeding the name here a search for "laptop" would never
        // surface a laptop the detector found. Curated synonyms ("kitten"
        // → cat) can still be added alongside this baseline row.
        let hasSynonym = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM object_synonyms WHERE class_id = ? AND synonym = ?)",
            arguments: [classID, name]
        ) ?? false
        if !hasSynonym {
            try db.execute(
                sql: "INSERT INTO object_synonyms (class_id, synonym) VALUES (?, ?)",
                arguments: [classID, name]
            )
        }
        return classID
    }
}
