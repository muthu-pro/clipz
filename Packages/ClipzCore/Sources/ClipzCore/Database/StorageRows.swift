// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

// MARK: - Clipboard

/// GRDB storage row for `clipboard_items`. Property names with underscores
/// map directly to the legacy column names (`analysis_text_done`, etc.)
/// via `CodingKeys`; everything else matches by default.
///
/// Note: `appIcon` is a column name, not a blob — the Swift app stores a
/// bundle identifier (e.g., `com.apple.Safari`) here. The Electron-era
/// rows stored base64 icon data; the migrator (swift_25) discards that.
public struct ClipboardItemRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "clipboard_items"

    public var id: String
    public var type: String
    public var content: String?
    public var createdAt: Int64
    public var originalName: String?
    public var appName: String?
    public var appIcon: String?
    public var searchPreview: String?
    public var driveId: String?
    public var thumbnailPath: String?
    public var pageCount: Int?
    public var wordCount: Int?
    public var metadata: String?
    public var contentHash: String?
    public var analysisTextDone: Int
    public var analysisObjectDone: Int
    public var analysisUpdatedAt: Int64?
    public var pinned: Int
    public var isSensitive: Int

    public enum CodingKeys: String, CodingKey {
        case id, type, content, createdAt, originalName, appName, appIcon
        case searchPreview, driveId, thumbnailPath, pageCount, wordCount
        case metadata, contentHash, pinned, isSensitive
        case analysisTextDone = "analysis_text_done"
        case analysisObjectDone = "analysis_object_done"
        case analysisUpdatedAt = "analysis_updatedAt"
    }

    public init(
        id: String,
        type: String,
        content: String? = nil,
        createdAt: Int64,
        originalName: String? = nil,
        appName: String? = nil,
        appIcon: String? = nil,
        searchPreview: String? = nil,
        driveId: String? = nil,
        thumbnailPath: String? = nil,
        pageCount: Int? = nil,
        wordCount: Int? = nil,
        metadata: String? = nil,
        contentHash: String? = nil,
        analysisTextDone: Int = 0,
        analysisObjectDone: Int = 0,
        analysisUpdatedAt: Int64? = nil,
        pinned: Int = 0,
        isSensitive: Int = 0
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.createdAt = createdAt
        self.originalName = originalName
        self.appName = appName
        self.appIcon = appIcon
        self.searchPreview = searchPreview
        self.driveId = driveId
        self.thumbnailPath = thumbnailPath
        self.pageCount = pageCount
        self.wordCount = wordCount
        self.metadata = metadata
        self.contentHash = contentHash
        self.analysisTextDone = analysisTextDone
        self.analysisObjectDone = analysisObjectDone
        self.analysisUpdatedAt = analysisUpdatedAt
        self.pinned = pinned
        self.isSensitive = isSensitive
    }
}

// MARK: - Settings

public struct SettingsRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "settings"

    public var key: String
    public var value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

// MARK: - Analysis

public struct ObjectClassRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "object_classes"

    public var classID: Int
    public var className: String

    public enum CodingKeys: String, CodingKey {
        case classID = "class_id"
        case className = "class_name"
    }

    public init(classID: Int, className: String) {
        self.classID = classID
        self.className = className
    }
}

public struct ObjectSynonymRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "object_synonyms"

    public var id: Int64?
    public var classID: Int
    public var synonym: String

    public enum CodingKeys: String, CodingKey {
        case id
        case classID = "class_id"
        case synonym
    }

    public init(id: Int64? = nil, classID: Int, synonym: String) {
        self.id = id
        self.classID = classID
        self.synonym = synonym
    }
}

public struct DetectionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "detections"

    public var id: Int64?
    public var itemID: String
    public var classID: Int
    public var confidence: Double
    public var bboxX: Double?
    public var bboxY: Double?
    public var bboxW: Double?
    public var bboxH: Double?

    public enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case classID = "class_id"
        case confidence
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxW = "bbox_w"
        case bboxH = "bbox_h"
    }

    public init(
        id: Int64? = nil,
        itemID: String,
        classID: Int,
        confidence: Double,
        bboxX: Double? = nil,
        bboxY: Double? = nil,
        bboxW: Double? = nil,
        bboxH: Double? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.classID = classID
        self.confidence = confidence
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxW = bboxW
        self.bboxH = bboxH
    }
}

public struct OCRResultRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "ocr_results"

    public var id: Int64?
    public var itemID: String
    public var kind: String
    public var text: String?
    public var symbology: String?
    public var payload: String?
    public var confidence: Double?
    public var bboxX: Double?
    public var bboxY: Double?
    public var bboxW: Double?
    public var bboxH: Double?
    /// Seconds into the source video this OCR text was read from (video
    /// frames only; NULL for image/PDF OCR). Lets a search hit seek.
    public var frameTime: Double?

    public enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case kind, text, symbology, payload, confidence
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxW = "bbox_w"
        case bboxH = "bbox_h"
        case frameTime = "frame_time"
    }

    public init(
        id: Int64? = nil,
        itemID: String,
        kind: String,
        text: String? = nil,
        symbology: String? = nil,
        payload: String? = nil,
        confidence: Double? = nil,
        bboxX: Double? = nil,
        bboxY: Double? = nil,
        bboxW: Double? = nil,
        bboxH: Double? = nil,
        frameTime: Double? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.text = text
        self.symbology = symbology
        self.payload = payload
        self.confidence = confidence
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxW = bboxW
        self.bboxH = bboxH
        self.frameTime = frameTime
    }
}

public struct DocumentTextRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "document_text"

    public var itemID: String
    public var fullText: String?
    public var pages: String?

    public enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case fullText = "full_text"
        case pages
    }

    public init(itemID: String, fullText: String?, pages: String?) {
        self.itemID = itemID
        self.fullText = fullText
        self.pages = pages
    }
}
