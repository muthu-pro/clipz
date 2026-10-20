# swift_07 — Clipboard Service

## Purpose

The central service layer for clipboard items. Owns capture, retrieval, search, deletion, and retention cleanup. Every UI interaction with clipboard data goes through this actor.

Replaces: all `save-clipboard`, `get-*clipboard*`, `search-clipboard-items`, `delete-clipboard-item*`, `cleanup-old-items`, `count-expired-items`, `get-unique-apps`, `handle-item-drop` IPC handlers from the current Electron app (~20 handlers).

## Current Electron architecture

- `ipcMain.handle(...)` in `electron/main.js` for each operation.
- Worker thread at `electron/workers/dbWorker.js` handles paginated fetch, search, and delete-with-file-cleanup off the main thread.
- Notifications: `mainWindow.webContents.send('clipboard-item-added', item)` after capture; similar for deleted/updated.
- Caching in renderer: `src/services/clipboard.ts` + `QueryCache` + IndexedDB persistence. Three cache TTL tiers (current window 10 s, historical 30 min).

## Swift design

### Service contract

```swift
// Packages/ClipzCore/Sources/ClipzCore/Services/ClipboardService.swift

public actor ClipboardService {
    private let database: AppDatabase
    private let fileStore: FileStore
    private let watcher: ClipboardWatcher
    private let broadcaster: EventBroadcaster
    private var analysisService: AnalysisService?     // injected weakly to avoid cycle

    private var lastCapturedHash: String?
    private var pendingDeletions: Set<String> = []

    // MARK: - Capture (swift_03 calls these)

    public func capture(_ payload: ClassifiedPayload) async { … }
    public func writeText(_ s: String) async { … }
    public func writeFile(at url: URL) async { … }
    public func writeImage(_ data: Data) async { … }

    // MARK: - Retrieval

    public func fetchPage(limit: Int, offset: Int,
                          kindFilter: Set<ClipboardKind>?,
                          dateRange: ClosedRange<Date>?,
                          sourceAppFilter: Set<String>?) async throws -> [ClipboardItem]

    public func fetchItem(id: String) async throws -> ClipboardItem?

    public func fetchUniqueSourceApps() async throws -> [SourceAppSummary]

    // MARK: - Search

    public func search(query: String,
                       limit: Int, offset: Int,
                       kindFilter: Set<ClipboardKind>? = nil,
                       dateRange: ClosedRange<Date>? = nil) async throws -> SearchResultPage

    // MARK: - Mutation

    public func delete(id: String) async throws
    public func deleteMany(ids: [String]) async throws

    // MARK: - Retention

    public func countExpired(olderThanDays days: Int) async throws -> Int
    public func deleteExpired(olderThanDays days: Int) async throws -> Int

    // MARK: - Drop handler (replaces `handle-item-drop`)

    public func importDroppedFiles(_ urls: [URL]) async throws -> [ClipboardItem]

    // MARK: - Stop / lifecycle

    public func stop() async
}
```

### Capture implementation

