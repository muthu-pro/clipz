// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - Time helpers

/// All timestamps in the DB are Int64 milliseconds since the Unix epoch,
/// for parity with the Electron app's `Date.now()` format. These helpers
/// are the one place that conversion happens.
private enum Timestamp {
    static func toDate(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    static func fromDate(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }
}

// MARK: - Metadata JSON helpers

private extension ClipboardItem.ItemMetadata {
    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum PagesCodec {
    static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encode(_ pages: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(pages) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - ClipboardItem

extension ClipboardItem {
    public init(row: ClipboardItemRow) {
        self.init(
            id: row.id,
            kind: ClipboardKind(rawValue: row.type) ?? .text,
            content: row.content ?? "",
            searchPreview: row.searchPreview,
            createdAt: Timestamp.toDate(row.createdAt),
            originalName: row.originalName,
            sourceApp: row.appName.map {
                SourceApp(name: $0, bundleID: row.appIcon)
            },
            mediaInfo: MediaInfo(
                thumbnailFilename: row.thumbnailPath,
                pageCount: row.pageCount,
                wordCount: row.wordCount
            ),
            metadata: ItemMetadata(json: row.metadata),
            contentHash: row.contentHash,
            analysisStatus: AnalysisStatus(
                textDone: row.analysisTextDone == 1,
                objectDone: row.analysisObjectDone == 1,
                updatedAt: row.analysisUpdatedAt.map(Timestamp.toDate)
            ),
            pinned: row.pinned == 1,
            isSensitive: row.isSensitive == 1
        )
    }

    public func toRow() -> ClipboardItemRow {
        ClipboardItemRow(
            id: id,
            type: kind.rawValue,
            content: content,
            createdAt: Timestamp.fromDate(createdAt),
            originalName: originalName,
            appName: sourceApp?.name,
            appIcon: sourceApp?.bundleID,
            searchPreview: searchPreview,
            driveId: nil,
            thumbnailPath: mediaInfo?.thumbnailFilename,
            pageCount: mediaInfo?.pageCount,
            wordCount: mediaInfo?.wordCount,
            metadata: metadata?.toJSON(),
            contentHash: contentHash,
            analysisTextDone: analysisStatus.textDone ? 1 : 0,
            analysisObjectDone: analysisStatus.objectDone ? 1 : 0,
            analysisUpdatedAt: analysisStatus.updatedAt.map(Timestamp.fromDate),
            pinned: pinned ? 1 : 0,
            isSensitive: isSensitive ? 1 : 0
        )
    }
}

// MARK: - Analysis

extension Detection {
    public init(row: DetectionRow) {
        let bbox: BoundingBox? = {
            guard let x = row.bboxX, let y = row.bboxY,
                  let w = row.bboxW, let h = row.bboxH else { return nil }
            return BoundingBox(x: x, y: y, width: w, height: h)
        }()
        // Detection rows carry an autoincrement `id` that's always populated
        // when read from DB; defaulting to 0 only matters for the odd case
        // of reading a just-constructed row before insertion.
        self.init(
            id: row.id ?? 0,
            itemID: row.itemID,
            classID: row.classID,
            confidence: row.confidence,
            bbox: bbox
        )
    }

    public func toRow() -> DetectionRow {
        DetectionRow(
            id: id == 0 ? nil : id,
            itemID: itemID,
            classID: classID,
            confidence: confidence,
            bboxX: bbox?.x,
            bboxY: bbox?.y,
            bboxW: bbox?.width,
            bboxH: bbox?.height
        )
    }
}

extension OCRResult {
    public init(row: OCRResultRow) {
        let bbox: BoundingBox? = {
            guard let x = row.bboxX, let y = row.bboxY,
                  let w = row.bboxW, let h = row.bboxH else { return nil }
            return BoundingBox(x: x, y: y, width: w, height: h)
        }()
        self.init(
            id: row.id ?? 0,
            itemID: row.itemID,
            kind: Kind(rawValue: row.kind) ?? .text,
            text: row.text,
            barcodeSymbology: row.symbology.flatMap(BarcodeSymbology.init(rawValue:)),
            barcodePayload: row.payload,
            confidence: row.confidence,
            bbox: bbox
        )
    }

    public func toRow() -> OCRResultRow {
        OCRResultRow(
            id: id == 0 ? nil : id,
            itemID: itemID,
            kind: kind.rawValue,
            text: text,
            symbology: barcodeSymbology?.rawValue,
            payload: barcodePayload,
            confidence: confidence,
            bboxX: bbox?.x,
            bboxY: bbox?.y,
            bboxW: bbox?.width,
            bboxH: bbox?.height
        )
    }
}

extension ObjectClass {
    public init(row: ObjectClassRow) {
        self.init(id: row.classID, name: row.className)
    }

    public func toRow() -> ObjectClassRow {
        ObjectClassRow(classID: id, className: name)
    }
}

extension ObjectSynonym {
    public init(row: ObjectSynonymRow) {
        self.init(id: row.id ?? 0, classID: row.classID, synonym: row.synonym)
    }

    public func toRow() -> ObjectSynonymRow {
        ObjectSynonymRow(id: id == 0 ? nil : id, classID: classID, synonym: synonym)
    }
}

extension DocumentText {
    public init(row: DocumentTextRow) {
        self.init(
            itemID: row.itemID,
            fullText: row.fullText ?? "",
            pages: PagesCodec.decode(row.pages)
        )
    }

    public func toRow() -> DocumentTextRow {
        DocumentTextRow(
            itemID: itemID,
            fullText: fullText,
            pages: PagesCodec.encode(pages)
        )
    }
}
