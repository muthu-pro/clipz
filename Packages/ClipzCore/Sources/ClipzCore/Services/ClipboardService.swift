// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

/// Central service for clipboard items. Every read and write of
/// `clipboard_items` goes through here; domain types come back out,
/// row types stay inside.
///
/// Serialized by actor isolation so concurrent callers (capture from the
/// watcher + a user click in the UI) can't race on the same item.
public actor ClipboardService {
    private let database: AppDatabase
    private let fileStore: FileStore
    private let broadcaster: EventBroadcaster
    private let settings: SettingsStore
    private let analysisEnqueuer: any AnalysisEnqueuer

    /// Last content hash we accepted. Filters out a common Electron-era
    /// quirk where the pasteboard's changeCount increments without the
    /// content actually changing.
    private var lastCapturedHash: String?

    /// Items currently inside a delete flow — prevents a race where
    /// retention cleanup and a UI-initiated delete both try to
    /// process the same row.
    private var pendingDeletions: Set<String> = []

    public init(
        database: AppDatabase,
        fileStore: FileStore,
        broadcaster: EventBroadcaster,
        settings: SettingsStore,
        analysisEnqueuer: any AnalysisEnqueuer = NoopAnalysisEnqueuer()
    ) {
        self.database = database
        self.fileStore = fileStore
        self.broadcaster = broadcaster
        self.settings = settings
        self.analysisEnqueuer = analysisEnqueuer
    }

    // MARK: - Capture

    /// Persist a classified payload. Deduplicates against:
    /// 1. the last in-memory capture (common change-count echo)
    /// 2. the last 5 seconds of DB rows (burst of identical events)
    ///
    /// Returns the captured item on success, `nil` if it was a duplicate
    /// or failed to persist (error is logged).
    @discardableResult
    public func capture(_ payload: ClassifiedPayload) async -> ClipboardItem? {
        // No license check here by design (swift_20 HR-5): post-trial the
        // app is hard-locked at `WindowRouter`, so capture is unreachable
        // when `.expired`. Services stay license-agnostic.
        let hash = ContentHasher.hash(payload)
        if hash == lastCapturedHash { return nil }

        let alreadyStored = await recentHashExists(hash)
        if alreadyStored { return nil }
        lastCapturedHash = hash

        // Heads-up for the UI: file-backed captures can block on a
        // multi-MB disk copy inside `persist()`. Broadcast the start
        // event so the tray can run its in-progress indicator while we
        // do the work.
        if payload.kind.isFilesystemBacked {
            await broadcaster.emit(.captureBegan(kind: payload.kind))
        }

        let id = UUID().uuidString
        let now = Date()

        let item: ClipboardItem
        do {
            item = try persist(payload: payload, id: id, hash: hash, now: now)
        } catch {
            Log.logger(.clipboard).error(
                "capture persist failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        do {
            try await database.write { [itemRow = item.toRow()] db in
                try itemRow.insert(db)
            }
        } catch {
            Log.logger(.clipboard).error(
                "capture DB insert failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        await broadcaster.emit(.captured(item))

        if await settings.get(SettingsKeys.analysisEnabled) {
            await analysisEnqueuer.enqueue(itemID: id, kind: item.kind)
        }
        return item
    }

    private func recentHashExists(_ hash: String) async -> Bool {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 5_000
        do {
            let count = try await database.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM clipboard_items
                    WHERE contentHash = ? AND createdAt > ?
                    """,
                    arguments: [hash, cutoff]
                ) ?? 0
            }
            return count > 0
        } catch {
            return false
        }
    }

    /// Writes bytes to disk (if applicable), assembles the domain item.
    /// Does not insert into DB — the caller wraps the insert so that
    /// failure here doesn't leave orphan files behind (no insert yet).
    private func persist(
        payload: ClassifiedPayload,
        id: String,
        hash: String,
        now: Date
    ) throws -> ClipboardItem {
        var content = ""
        // PDF / document thumbnail generation lives in the analysis
        // pipeline (swift_09) and runs after capture. At persist-time
        // there's nothing to fill in, but keep the hook wired through
        // to MediaInfo.
        let thumbnailFilename: String? = nil

        switch payload.data {
        case .inlineText(let s):
            content = s

        case .imageData(let data, let ext):
            let filename = "\(id).\(ext)"
            try fileStore.writeMedia(data: data, filename: filename)
            content = filename

        case .fileURL(let url):
            let ext = url.pathExtension.lowercased()
            let filename = "\(id).\(ext.isEmpty ? "bin" : ext)"
            try fileStore.importMedia(from: url, filename: filename)
            content = filename
        }

        let item = ClipboardItem(
            id: id,
            kind: payload.kind,
            content: content,
            searchPreview: payload.searchPreview,
            createdAt: now,
            originalName: payload.originalName,
            sourceApp: payload.sourceAppName.map {
                .init(name: $0, bundleID: payload.sourceAppBundleID)
            },
            mediaInfo: MediaInfoHelper.make(
                kind: payload.kind,
                thumbnailFilename: thumbnailFilename
            ),
            metadata: nil,
            contentHash: hash,
            analysisStatus: .init(textDone: false, objectDone: false, updatedAt: nil),
            isSensitive: payload.isSensitive
        )
        return item
    }

    // MARK: - Retrieval

    /// Paginated fetch for the main list. Newest-first ordering.
    public func fetchPage(
        limit: Int = 50,
        offset: Int = 0,
        kindFilter: Set<ClipboardKind>? = nil,
        dateRange: ClosedRange<Date>? = nil,
        sourceAppName: String? = nil,
        pinnedOnly: Bool = false
    ) async throws -> [ClipboardItem] {
        try await database.read { db in
            var sql = "SELECT * FROM clipboard_items WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if pinnedOnly {
                sql += " AND pinned = 1"
            }
            if let kinds = kindFilter, !kinds.isEmpty {
                let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                args.append(contentsOf: kinds.map(\.rawValue))
            }
            if let range = dateRange {
                sql += " AND createdAt BETWEEN ? AND ?"
                args.append(Int64(range.lowerBound.timeIntervalSince1970 * 1000))
                args.append(Int64(range.upperBound.timeIntervalSince1970 * 1000))
            }
            if let appName = sourceAppName, !appName.isEmpty {
                sql += " AND appName = ?"
                args.append(appName)
            }
            sql += " ORDER BY createdAt DESC LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)

            let rows = try ClipboardItemRow.fetchAll(
                db, sql: sql, arguments: StatementArguments(args)
            )
            return rows.map(ClipboardItem.init(row:))
        }
    }

    public func fetchItem(id: String) async throws -> ClipboardItem? {
        try await database.read { db in
            try ClipboardItemRow.fetchOne(db, key: id).map(ClipboardItem.init(row:))
        }
    }

    /// All pinned (favorite) clips, most-recent first.
    public func fetchPinned(limit: Int = 200) async throws -> [ClipboardItem] {
        try await database.read { db in
            try ClipboardItemRow.fetchAll(
                db,
                sql: "SELECT * FROM clipboard_items WHERE pinned = 1 ORDER BY createdAt DESC LIMIT ?",
                arguments: [limit]
            ).map(ClipboardItem.init(row:))
        }
    }

    public func countItems() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }
    }

    /// Labeled bounding boxes for an item's image, for the detection
    /// overlay. Joins `detections` → `object_classes` for the class name
    /// and drops boxless rows (the whole-image classifier tags), keeping
    /// only localizable detections. Highest-confidence first.
    public func fetchDetections(forItemID itemID: String) async throws -> [DetectedObject] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS id, c.class_name AS name, d.confidence AS confidence,
                       d.bbox_x AS x, d.bbox_y AS y, d.bbox_w AS w, d.bbox_h AS h
                FROM detections d
                JOIN object_classes c ON c.class_id = d.class_id
                WHERE d.item_id = ?
                  AND d.bbox_x IS NOT NULL AND d.bbox_y IS NOT NULL
                  AND d.bbox_w IS NOT NULL AND d.bbox_h IS NOT NULL
                ORDER BY d.confidence DESC
                """, arguments: [itemID])
            return rows.map { r in
                DetectedObject(
                    id: r["id"],
                    label: r["name"],
                    confidence: r["confidence"],
                    bbox: BoundingBox(x: r["x"], y: r["y"], width: r["w"], height: r["h"])
                )
            }
        }
    }

    /// List distinct source apps for the tray's "filter by app" control.
    /// Sorted by most-recent capture so the apps the user is actively
    /// working in float to the top.
    public func fetchUniqueSourceApps() async throws -> [SourceAppSummary] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT appName, appIcon, COUNT(*) as cnt, MAX(createdAt) as recent
                FROM clipboard_items
                WHERE appName IS NOT NULL AND appName <> ''
                GROUP BY appName
                ORDER BY recent DESC
                """
            )
            return rows.map { row in
                SourceAppSummary(
                    name: row["appName"],
                    bundleID: row["appIcon"],
                    count: row["cnt"],
                    lastSeen: Date(timeIntervalSince1970: Double(row["recent"] as Int64) / 1000)
                )
            }
        }
    }

    // MARK: - Deletion

    public func delete(id: String) async throws {
        guard !pendingDeletions.contains(id) else { return }
        pendingDeletions.insert(id)
        defer { pendingDeletions.remove(id) }

        let row: ClipboardItemRow? = try await database.read { db in
            try ClipboardItemRow.fetchOne(db, key: id)
        }
        guard let row else { return }

        // DB delete cascades into analysis tables via FK ON DELETE CASCADE.
        try await database.write { db in
            _ = try ClipboardItemRow.deleteOne(db, key: id)
        }

        cleanupFiles(for: row)
        await broadcaster.emit(.deleted(id: id))
    }

    public func deleteMany(ids: [String]) async throws {
        guard !ids.isEmpty else { return }

        let rows: [ClipboardItemRow] = try await database.read { [ids] db in
            try ClipboardItemRow.fetchAll(db, keys: ids)
        }
        try await database.write { [ids] db in
            _ = try ClipboardItemRow.deleteAll(db, keys: ids)
        }
        for row in rows {
            cleanupFiles(for: row)
        }
        await broadcaster.emit(.manyDeleted(ids: ids))
    }

    /// Nuke. Danger tab → captcha → here. Removes every clipboard row
    /// and every file in the media directory. Notes are separate; this
    /// is the clipboard-only wipe.
    public func deleteEverything() async throws {
        let count = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }
        guard count > 0 else { return }

        let ids: [String] = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM clipboard_items")
        }
        try await database.write { db in
            try db.execute(sql: "DELETE FROM clipboard_items")
        }
        // Scorched-earth media clean. A file-by-file delete is safer than
        // rm -rf of the media dir (which would take the dir too and break
        // later writes). Unknown filenames also get cleaned by this loop
        // if they shared the uuid prefix.
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: fileStore.mediaDir, includingPropertiesForKeys: nil
        ) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        await broadcaster.emit(.manyDeleted(ids: ids))
    }

    private func cleanupFiles(for row: ClipboardItemRow) {
        if let filename = row.content, !filename.isEmpty {
            if ClipboardKind(rawValue: row.type)?.isFilesystemBacked == true
                || filename.hasSuffix(".bookmark")
            {
                try? fileStore.deleteMedia(filename: filename)
            }
        }
        if let thumb = row.thumbnailPath, !thumb.isEmpty {
            try? fileStore.deleteMedia(filename: thumb)
        }
    }

    // MARK: - Retention

    public func countExpired(olderThanDays days: Int) async throws -> Int {
        let cutoff = Self.cutoffMilliseconds(forDays: days)
        return try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clipboard_items WHERE createdAt < ? AND pinned = 0",
                arguments: [cutoff]
            ) ?? 0
        }
    }

    /// Pin / unpin a clip. Pinned clips survive retention cleanup and sort
    /// to the top of the timeline.
    public func setPinned(id: String, pinned: Bool) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET pinned = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, id]
            )
        }
        if let item = try? await fetchItem(id: id) {
            await broadcaster.emit(.updated(item))
        }
    }

    /// Drop everything older than `days`. Returns the number of rows
    /// deleted. Batched through `deleteMany` so file cleanup runs for
    /// each removed item and the broadcaster emits a single
    /// `.manyDeleted`.
    @discardableResult
    public func deleteExpired(olderThanDays days: Int) async throws -> Int {
        let cutoff = Self.cutoffMilliseconds(forDays: days)
        let ids: [String] = try await database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items WHERE createdAt < ? AND pinned = 0",
                arguments: [cutoff]
            )
        }
        try await deleteMany(ids: ids)
        return ids.count
    }

    private static func cutoffMilliseconds(forDays days: Int) -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // `days == Int.max` is the "forever" sentinel — nothing is ever
        // older than that, so return a cutoff far in the past.
        guard days > 0, days < (Int.max / 86_400_000 - 1) else {
            return 0
        }
        return now - Int64(days) * 86_400_000
    }

    // MARK: - Storage usage

    public func storageUsage() async throws -> StorageUsage {
        let (itemCount, dbBytes) = try await database.read { db -> (Int, Int64) in
            let i = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
            let page = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return (i, Int64(page) * Int64(size))
        }
        return StorageUsage(
            dbBytes: dbBytes,
            mediaBytes: fileStore.mediaBytes(),
            itemCount: itemCount
        )
    }
}

/// Summary row for `fetchUniqueSourceApps` — what the clipboard view's
/// "filter by app" chip row and the tray's popover app list consume.
public struct SourceAppSummary: Hashable, Sendable {
    public let name: String
    public let bundleID: String?
    public let count: Int
    public let lastSeen: Date

    public init(name: String, bundleID: String?, count: Int, lastSeen: Date) {
        self.name = name
        self.bundleID = bundleID
        self.count = count
        self.lastSeen = lastSeen
    }
}

// MARK: - Helpers

private enum MediaInfoHelper {
    /// Build `MediaInfo` only when there's actually something worth
    /// carrying. Saves allocating an empty struct for every text clip.
    static func make(kind: ClipboardKind, thumbnailFilename: String?) -> ClipboardItem.MediaInfo? {
        guard kind.isFilesystemBacked || thumbnailFilename != nil else { return nil }
        return ClipboardItem.MediaInfo(
            thumbnailFilename: thumbnailFilename,
            pageCount: nil,
            wordCount: nil
        )
    }
}
