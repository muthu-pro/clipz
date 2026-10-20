# swift_08 — Search & FTS

## Purpose

Full-text search across clipboard items, OCR-extracted text from images, detected objects (with synonym expansion), and PDF/doc text. Returns unified, ranked results with highlight markup and — for image items — per-match bounding boxes for in-image highlighting.

Replaces: `search-clipboard-items`, `search-notes`, `search-document-pages` IPC handlers and their renderer-side OCR-fuzzy-match code (`ClipboardPage.tsx:2959-3050`).

## Current Electron behavior

- `searchPreview` field (first 500 chars) is the primary text index for clipboard items.
- `clipboard_fts` uses **trigram** tokenizer for substring matching (so "usage" matches inside "superusageflow").
- `notes_fts` uses **porter** for English stemming.
- Analysis content has **dual FTS** tables — porter AND trigram — with the query layer choosing one based on query length/shape (heuristic not documented; inferred as "use trigram for ≤3-char queries, porter otherwise").
- OCR matching inside images: the renderer loads OCR results for visible items and does Levenshtein-based fuzzy matching per image to find bounding boxes.
- Result highlighting: raw `innerHTML` with `<mark>` tags (`ClipboardPage.tsx:3954`) — renderer trusts DB content after an HTML escape.

## Swift design

### Query model

```swift
public struct SearchQuery: Sendable {
    public let text: String                       // user input; may contain quoted phrases
    public let kindFilter: Set<ClipboardKind>?
    public let dateRange: ClosedRange<Date>?
    public let limit: Int
    public let offset: Int
}
```

Parse the input before running it:

- **Quoted phrases** (`"exact phrase"`) → passed as a phrase to FTS5.
- **Bare tokens** → ANDed together.
- **Short tokens (≤ 2 chars)** → trigram path.
- **Longer tokens** → porter path.

```swift
public struct ParsedSearch: Sendable {
    public let tokens: [Token]
    public let useTrigram: Bool

    public enum Token: Sendable {
        case word(String)       // unquoted
        case phrase(String)     // exact phrase
    }
}

extension ParsedSearch {
    static func parse(_ raw: String) -> ParsedSearch {
        // Naive tokenizer: scan for quoted strings, then split remainder on whitespace.
        var tokens: [Token] = []
        var buffer = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                if inQuotes, !buffer.isEmpty { tokens.append(.phrase(buffer)) }
                else if !inQuotes, !buffer.isEmpty {
                    for w in buffer.split(separator: " ") { tokens.append(.word(String(w))) }
                }
                buffer = ""
                inQuotes.toggle()
            } else {
                buffer.append(ch)
            }
        }
        if inQuotes { tokens.append(.phrase(buffer)) }
        else { for w in buffer.split(separator: " ") where !w.isEmpty {
                  tokens.append(.word(String(w))) } }

        let minLen = tokens.compactMap { t -> Int? in
            switch t {
            case .word(let w): return w.count
            case .phrase(let p): return p.split(separator: " ").map(\.count).min()
            }
        }.min() ?? 0
        return ParsedSearch(tokens: tokens, useTrigram: minLen <= 2)
    }
}
```

### Result model

```swift
public struct SearchResultPage: Sendable {
    public let results: [SearchResult]
    public let totalCount: Int?                   // nil = unknown (we don't always count)
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String                         // = item.id
    public let item: ClipboardItem
    public let matches: [Match]                   // one or more matches per item
    public let rank: Double                       // BM25 score; lower = more relevant

    public struct Match: Hashable, Sendable {
        public let source: Source
        public let snippet: String                // "…your <mark>query</mark> here…"
        public let bbox: BoundingBox?             // populated for OCR-on-image matches

        public enum Source: String, Sendable {
            case content             // searchPreview or inline text
            case ocrText             // VNRecognizeTextRequest output
            case barcodePayload
            case detectedObject      // object class or synonym
            case documentText        // PDF/DOC full text
        }
    }
}
```

### Search engine

