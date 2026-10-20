// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

/// Cross-index full-text search over the clipboard corpus. Hits come
/// from five sources — inline content, OCR-extracted text, OCR barcode
/// payloads, detected-object synonyms, and PDF/doc text — and are
/// grouped per item so one clip matching in two places counts once.
///
/// Short queries (≤ 2 chars) route through the trigram indices; if
/// even trigram can't serve the query (fewer than 3 characters total),
/// we fall back to `LIKE '%q%'` against `searchPreview`.
///
/// `SearchEngine` is a value type — every call takes a fresh DB read;
/// the underlying `AppDatabase`'s pool handles concurrency.
public struct SearchEngine: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func search(
        query: String,
        limit: Int = 50,
        offset: Int = 0,
        kindFilter: Set<ClipboardKind>? = nil,
        dateRange: ClosedRange<Date>? = nil,
        sourceAppName: String? = nil
    ) async throws -> SearchResultPage {
        let parsed = ParsedSearchParser.parse(query)
        if parsed.isEmpty {
            return SearchResultPage(results: [])
        }
        if parsed.fallbackToLike {
            return try await runLikeFallback(
                needle: query,
                limit: limit,
                offset: offset,
                kindFilter: kindFilter,
                dateRange: dateRange,
                sourceAppName: sourceAppName
            )
        }

        let match = parsed.toFTSMatchExpression()
        let itemsIndex = "clipboard_fts"  // trigram-only per schema (swift_05)
        let ocrIndex = parsed.useTrigram ? "ocr_fts_trigram" : "ocr_fts"
        let synonymIndex = parsed.useTrigram ? "object_synonyms_trigram" : "object_synonyms_fts"

        let sql = """
        WITH
        item_hits AS (
            SELECT ci.id AS hit_id,
                   bm25(\(itemsIndex)) AS rnk,
                   'content' AS source,
                   snippet(\(itemsIndex), 0, '⟪', '⟫', '…', 32) AS snip,
                   NULL AS bbox_x, NULL AS bbox_y, NULL AS bbox_w, NULL AS bbox_h,
                   NULL AS frame_time
            FROM \(itemsIndex)
            JOIN clipboard_items ci ON ci.rowid = \(itemsIndex).rowid
            WHERE \(itemsIndex) MATCH :q
        ),
        ocr_hits AS (
            SELECT o.item_id AS hit_id,
                   bm25(\(ocrIndex)) AS rnk,
                   CASE WHEN o.kind = 'barcode' THEN 'barcodePayload' ELSE 'ocrText' END AS source,
                   snippet(\(ocrIndex), 0, '⟪', '⟫', '…', 32) AS snip,
                   o.bbox_x, o.bbox_y, o.bbox_w, o.bbox_h,
                   o.frame_time
            FROM \(ocrIndex)
            JOIN ocr_results o ON o.rowid = \(ocrIndex).rowid
            WHERE \(ocrIndex) MATCH :q
        ),
        synonym_hits AS (
            SELECT d.item_id AS hit_id,
                   bm25(\(synonymIndex)) AS rnk,
                   'detectedObject' AS source,
                   s.synonym AS snip,
                   NULL, NULL, NULL, NULL,
                   NULL
            FROM \(synonymIndex)
            JOIN object_synonyms s ON s.rowid = \(synonymIndex).rowid
            JOIN detections d ON d.class_id = s.class_id
            WHERE \(synonymIndex) MATCH :q
        ),
        doc_hits AS (
            SELECT dt.item_id AS hit_id,
                   bm25(document_fts) AS rnk,
                   'documentText' AS source,
                   snippet(document_fts, 0, '⟪', '⟫', '…', 32) AS snip,
                   NULL, NULL, NULL, NULL,
                   NULL
            FROM document_fts
            JOIN document_text dt ON dt.rowid = document_fts.rowid
            WHERE document_fts MATCH :q
        ),
        all_hits AS (
            SELECT * FROM item_hits
            UNION ALL SELECT * FROM ocr_hits
            UNION ALL SELECT * FROM synonym_hits
            UNION ALL SELECT * FROM doc_hits
        )
        SELECT ci.*,
               MIN(h.rnk) AS best_rnk,
               GROUP_CONCAT(
                   h.source || '\u{001F}' ||
                   COALESCE(h.snip,'') || '\u{001F}' ||
                   COALESCE(CAST(h.bbox_x AS TEXT),'') || '\u{001F}' ||
                   COALESCE(CAST(h.bbox_y AS TEXT),'') || '\u{001F}' ||
                   COALESCE(CAST(h.bbox_w AS TEXT),'') || '\u{001F}' ||
                   COALESCE(CAST(h.bbox_h AS TEXT),'') || '\u{001F}' ||
                   COALESCE(CAST(h.frame_time AS TEXT),''),
                   '\u{001E}'
               ) AS matches_blob
        FROM all_hits h
        JOIN clipboard_items ci ON ci.id = h.hit_id
        \(buildFilterClauses(kindFilter: kindFilter, dateRange: dateRange, sourceAppName: sourceAppName))
        GROUP BY ci.id
        ORDER BY best_rnk ASC, ci.createdAt DESC
        LIMIT :limit OFFSET :offset
        """

        // Row isn't Sendable in GRDB 6, so decode inside the read closure
        // and ship back the plain-Swift SearchResult values.
        let results: [SearchResult] = try await database.read { [match, limit, offset] db in
            var args: StatementArguments = ["q": match, "limit": limit, "offset": offset]
            Self.appendFilterArguments(
                &args,
                kindFilter: kindFilter,
                dateRange: dateRange,
                sourceAppName: sourceAppName
            )
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap(SearchEngine.parseResultRow)
        }

        return SearchResultPage(results: results)
    }

    // MARK: - LIKE fallback

    private func runLikeFallback(
        needle: String,
        limit: Int,
        offset: Int,
        kindFilter: Set<ClipboardKind>?,
        dateRange: ClosedRange<Date>?,
        sourceAppName: String?
    ) async throws -> SearchResultPage {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResultPage(results: [])
        }
        let pattern = "%" + Self.escapeLike(trimmed) + "%"

        let whereClauses = buildFilterClauses(
            kindFilter: kindFilter,
            dateRange: dateRange,
            sourceAppName: sourceAppName
        )
        let sql = """
        SELECT * FROM clipboard_items
        WHERE (searchPreview LIKE :p ESCAPE '\\' OR content LIKE :p ESCAPE '\\')
        \(whereClauses)
        ORDER BY createdAt DESC
        LIMIT :limit OFFSET :offset
        """

        let items: [ClipboardItem] = try await database.read { [pattern, limit, offset] db in
            var args: StatementArguments = ["p": pattern, "limit": limit, "offset": offset]
            Self.appendFilterArguments(
                &args,
                kindFilter: kindFilter,
                dateRange: dateRange,
                sourceAppName: sourceAppName
            )
            let rows = try ClipboardItemRow.fetchAll(db, sql: sql, arguments: args)
            return rows.map(ClipboardItem.init(row:))
        }
        let results: [SearchResult] = items.enumerated().map { offset, item in
            SearchResult(
                id: item.id,
                item: item,
                matches: [
                    .init(
                        source: .content,
                        snippet: item.searchPreview ?? String(item.content.prefix(120))
                    )
                ],
                rank: Double(offset)
            )
        }
        return SearchResultPage(results: results)
    }

    private static func escapeLike(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Filter helpers

    /// Returns SQL fragment including leading ` AND ` / ` WHERE ` glue as
    /// appropriate. Current callers always have at least one other clause
    /// (`ci.id = h.hit_id` etc.) so ` AND ` is always safe to prefix.
    private func buildFilterClauses(
        kindFilter: Set<ClipboardKind>?,
        dateRange: ClosedRange<Date>?,
        sourceAppName: String? = nil
    ) -> String {
        var parts: [String] = []
        if let kinds = kindFilter, !kinds.isEmpty {
            let placeholders = (0..<kinds.count)
                .map { ":kind_\($0)" }
                .joined(separator: ",")
            parts.append("ci.type IN (\(placeholders))")
        }
        if dateRange != nil {
            parts.append("ci.createdAt BETWEEN :date_lo AND :date_hi")
        }
        if let name = sourceAppName, !name.isEmpty {
            parts.append("ci.appName = :app_name")
        }
        if parts.isEmpty { return "" }
        return "AND " + parts.joined(separator: " AND ")
    }

    private static func appendFilterArguments(
        _ args: inout StatementArguments,
        kindFilter: Set<ClipboardKind>?,
        dateRange: ClosedRange<Date>?,
        sourceAppName: String? = nil
    ) {
        if let kinds = kindFilter, !kinds.isEmpty {
            for (i, kind) in kinds.enumerated() {
                args += ["kind_\(i)": kind.rawValue]
            }
        }
        if let range = dateRange {
            let lo = Int64(range.lowerBound.timeIntervalSince1970 * 1000)
            let hi = Int64(range.upperBound.timeIntervalSince1970 * 1000)
            args += ["date_lo": lo, "date_hi": hi]
        }
        if let name = sourceAppName, !name.isEmpty {
            args += ["app_name": name]
        }
    }

    // MARK: - Row → SearchResult

    private static func parseResultRow(_ row: Row) -> SearchResult? {
        // Inline copy of the ClipboardItemRow decoder — we can't use
        // GRDB's automatic mapping here because the row also carries
        // computed search columns. Reading each column by name keeps
        // us honest about which fields we're pulling.
        let itemRow = ClipboardItemRow(
            id: row["id"],
            type: row["type"],
            content: row["content"],
            createdAt: row["createdAt"],
            originalName: row["originalName"],
            appName: row["appName"],
            appIcon: row["appIcon"],
            searchPreview: row["searchPreview"],
            driveId: row["driveId"],
            thumbnailPath: row["thumbnailPath"],
            pageCount: row["pageCount"],
            wordCount: row["wordCount"],
            metadata: row["metadata"],
            contentHash: row["contentHash"],
            analysisTextDone: row["analysis_text_done"],
            analysisObjectDone: row["analysis_object_done"],
            analysisUpdatedAt: row["analysis_updatedAt"],
            pinned: row["pinned"],
            isSensitive: row["isSensitive"]
        )
        let item = ClipboardItem(row: itemRow)

        guard let blob = row["matches_blob"] as String? else { return nil }
        let rank = (row["best_rnk"] as Double?) ?? 0
        let matches = parseMatchesBlob(blob)
        return SearchResult(id: item.id, item: item, matches: matches, rank: rank)
    }

    /// Matches are packed into a single string by `GROUP_CONCAT`:
    /// - `\u{001F}` (unit separator) between match fields
    /// - `\u{001E}` (record separator) between matches
    /// Field order: source, snippet, bbox_x, bbox_y, bbox_w, bbox_h, frame_time.
    private static func parseMatchesBlob(_ blob: String) -> [SearchResult.Match] {
        blob.split(separator: "\u{001E}").compactMap { record -> SearchResult.Match? in
            let fields = record.split(separator: "\u{001F}", omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }
            guard let src = SearchResult.Match.Source(rawValue: String(fields[0])) else {
                return nil
            }
            let snippet = String(fields[1])
            let x = Double(fields[2])
            let y = Double(fields[3])
            let w = Double(fields[4])
            let h = Double(fields[5])
            let time = Double(fields[6])
            let bbox: BoundingBox? = {
                guard let x, let y, let w, let h else { return nil }
                return BoundingBox(x: x, y: y, width: w, height: h)
            }()
            return SearchResult.Match(source: src, snippet: snippet, bbox: bbox, time: time)
        }
    }
}