```swift
public func capture(_ payload: ClassifiedPayload) async {
    let hash = ContentHasher.hash(payload)
    if hash == lastCapturedHash { return }

    // Recent-DB dedup (same content in last 5 seconds)
    if let exists = try? await database.read({ db in
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM clipboard_items
            WHERE contentHash = ? AND createdAt > ?
        """, arguments: [hash, Int64(Date().timeIntervalSince1970 * 1000) - 5000])
    }), (exists ?? 0) > 0 {
        return
    }
    lastCapturedHash = hash

    let id = UUID().uuidString
    let now = Date()
    let item: ClipboardItem
    do {
        item = try await persist(payload: payload, id: id, hash: hash, now: now)
    } catch {
        Log.error("capture failed: \(error)")
        return
    }

    await broadcaster.emit(.captured(item))

    // Enqueue analysis (non-blocking)
    if await settingsStore.analysisEnabled {
        await analysisService?.enqueue(itemID: id, kind: item.kind)
    }

    // Play sound (unless muted)
    if !(await settingsStore.muteCopySound) {
        await SoundPlayer.playCaptureChime()
    }
}

private func persist(payload: ClassifiedPayload, id: String,
                     hash: String, now: Date) async throws -> ClipboardItem {
    var content = ""
    var thumbnailFilename: String? = nil
    var pageCount: Int? = nil
    var mediaOnDisk = false

    switch payload.data {
    case .inlineText(let s):
        content = s

    case .imageData(let data, let ext):
        let filename = "\(id).\(ext)"
        try fileStore.writeMedia(data: data, filename: filename)
        content = filename
        mediaOnDisk = true

    case .fileURL(let url):
        let ext = url.pathExtension.lowercased()
        let filename = "\(id).\(ext.isEmpty ? "bin" : ext)"

        // Size gate for videos: > 100 MB → store bookmark, not bytes
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if payload.kind == .video && size > 100_000_000 {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            try fileStore.writeBookmark(bookmark, filename: "\(id).bookmark")
            content = "\(id).bookmark"
        } else {
            try fileStore.importMedia(from: url, filename: filename)
            content = filename
            mediaOnDisk = true
        }

        if payload.kind == .pdf {
            pageCount = PDFInspector.pageCount(fileURL: url)
            if let thumb = try? PDFInspector.renderThumbnail(fileURL: url) {
                let thumbName = "\(id)_thumb.png"
                try fileStore.writeMedia(data: thumb, filename: thumbName)
                thumbnailFilename = thumbName
            }
        }
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
        mediaInfo: .init(
            thumbnailFilename: thumbnailFilename,
            pageCount: pageCount,
            wordCount: nil
        ),
        metadata: nil,          // populated by analysis pipeline later
        contentHash: hash,
        analysisStatus: .init(textDone: false, objectDone: false, updatedAt: nil)
    )

    try await database.write { db in
        try item.toRow().insert(db)
    }
    return item
}
```

### Retrieval

```swift
public func fetchPage(limit: Int = 50, offset: Int = 0,
                      kindFilter: Set<ClipboardKind>? = nil,
                      dateRange: ClosedRange<Date>? = nil,
                      sourceAppFilter: Set<String>? = nil) async throws -> [ClipboardItem] {
    try await database.read { db in
        var sql = "SELECT * FROM clipboard_items WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

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
        if let apps = sourceAppFilter, !apps.isEmpty {
            let placeholders = Array(repeating: "?", count: apps.count).joined(separator: ",")
            sql += " AND appName IN (\(placeholders))"
            args.append(contentsOf: apps)
        }
        sql += " ORDER BY createdAt DESC LIMIT ? OFFSET ?"
        args.append(limit)
        args.append(offset)

        let rows = try ClipboardItemRow.fetchAll(db, sql: sql,
                                                  arguments: StatementArguments(args))
        return rows.map(ClipboardItem.init(row:))
    }
}
```

### Search (full delegation to swift_08)

```swift
public func search(query: String, limit: Int = 50, offset: Int = 0,
                   kindFilter: Set<ClipboardKind>? = nil,
                   dateRange: ClosedRange<Date>? = nil) async throws -> SearchResultPage {
    try await SearchEngine(database: database).search(
        query: query, limit: limit, offset: offset,
        kindFilter: kindFilter, dateRange: dateRange
    )
}
```

### Deletion