```swift
// Packages/ClipzCore/Sources/ClipzCore/Search/SearchEngine.swift
public struct SearchEngine {
    let database: AppDatabase

    public func search(query: String,
                       limit: Int, offset: Int,
                       kindFilter: Set<ClipboardKind>?,
                       dateRange: ClosedRange<Date>?) async throws -> SearchResultPage {
        let parsed = ParsedSearch.parse(query)
        let matchExpr = parsed.toFTSMatchExpression()       // e.g., `"exact" foo bar`
        let itemsIndex = parsed.useTrigram ? "clipboard_fts" : "clipboard_fts"
            // clipboard_fts is trigram-only in our schema; porter for other indices.

        // Cross-index CTE query. SQL below is illustrative; real code uses prepared stmts.
        let sql = """
        WITH
        item_hits AS (
            SELECT ci.id,
                   bm25(\(itemsIndex)) AS rnk,
                   'content' AS source,
                   snippet(\(itemsIndex), 0, '⟪', '⟫', '…', 32) AS snippet,
                   NULL AS bbox_x, NULL AS bbox_y, NULL AS bbox_w, NULL AS bbox_h
            FROM \(itemsIndex) fts
            JOIN clipboard_items ci ON ci.rowid = fts.rowid
            WHERE \(itemsIndex) MATCH :q
        ),
        ocr_hits AS (
            SELECT o.item_id AS id,
                   bm25(\(parsed.useTrigram ? "ocr_fts_trigram" : "ocr_fts")) AS rnk,
                   'ocrText' AS source,
                   snippet(\(parsed.useTrigram ? "ocr_fts_trigram" : "ocr_fts"),
                           0, '⟪', '⟫', '…', 32) AS snippet,
                   o.bbox_x, o.bbox_y, o.bbox_w, o.bbox_h
            FROM \(parsed.useTrigram ? "ocr_fts_trigram" : "ocr_fts") fts
            JOIN ocr_results o ON o.rowid = fts.rowid
            WHERE \(parsed.useTrigram ? "ocr_fts_trigram" : "ocr_fts") MATCH :q
        ),
        synonym_hits AS (
            SELECT d.item_id AS id,
                   bm25(\(parsed.useTrigram ? "object_synonyms_trigram" : "object_synonyms_fts")) AS rnk,
                   'detectedObject' AS source,
                   s.synonym AS snippet,
                   NULL, NULL, NULL, NULL
            FROM \(parsed.useTrigram ? "object_synonyms_trigram" : "object_synonyms_fts") fts
            JOIN object_synonyms s ON s.rowid = fts.rowid
            JOIN detections d      ON d.class_id = s.class_id
            WHERE \(parsed.useTrigram ? "object_synonyms_trigram" : "object_synonyms_fts") MATCH :q
        ),
        doc_hits AS (
            SELECT dt.item_id AS id,
                   bm25(document_fts) AS rnk,
                   'documentText' AS source,
                   snippet(document_fts, 0, '⟪', '⟫', '…', 32) AS snippet,
                   NULL, NULL, NULL, NULL
            FROM document_fts fts
            JOIN document_text dt ON dt.rowid = fts.rowid
            WHERE document_fts MATCH :q
        ),
        all_hits AS (
            SELECT * FROM item_hits
            UNION ALL SELECT * FROM ocr_hits
            UNION ALL SELECT * FROM synonym_hits
            UNION ALL SELECT * FROM doc_hits
        )
        SELECT h.id,
               MIN(h.rnk) AS best_rnk,
               GROUP_CONCAT(h.source || '\u{001E}' || COALESCE(h.snippet,'') || '\u{001E}'
                            || COALESCE(h.bbox_x,'') || ',' || COALESCE(h.bbox_y,'') || ','
                            || COALESCE(h.bbox_w,'') || ',' || COALESCE(h.bbox_h,''), '\u{001F}') AS matches_blob,
               ci.*
        FROM all_hits h
        JOIN clipboard_items ci ON ci.id = h.id
        WHERE 1=1
          \(kindClause(kindFilter))
          \(dateClause(dateRange))
        GROUP BY h.id
        ORDER BY best_rnk ASC, ci.createdAt DESC
        LIMIT :limit OFFSET :offset
        """

        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: sql,
                             arguments: ["q": matchExpr, "limit": limit, "offset": offset])
        }
        return SearchResultPage(
            results: rows.map(parseResultRow),
            totalCount: nil
        )
    }
}
```

Notes on this query:

