// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Input to `ClipboardService.capture`. Produced by `ClipboardWatcher`
/// (swift_03) — or by drop handlers / migration / programmatic callers —
/// after the raw pasteboard has been classified into a known kind.
public struct ClassifiedPayload: Sendable {
    public let kind: ClipboardKind
    public let data: PayloadData
    public let sourceAppName: String?
    public let sourceAppBundleID: String?
    /// Raw PNG bytes of the source app's icon, for the one-time capture
    /// where the bundle id isn't yet resolvable. Not persisted to DB —
    /// the app stores the bundle id and resolves icons at render time.
    public let sourceAppIconPNGData: Data?
    /// Filename at the source (e.g., "Screenshot 2026-04-22.png") when
    /// the clip came from a file; nil for inline text/html.
    public let originalName: String?
    /// First ~500 chars for FTS; nil for media kinds where OCR/analysis
    /// produces the searchable text later.
    public let searchPreview: String?
    /// The pasteboard was tagged private by the source app (a password /
    /// key). Threaded into the persisted `ClipboardItem.isSensitive`.
    public let isSensitive: Bool

    public init(
        kind: ClipboardKind,
        data: PayloadData,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppIconPNGData: Data? = nil,
        originalName: String? = nil,
        searchPreview: String? = nil,
        isSensitive: Bool = false
    ) {
        self.kind = kind
        self.data = data
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppIconPNGData = sourceAppIconPNGData
        self.originalName = originalName
        self.searchPreview = searchPreview
        self.isSensitive = isSensitive
    }

    public enum PayloadData: Sendable {
        /// Inline UTF-8 text. Stored directly in `clipboard_items.content`.
        case inlineText(String)
        /// Raw image bytes (PNG/JPEG/GIF). Written to FileStore as
        /// `<id>.<ext>` and the filename stored in `content`.
        case imageData(Data, ext: String)
        /// A file URL (document, video, screenshot saved to disk, drop).
        /// FileStore copies the bytes in unless the file is huge — in
        /// which case the caller should pre-convert to a bookmark.
        case fileURL(URL)
    }
}