```swift
public func delete(id: String) async throws {
    guard !pendingDeletions.contains(id) else { return }
    pendingDeletions.insert(id)
    defer { pendingDeletions.remove(id) }

    // Fetch the row first so we know which files to clean up.
    guard let row = try await database.read({ db in
        try ClipboardItemRow.fetchOne(db, key: id)
    }) else { return }

    // Delete DB row (cascades into analysis tables via FK cascades).
    try await database.write { db in
        _ = try ClipboardItemRow.deleteOne(db, key: id)
    }

    // Delete associated files.
    await cleanupFiles(for: row)

    await broadcaster.emit(.deleted(id: id))
}

public func deleteMany(ids: [String]) async throws {
    // Batch DB delete in one transaction.
    let rows: [ClipboardItemRow] = try await database.read { db in
        try ClipboardItemRow.fetchAll(db, keys: ids)
    }
    try await database.write { db in
        _ = try ClipboardItemRow.deleteAll(db, keys: ids)
    }
    for row in rows { await cleanupFiles(for: row) }
    await broadcaster.emit(.manyDeleted(ids: ids))
}

private func cleanupFiles(for row: ClipboardItemRow) async {
    // Media file (content column is a filename for media kinds).
    if let filename = row.content, !filename.isEmpty,
       ClipboardKind(rawValue: row.type)?.isMedia == true {
        try? fileStore.deleteMedia(filename: filename)
    }
    // Thumbnail
    if let thumb = row.thumbnailPath, !thumb.isEmpty {
        try? fileStore.deleteMedia(filename: thumb)
    }
    // Bookmark for large videos
    if let content = row.content, content.hasSuffix(".bookmark") {
        try? fileStore.deleteMedia(filename: content)
    }
}
```

**Why no heuristic file scan** (unlike the current `dbWorker.js` which scans the clipboard dir for files starting with the item id): because we track filenames in `content` and `thumbnailPath`. Canonical storage → deterministic cleanup. The current app's heuristic is a workaround for the Electron code path not recording the exact filename; we fix this at the source.

### Drop handler (replaces `handle-item-drop`)

```swift
public func importDroppedFiles(_ urls: [URL]) async throws -> [ClipboardItem] {
    var imported: [ClipboardItem] = []
    for url in urls {
        guard url.startAccessingSecurityScopedResource() else { continue }
        defer { url.stopAccessingSecurityScopedResource() }

        let kind = ClipboardClassifier().documentKind(for: url) ?? .text
        let payload = ClassifiedPayload(
            kind: kind,
            data: .fileURL(url),
            sourceAppName: "Drop",
            sourceAppBundleID: nil,
            sourceAppIconPNGData: nil,
            originalName: url.lastPathComponent,
            searchPreview: nil
        )
        await capture(payload)
        // capture doesn't return — look up by hash
        if let hash = ContentHasher.hashFile(at: url),
           let item = try? await fetchMostRecent(withContentHash: hash) {
            imported.append(item)
        }
    }
    return imported
}
```

### Retention cleanup

```swift
public func countExpired(olderThanDays days: Int) async throws -> Int {
    let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
    return try await database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items WHERE createdAt < ?",
                         arguments: [cutoff]) ?? 0
    }
}

public func deleteExpired(olderThanDays days: Int) async throws -> Int {
    let ids: [String] = try await database.read { db in
        try String.fetchAll(db, sql: """
            SELECT id FROM clipboard_items WHERE createdAt < ?
        """, arguments: [Int64(Date().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000])
    }
    try await deleteMany(ids: ids)
    return ids.count
}
```

Scheduled to run daily via a `Task.detached(priority: .background)` kicked off on app launch after a 60-second delay (to avoid slowing startup).

### Event broadcaster

```swift
public actor EventBroadcaster {
    public enum Event: Sendable {
        case captured(ClipboardItem)
        case deleted(id: String)
        case manyDeleted(ids: [String])
        case updated(ClipboardItem)
        case analysisUpdated(itemID: String)
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public func events() -> AsyncStream<Event> {
        AsyncStream { cont in
            let id = UUID()
            self.continuations[id] = cont
            cont.onTermination = { _ in
                Task { await self.remove(id: id) }
            }
        }
    }

    public func emit(_ event: Event) {
        for cont in continuations.values { cont.yield(event) }
    }

    private func remove(id: UUID) { continuations[id] = nil }
}
```

SwiftUI views subscribe via `.task { for await e in broadcaster.events() { … } }`.

### No renderer-side cache

The Electron app has `QueryCache` + IndexedDB in the renderer because every query crosses an IPC boundary. In Swift there's no IPC: SQLite is in-process, prepared statements are cached by GRDB, and a `DatabasePool` serves concurrent readers. **Don't replicate `QueryCache`.** Revisit only if measurements show fetch overhead.

What we **do** keep:

- **Debounced search** — the UI already debounces keystrokes before hitting `search()` (in swift_12).
- **Listy memoization** — SwiftUI List/LazyVStack caches rendered cells.
- **Per-item analysis cache** — analysis results are stored in DB; the `AnalysisService` caches them in memory for in-flight re-renders. Swift_09.

## Concurrency & thread safety

- `ClipboardService` is an `actor` → all state is serialized.
- Database access is through `AppDatabase.read/write` which uses `DatabasePool`'s internal queues.
- File I/O (`FileStore`) is *not* an actor — it's a struct with synchronous methods that return errors. Called from within `ClipboardService` actor methods, so concurrent calls to the same filename don't happen within our code (though the OS might get a concurrent rename from another process; nothing to do about that).
- **Main-thread hop** — broadcasting events: views running on `@MainActor` receive them; no explicit hop needed in the broadcaster (consumers are `@MainActor`).

## Edge cases & gotchas

1. **Self-capture loop** — when we write to the pasteboard (`writeText`/`writeFile`/`writeImage`), we first tell `ClipboardWatcher` to ignore the next change. A race is possible if the watcher ticks between `ignoreNextChange()` and the pasteboard write. The watcher's 1-second ignore window is wide enough that this is fine in practice.

2. **Bulk delete transactionality** — deleting many rows in a single transaction is fast. File cleanup for those rows happens after the transaction. If the app crashes between DB delete and file cleanup, orphan files remain; the periodic file-store sweep cleans them up (swift_16).

3. **Capture during retention sweep** — the sweep deletes expired items in one write transaction while another write (a fresh capture) is serialized behind it. User may briefly see "no new items" during a 100k-item cleanup; acceptable.

4. **Source app filter** — `get-unique-apps` IPC returns a list of distinct `appName` values. Swift:

   ```swift
   public func fetchUniqueSourceApps() async throws -> [SourceAppSummary] {
       try await database.read { db in
           try Row.fetchAll(db, sql: """
               SELECT appName, appIcon, COUNT(*) as cnt, MAX(createdAt) as recent
               FROM clipboard_items
               WHERE appName IS NOT NULL
               GROUP BY appName
               ORDER BY recent DESC
           """).map {
               SourceAppSummary(name: $0["appName"], bundleID: $0["appIcon"],
                                count: $0["cnt"], lastSeen: Date(…))
           }
       }
   }
   ```

5. **Same hash across kinds** — extremely unlikely (hash includes `kind.rawValue`), but two different media types with identical bytes shouldn't dedup. Current implementation includes `kind` in the hash input (swift_03). Good.

6. **Audio on capture** — current app plays a chime when an item is captured (via `useAudio`). Swift version: `NSSound(named: "Glass")?.play()` gated by `muteCopySound` setting. System sounds only — no bundled audio assets, keeps the app slim.

7. **`setIgnoreNextClipboardChange` IPC preserved** — externalize the ignore-next protocol so the tray popup (swift_11) can call it when the user clicks a card to paste.

8. **Delete-while-analysis** — if analysis is mid-run when the user deletes an item, the analysis pipeline should cancel. Enforced by checking `Task.isCancelled` in the analysis loop (swift_09) and by dropping results that reference a now-missing item_id (FK cascade handles this for us anyway — a failed insert into `detections` for a deleted item_id is fine to swallow).

## MAS notes

- All operations stay in-container; no entitlements needed beyond base sandbox.
- `NSSound(named:)` is sandbox-compatible.

## Open questions

- **Queued delete** (`delete-clipboard-item-queued` in the Electron app) — the current app queues deletes to avoid UI jank. In Swift with async actors + WAL, a direct `delete(id:)` is fast enough. If measurement shows UI jank on bulk deletes, wrap in `Task.detached(priority: .userInitiated)` and return immediately; the broadcaster tells the UI when it's done.
- **Transactional cross-entity operations** (e.g., "move item to favorites" — not in v1 but on the roadmap) would go here as dedicated methods.
- **Large video inline-vs-bookmark threshold** — 100 MB is a guess. Profile with typical workflows before shipping.