- **`bm25(table)`** — SQLite's built-in BM25 ranking (lower = better).
- **`snippet(table, col, startTag, endTag, ellipsis, maxTokens)`** — returns a snippet with `⟪` / `⟫` markers around matches. Using non-ASCII bracket characters avoids collision with user content.
- **`GROUP_CONCAT` with `\u{001E}` / `\u{001F}` separators** — ASCII group/record separator chars. Safe delimiters not present in user text.
- **`UNION ALL` over a CTE** — gives a single source list we can group by item ID, so the same item matched in OCR + content counts once at the best rank.

### Highlight markup

The snippet comes out as e.g. `"press ⟪Cmd⟫ to copy"`. Convert to `AttributedString` for SwiftUI:

```swift
public struct HighlightedString: Sendable {
    public let attributed: AttributedString
    public let plain: String
}

extension HighlightedString {
    static func parse(_ raw: String, highlight: Color = .accentColor) -> HighlightedString {
        var plain = ""
        var attr = AttributedString()
        var inHighlight = false
        var buffer = ""

        func flush() {
            if buffer.isEmpty { return }
            var chunk = AttributedString(buffer)
            if inHighlight {
                chunk.backgroundColor = highlight.opacity(0.35)
                chunk.font = .body.weight(.semibold)
            }
            attr.append(chunk)
            plain += buffer
            buffer = ""
        }
        for ch in raw {
            if ch == "⟪"      { flush(); inHighlight = true  }
            else if ch == "⟫" { flush(); inHighlight = false }
            else               { buffer.append(ch) }
        }
        flush()
        return HighlightedString(attributed: attr, plain: plain)
    }
}
```

SwiftUI views render `Text(result.snippet.attributed)`. No HTML, no `innerHTML`, no trust-the-DB concern.

### OCR match-in-image (bounding boxes)

When a query hits the `ocr_results` table, the row already carries `bbox_x/y/w/h`. We surface these as `Match.bbox` and the image renderer in swift_12 overlays a highlight rectangle at those normalized coordinates on top of the image.

This replaces the current Electron renderer-side Levenshtein fuzzy matching (`ClipboardPage.tsx:2959-3050`) — the bbox is authoritative from Vision, no re-matching needed.

### Synonym expansion

Object detection stores `class_id` + confidence per item. Synonyms map class_id → synonym strings (e.g., class 15 = "cat" has synonyms "kitten", "cats", "kitty").

When the user types "kitten", the `synonym_hits` CTE matches the synonym table, joins to `detections` by `class_id`, and surfaces the image items containing that class. The `Match.snippet` carries the matched synonym so the UI can show "matched: kitten → cat".

### Notes search

Separate engine, different tables:

```swift
public struct NotesSearchEngine {
    let database: AppDatabase

    public func search(query: String, limit: Int) async throws -> [Note] {
        let match = ParsedSearch.parse(query).toFTSMatchExpression()
        return try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.*, snippet(notes_fts, 1, '⟪', '⟫', '…', 48) AS snip
                FROM notes_fts
                JOIN notes n ON n.rowid = notes_fts.rowid
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts, 10.0, 1.0) ASC
                LIMIT ?
            """, arguments: [match, limit]).map { Note(row: $0) }
        }
    }
}
```

BM25 weights `(title=10.0, content_text=1.0)` bias results to title matches, which matches user expectation for notes.

### Document search (replaces `search-document-pages`)

Query `document_fts` with porter; attach per-page info from `document_text.pages` (JSON array). For a PDF with 200 pages, this lets the UI open the item directly on the matching page.

```swift
public func searchDocumentPages(query: String) async throws -> [DocumentPageHit] {
    let match = ParsedSearch.parse(query).toFTSMatchExpression()
    return try await database.read { db in
        try Row.fetchAll(db, sql: """
            SELECT dt.item_id, dt.pages, dt.full_text
            FROM document_fts fts
            JOIN document_text dt ON dt.rowid = fts.rowid
            WHERE document_fts MATCH ?
        """, arguments: [match]).flatMap { row in
            let pages = (try? JSONDecoder().decode([String].self, from: Data(row["pages"].utf8))) ?? []
            return pages.enumerated().compactMap { idx, pageText in
                guard pageText.range(of: query, options: .caseInsensitive) != nil else { return nil }
                return DocumentPageHit(itemID: row["item_id"], pageIndex: idx,
                                        snippet: extractSnippet(pageText, around: query))
            }
        }
    }
}
```

Case-insensitive substring after FTS is acceptable because FTS already filtered down the candidate items; we're just narrowing to the page.

## Debouncing

