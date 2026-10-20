// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Paginated search response. `totalCount` is optional because accurately
/// counting across a 5-table UNION ALL is expensive; we only populate it
/// when the caller explicitly asks (they don't, today).
public struct SearchResultPage: Sendable {
    public let results: [SearchResult]
    public let totalCount: Int?

    public init(results: [SearchResult], totalCount: Int? = nil) {
        self.results = results
        self.totalCount = totalCount
    }
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String                         // = item.id
    public let item: ClipboardItem
    public let matches: [Match]
    /// BM25 score, lower = more relevant (SQLite convention).
    public let rank: Double

    public init(id: String, item: ClipboardItem, matches: [Match], rank: Double) {
        self.id = id
        self.item = item
        self.matches = matches
        self.rank = rank
    }

    public struct Match: Hashable, Sendable {
        public let source: Source
        /// Snippet text with `⟪` / `⟫` delimiters around matched terms.
        /// Callers render via `HighlightedString.parse`.
        public let snippet: String
        public let bbox: BoundingBox?
        /// For OCR text read from a video frame: seconds into the video
        /// where the match was found, so the UI can seek the player.
        /// `nil` for every non-video / non-OCR source.
        public let time: Double?

        public init(
            source: Source,
            snippet: String,
            bbox: BoundingBox? = nil,
            time: Double? = nil
        ) {
            self.source = source
            self.snippet = snippet
            self.bbox = bbox
            self.time = time
        }

        public enum Source: String, Sendable, Codable {
            case content
            case ocrText
            case barcodePayload
            case detectedObject
            case documentText
        }
    }
}
