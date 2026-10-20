// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The canonical clipboard-item value as seen by services and UI. The
/// database storage shape lives in `ClipboardItemRow`; mapping between the
/// two is in `Database/DomainMapping.swift`.
public struct ClipboardItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ClipboardKind
    public let content: String
    public let searchPreview: String?
    public let createdAt: Date
    public let originalName: String?
    public let sourceApp: SourceApp?
    public let mediaInfo: MediaInfo?
    public let metadata: ItemMetadata?
    public let contentHash: String?
    public let analysisStatus: AnalysisStatus
    /// User-pinned (favorite). Pinned clips are exempt from retention
    /// cleanup and surface in a dedicated section at the top of the timeline.
    public let pinned: Bool
    /// The source app marked this clip private on the pasteboard (password
    /// managers, Keychain, browser password fields). Drives the blur + badge
    /// + Touch-ID gate. Set only for inline text — never files/screenshots.
    public let isSensitive: Bool

    public init(
        id: String,
        kind: ClipboardKind,
        content: String,
        searchPreview: String? = nil,
        createdAt: Date,
        originalName: String? = nil,
        sourceApp: SourceApp? = nil,
        mediaInfo: MediaInfo? = nil,
        metadata: ItemMetadata? = nil,
        contentHash: String? = nil,
        analysisStatus: AnalysisStatus = .init(textDone: false, objectDone: false, updatedAt: nil),
        pinned: Bool = false,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.searchPreview = searchPreview
        self.createdAt = createdAt
        self.originalName = originalName
        self.sourceApp = sourceApp
        self.mediaInfo = mediaInfo
        self.metadata = metadata
        self.contentHash = contentHash
        self.analysisStatus = analysisStatus
        self.pinned = pinned
        self.isSensitive = isSensitive
    }

    /// Attribution for where the clip came from.
    public struct SourceApp: Hashable, Sendable, Codable {
        /// Human-readable app name ("Safari", "Xcode").
        public let name: String
        /// Bundle identifier used to resolve a live icon via
        /// `NSWorkspace.shared.icon(forFile:)`. Nil when migrated from
        /// Electron-era rows that stored base64 icons we discarded.
        public let bundleID: String?

        public init(name: String, bundleID: String? = nil) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    /// Media-ish metadata for filesystem-backed clips.
    public struct MediaInfo: Hashable, Sendable {
        /// Optional thumbnail filename in `FileStore` (e.g. `<id>_thumb.png`
        /// for PDFs).
        public let thumbnailFilename: String?
        public let pageCount: Int?
        /// Retained for Electron parity; not surfaced in the new UI.
        public let wordCount: Int?

        public init(thumbnailFilename: String? = nil, pageCount: Int? = nil, wordCount: Int? = nil) {
            self.thumbnailFilename = thumbnailFilename
            self.pageCount = pageCount
            self.wordCount = wordCount
        }
    }

    /// Document-style metadata extracted at capture time (PDF/RTF/Word).
    /// Stored as JSON in the `metadata` column so new fields can be added
    /// without a schema migration.
    public struct ItemMetadata: Hashable, Sendable, Codable {
        public var title: String?
        public var author: String?
        public var creator: String?
        public var subject: String?
        public var keywords: [String]?
        public var mimeType: String?

        public init(
            title: String? = nil,
            author: String? = nil,
            creator: String? = nil,
            subject: String? = nil,
            keywords: [String]? = nil,
            mimeType: String? = nil
        ) {
            self.title = title
            self.author = author
            self.creator = creator
            self.subject = subject
            self.keywords = keywords
            self.mimeType = mimeType
        }
    }

    public struct AnalysisStatus: Hashable, Sendable {
        public var textDone: Bool
        public var objectDone: Bool
        public var updatedAt: Date?

        public init(textDone: Bool, objectDone: Bool, updatedAt: Date?) {
            self.textDone = textDone
            self.objectDone = objectDone
            self.updatedAt = updatedAt
        }
    }

    public var isMedia: Bool { kind.isMedia }
    public var isDocument: Bool { kind.isDocument }
}