The UI calls `search(query:)` on every keystroke. A debouncer in the view layer delays by **180 ms** after the last keystroke before issuing the query:

```swift
// Packages/ClipzUI/Sources/ClipzUI/Clipboard/SearchDebouncer.swift
@Observable
final class SearchDebouncer {
    var query: String = "" { didSet { scheduleSearch() } }
    private var task: Task<Void, Never>?
    let onFire: (String) -> Void

    private func scheduleSearch() {
        task?.cancel()
        task = Task { [query] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            onFire(query)
        }
    }
}
```

## Edge cases & gotchas

1. **Empty query** — return empty results immediately; don't hit SQLite for `MATCH ""`.

2. **Very short queries** — porter tokenizer rejects 1–2 char queries. Our `useTrigram` heuristic routes those to the trigram index. Trigram FTS5 requires at least 3 characters too (`MATCH "ab"` returns nothing). **Clamp**: if the shortest token is < 3 chars and it's not a phrase, fall back to a `LIKE '%ab%'` query against `clipboard_items.searchPreview`.

3. **Special FTS characters** — user typing `(` or `"` in search breaks MATCH syntax. Sanitize: if parsing fails, escape by quoting each token.

4. **MATCH vs LIKE tradeoff** — LIKE is O(n) over `searchPreview`; for < 3-char queries against 50k items this is fine. For larger DBs (> 500k items) consider a prefix-index or just disable search for 1-char queries.

5. **BM25 comparability across tables** — `bm25()` values aren't directly comparable between FTS tables (different row counts, different term frequencies). We use `MIN(rnk)` to pick the best rank per item, and sort by that — not perfect but good enough in practice. A future improvement: normalize ranks per source before the UNION.

6. **Snippet bracket characters** — `⟪` and `⟫` are non-ASCII. If a user ever pastes these exact characters into clipboard content, the snippet parser mis-identifies boundaries. Probability: negligible. Mitigation: escape double occurrences or use harder-to-hit delimiters like `\u{E000}\u{E001}` (Private Use Area).

7. **OCR bbox units** — Vision framework returns bboxes as normalized `CGRect` relative to the *image*, origin bottom-left. Store as normalized (0–1) with origin top-left (flip y during ingest) so SwiftUI renders correctly without per-render conversion.

8. **Synonym expansion includes base class** — the seed data for `object_synonyms` includes the base class name itself (e.g., "cat" is in the synonym list for class "cat"). This avoids a JOIN against `object_classes` at query time.

9. **Notes title boost weights** — `bm25(notes_fts, 10.0, 1.0)` assumes column order is (title, content_text). Verify in FTS table definition; if reversed, weights are wrong.

10. **Query cancellation** — the debouncer cancels in-flight searches. Inside `SearchEngine.search`, `Task.isCancelled` isn't checked because GRDB queries are synchronous within the `await database.read {…}` block. For multi-second queries, consider wrapping in `database.asyncRead { db in try Task.checkCancellation(); … }`.

11. **Duplicate items from multiple matches** — the CTE + GROUP BY handles this. Without it, an item matching on both `content` and `ocrText` would appear twice.

## Performance

- **Indexed tables**: all FTS5 virtual tables are already indexed. Non-FTS filters (`kind`, `createdAt`) use the `idx_items_type_createdAt` index.
- **Expected throughput**: 50k-item DB, 3-char trigram query → ≤ 50 ms on M1. PDF corpus (1M tokens across 100 PDFs) → porter query ≤ 100 ms.
- **Memory**: snippet extraction is streaming; no full-column load.
- **Target p95**: < 200 ms end-to-end from keystroke to rendered results.

## MAS notes

SQLite is in-process; no IPC; no sandbox concerns for search. Analysis enablement (swift_09) has sandbox implications, but once data is in the DB, search is free.

## Open questions

- **Fuzzy matching for typos** — SQLite's `fts5vocab` + custom ranking could enable edit-distance matching. For v1, rely on porter stemming + trigram substring. Revisit based on user feedback.
- **Per-user tuned ranking** — future "boost items copied from this app" or "boost items clicked on more often" scoring. Out of v1 scope.
- **Scope all-search integration with Spotlight** — could expose a `CoreSpotlightIndex` to make clipboard items findable from Spotlight. App Store–compatible but adds privacy considerations (Spotlight indexes everything with the bundle ID). Defer; opt-in setting.
