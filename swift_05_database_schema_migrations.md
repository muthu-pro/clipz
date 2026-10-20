# swift_05 — Database Schema & Migrations

## Purpose

Define the SQLite schema, indexes, FTS5 setup, triggers, and a proper versioned migration system. Replaces `electron/database.js` (which has no real migrations — it re-creates tables and runs defensive `ALTER TABLE` checks on every startup).

## Current Electron schema (source of truth to replicate)

From the Explore report of `electron/database.js`:

### Tables

**`clipboard_items`**
- `id TEXT PRIMARY KEY`
- `type TEXT NOT NULL`
- `content TEXT` (inline text or filename)
- `createdAt INTEGER NOT NULL`
- `originalName TEXT`
- `appName TEXT`
- `appIcon TEXT`
- `searchPreview TEXT`
- `driveId TEXT`
- `thumbnailPath TEXT`
- `pageCount INTEGER`
- `wordCount INTEGER`
- `metadata TEXT` (JSON)
- `contentHash TEXT`
- `analysis_text_done INTEGER DEFAULT 0`
- `analysis_object_done INTEGER DEFAULT 0`
- `analysis_updatedAt INTEGER`

Indexes: `idx_createdAt`, `idx_type`, `idx_contentHash`, `idx_items_type_createdAt`

**`notes`** (`id`, `title`, `content_json`, `content_text`, `createdAt`, `updatedAt`)

**`tasks`** (`id`, `text`, `completed`, `createdAt`)
- Indexes: `idx_tasks_createdAt`, `idx_tasks_completed`

**`settings`** (`key`, `value`) — K/V

**Analysis tables**
- `detections` (`id`, `item_id`, `class_id`, `confidence`, `bbox_x/y/w/h`)
- `ocr_results` (`id`, `item_id`, `kind`, `text`, `symbology`, `payload`, `confidence`, bbox)
- `object_classes` (`class_id`, `class_name`)
- `object_synonyms` (`id`, `class_id`, `synonym`)
- `document_text` (`id`, `item_id`, `full_text`, `pages` JSON)

**FTS virtual tables**
- `clipboard_fts` — trigram tokenizer
- `notes_fts` — porter tokenizer
- `object_synonyms_fts` — porter
- `object_synonyms_trigram` — trigram
- `ocr_fts` — porter
- `ocr_fts_trigram` — trigram
- `document_fts` — porter

### Triggers (cascade delete from `clipboard_items`)
- `clipboard_items_ad_det` — delete from detections on item delete
- `clipboard_items_ad_ocr` — delete from ocr_results
- `clipboard_items_ad_doctext` — delete from document_text

### Pragmas
- `journal_mode=WAL`
- `synchronous=NORMAL`
- `foreign_keys=ON`

## Swift design

### Stack choice: GRDB.swift 6

GRDB is the standard SQLite wrapper for Swift. It gives us:

- Proper `DatabaseMigrator` with up/down migrations
- `DatabaseQueue` (serialized) and `DatabasePool` (reader/writer split, WAL)
- FTS5 first-class support
- Compile-time query definitions via `@available(macOS 14)` Swift column builder
- Row decoding to Codable structs via `FetchableRecord`

We'll use `DatabasePool` (WAL) to allow concurrent readers while a writer is in progress — matches the current `better-sqlite3` WAL setup.

### Database configuration

```swift
// Packages/ClipzCore/Sources/ClipzCore/Database/AppDatabase.swift
import GRDB

public final class AppDatabase: Sendable {
    private let dbPool: DatabasePool

    public static func make(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA journal_size_limit = 10485760")  // 10 MB WAL cap
            try db.execute(sql: "PRAGMA mmap_size = 268435456")          // 256 MB
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try AppDatabase.migrator.migrate(pool)
        return AppDatabase(dbPool: pool)
    }

    private init(dbPool: DatabasePool) { self.dbPool = dbPool }

    public func read<T>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await dbPool.read(block)
    }

    public func write<T>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await dbPool.write(block)
    }
}
```

WAL mode is enabled by `DatabasePool` by default; no explicit pragma needed.

### Migrations

Real migrations — numbered, idempotent, with a registered version. GRDB's `DatabaseMigrator` tracks applied migrations in a `grdb_migrations` table.

```swift
extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true  // dev-only; never in release
        #endif

        m.registerMigration("v1-initial") { db in
            try createClipboardItems(db)
            try createNotes(db)
            try createTasks(db)
            try createSettings(db)
            try createAnalysisTables(db)
            try createFTSTables(db)
            try createTriggers(db)
            try seedDefaultSettings(db)
        }

        // Future migrations append here.
        // m.registerMigration("v2-add-tags") { db in … }

        return m
    }

    private static func createClipboardItems(_ db: Database) throws {
        try db.create(table: "clipboard_items") { t in
            t.column("id", .text).primaryKey()
            t.column("type", .text).notNull()
            t.column("content", .text)
            t.column("createdAt", .integer).notNull().indexed()
            t.column("originalName", .text)
            t.column("appName", .text)
            t.column("appIcon", .text)                     // stores bundleID now, not image blob
            t.column("searchPreview", .text)
            t.column("driveId", .text)                     // legacy; unused in Swift app
            t.column("thumbnailPath", .text)
            t.column("pageCount", .integer)
            t.column("wordCount", .integer)
            t.column("metadata", .text)                    // JSON
            t.column("contentHash", .text).indexed()
            t.column("analysis_text_done", .integer).notNull().defaults(to: 0)
            t.column("analysis_object_done", .integer).notNull().defaults(to: 0)
            t.column("analysis_updatedAt", .integer)
        }
        try db.create(index: "idx_items_type", on: "clipboard_items", columns: ["type"])
        try db.create(index: "idx_items_type_createdAt",
                      on: "clipboard_items", columns: ["type", "createdAt"])
    }

    private static func createNotes(_ db: Database) throws {
        try db.create(table: "notes") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text)
            t.column("content_json", .text)
            t.column("content_text", .text).notNull().defaults(to: "")
            t.column("createdAt", .integer).notNull()
            t.column("updatedAt", .integer).notNull().indexed()
        }
    }

    private static func createTasks(_ db: Database) throws {
        try db.create(table: "tasks") { t in
            t.column("id", .text).primaryKey()
            t.column("text", .text).notNull()
            t.column("completed", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .integer).notNull()
        }
        try db.create(index: "idx_tasks_createdAt", on: "tasks", columns: ["createdAt"])
        try db.create(index: "idx_tasks_completed", on: "tasks", columns: ["completed"])
    }

    private static func createSettings(_ db: Database) throws {
        try db.create(table: "settings") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text)
        }
    }

    private static func createAnalysisTables(_ db: Database) throws {
        try db.create(table: "object_classes") { t in
            t.column("class_id", .integer).primaryKey()
            t.column("class_name", .text).notNull()
        }
        try db.create(table: "object_synonyms") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("class_id", .integer)
                .notNull()
                .references("object_classes", onDelete: .cascade)
            t.column("synonym", .text).notNull()
        }
        try db.create(index: "idx_synonyms_class", on: "object_synonyms", columns: ["class_id"])

        try db.create(table: "detections") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("item_id", .text).notNull()
                .references("clipboard_items", onDelete: .cascade)
            t.column("class_id", .integer).notNull()
            t.column("confidence", .double).notNull()
            t.column("bbox_x", .double)
            t.column("bbox_y", .double)
            t.column("bbox_w", .double)
            t.column("bbox_h", .double)
        }
        try db.create(index: "idx_detections_item", on: "detections", columns: ["item_id"])
        try db.create(index: "idx_detections_class", on: "detections", columns: ["class_id"])

        try db.create(table: "ocr_results") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("item_id", .text).notNull()
                .references("clipboard_items", onDelete: .cascade)
            t.column("kind", .text).notNull()         // 'text' | 'barcode'
            t.column("text", .text)
            t.column("symbology", .text)              // e.g. 'QR', 'EAN13'
            t.column("payload", .text)                // for barcodes, decoded content
            t.column("confidence", .double)
            t.column("bbox_x", .double)
            t.column("bbox_y", .double)
            t.column("bbox_w", .double)
            t.column("bbox_h", .double)
        }
        try db.create(index: "idx_ocr_item", on: "ocr_results", columns: ["item_id"])

        try db.create(table: "document_text") { t in
            t.column("item_id", .text).primaryKey()
                .references("clipboard_items", onDelete: .cascade)
            t.column("full_text", .text)
            t.column("pages", .text)                  // JSON array of page strings
        }
    }

    private static func createFTSTables(_ db: Database) throws {
        // clipboard_fts: trigram for substring-friendly search
        try db.create(virtualTable: "clipboard_fts", using: FTS5()) { t in
            t.tokenizer = .trigram()
            t.column("searchPreview")
            t.column("content")
            t.synchronize(withTable: "clipboard_items")
        }

        // notes_fts: porter for stemmed word search
        try db.create(virtualTable: "notes_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("title")
            t.column("content_text")
            t.synchronize(withTable: "notes")
        }

        // OCR: porter + trigram (dual index, matching current app behavior)
        try db.create(virtualTable: "ocr_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("text")
            t.column("payload")
            t.synchronize(withTable: "ocr_results")
        }
        try db.create(virtualTable: "ocr_fts_trigram", using: FTS5()) { t in
            t.tokenizer = .trigram()
            t.column("text")
            t.column("payload")
            t.synchronize(withTable: "ocr_results")
        }

        // Synonyms: porter + trigram
        try db.create(virtualTable: "object_synonyms_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("synonym")
            t.synchronize(withTable: "object_synonyms")
        }
        try db.create(virtualTable: "object_synonyms_trigram", using: FTS5()) { t in
            t.tokenizer = .trigram()
            t.column("synonym")
            t.synchronize(withTable: "object_synonyms")
        }

        // Document text: porter
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("full_text")
            t.synchronize(withTable: "document_text")
        }
    }

    private static func createTriggers(_ db: Database) throws {
        // GRDB's `.synchronize` above creates _ai/_ad/_au triggers automatically,
        // so we don't need manual AD triggers for the FTS tables.
        //
        // Foreign-key cascades handle the analysis-table cascade deletes
        // (ON DELETE CASCADE in createAnalysisTables), which is better than the
        // Electron app's trigger-based cascade (triggers don't fire inside
        // `PRAGMA foreign_keys=OFF` batches; FK cascades are more robust).
    }

    private static func seedDefaultSettings(_ db: Database) throws {
        let defaults: [(String, String)] = [
            ("retentionDays", "90"),
            ("monitorClipboard", "1"),
            ("monitorClipboardTextOnly", "0"),
            ("muteCopySound", "0"),
            ("hideMediaThumbnail", "0"),
            ("screenshotMonitoring", "0"),
            ("screenshotFileTypes", "[\"png\",\"jpg\",\"mov\"]"),
            ("screenshotAfterImport", "keep"),
            ("analysisEnabled", "1"),
            ("theme", "light-plus"),
            ("themeMode", "auto"),
            ("showDockIcon", "1")
        ]
        for (k, v) in defaults {
            try db.execute(sql: "INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)",
                           arguments: [k, v])
        }
    }
}
```

### Type-safe settings

Instead of raw string K/V calls scattered through the code, a type-safe wrapper:

```swift
public struct SettingsKey<Value: SettingsValue>: Sendable {
    public let rawKey: String
    public let defaultValue: Value

    public static var retentionDays: SettingsKey<Int>
    { .init(rawKey: "retentionDays", defaultValue: 90) }
    public static var monitorClipboard: SettingsKey<Bool>
    { .init(rawKey: "monitorClipboard", defaultValue: true) }
    public static var monitorClipboardTextOnly: SettingsKey<Bool>
    { .init(rawKey: "monitorClipboardTextOnly", defaultValue: false) }
    public static var muteCopySound: SettingsKey<Bool>
    { .init(rawKey: "muteCopySound", defaultValue: false) }
    public static var hideMediaThumbnail: SettingsKey<Bool>
    { .init(rawKey: "hideMediaThumbnail", defaultValue: false) }
    public static var screenshotMonitoring: SettingsKey<Bool>
    { .init(rawKey: "screenshotMonitoring", defaultValue: false) }
    public static var screenshotFileTypes: SettingsKey<Set<String>>
    { .init(rawKey: "screenshotFileTypes", defaultValue: ["png", "jpg", "mov"]) }
    public static var screenshotAfterImport: SettingsKey<ScreenshotAfterImportAction>
    { .init(rawKey: "screenshotAfterImport", defaultValue: .keep) }
    public static var analysisEnabled: SettingsKey<Bool>
    { .init(rawKey: "analysisEnabled", defaultValue: true) }
    public static var theme: SettingsKey<String>
    { .init(rawKey: "theme", defaultValue: "light-plus") }
    public static var themeMode: SettingsKey<ThemeMode>
    { .init(rawKey: "themeMode", defaultValue: .auto) }
    public static var showDockIcon: SettingsKey<Bool>
    { .init(rawKey: "showDockIcon", defaultValue: true) }
}

public protocol SettingsValue {
    init?(dbString: String)
    var dbString: String { get }
}
```

Conformances for `Bool`, `Int`, `String`, `Set<String>`, and the `RawRepresentable` enums provide the conversions. A `SettingsStore` actor wraps the database:

```swift
public actor SettingsStore {
    let database: AppDatabase

    public func get<V>(_ key: SettingsKey<V>) async -> V { … }
    public func set<V>(_ key: SettingsKey<V>, _ value: V) async { … }
}
```

### Querying patterns

Use GRDB record types with a column-derived API:

```swift
// Packages/ClipzCore/Sources/ClipzCore/Models/ClipboardItemRow.swift
import GRDB

struct ClipboardItemRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboard_items"
    var id: String
    var type: String
    var content: String?
    var createdAt: Int64
    var originalName: String?
    var appName: String?
    var appIcon: String?
    var searchPreview: String?
    var driveId: String?
    var thumbnailPath: String?
    var pageCount: Int?
    var wordCount: Int?
    var metadata: String?
    var contentHash: String?
    var analysis_text_done: Int
    var analysis_object_done: Int
    var analysis_updatedAt: Int64?
}
```

Converting between the storage row type (`ClipboardItemRow`) and the domain model (`ClipboardItem`) happens in `ClipboardService`. Keeping these separate avoids GRDB attributes leaking into the domain type and simplifies testing.

### Prepared statements

GRDB auto-caches prepared statements. The frequent queries that deserve named accessors:

- `getItemsPaginated(limit:offset:type:from:to:)` — main list
- `searchItems(query:limit:offset:)` — FTS5 MATCH
- `getItem(id:)` — single fetch
- `insertItem(_:)` — capture
- `deleteItem(id:)` — cascade
- `countExpired(olderThan:)` — retention UI
- `deleteExpired(olderThan:)` — retention cleanup

All implemented in `ClipzCore.ClipboardQueries`.

### Retention cleanup

```swift
public func deleteExpired(olderThanDays days: Int) async throws -> Int {
    let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
    // Get filenames first, delete files, then delete rows atomically.
    let toDelete: [(id: String, filename: String?)] = try await database.read { db in
        try Row.fetchAll(db, sql: """
            SELECT id, content FROM clipboard_items WHERE createdAt < ?
        """, arguments: [cutoff]).map { ($0["id"], $0["content"]) }
    }
    for item in toDelete {
        if let fn = item.filename, !fn.isEmpty { try? fileStore.deleteMedia(filename: fn) }
    }
    return try await database.write { db in
        try db.execute(sql: "DELETE FROM clipboard_items WHERE createdAt < ?",
                       arguments: [cutoff])
        return db.changesCount
    }
}
```

## Edge cases & gotchas

1. **`eraseDatabaseOnSchemaChange`** — enabled in `DEBUG` only so developers can freely iterate on schema during dev. Release builds always respect migrations.

2. **Triggers vs FK cascades** — the Electron app uses triggers to cascade delete into analysis tables. We use foreign-key cascades, which are stricter and more predictable. FK cascades require `PRAGMA foreign_keys=ON` (enabled in `prepareDatabase`).

3. **FTS5 synchronization** — GRDB's `.synchronize(withTable:)` creates `_ai`, `_ad`, `_au` triggers that keep the FTS index in sync automatically. No manual trigger SQL needed.

4. **Trigram tokenizer requires SQLite 3.34+** — macOS 14 ships SQLite 3.41, so we're fine.

5. **Porter stemming quirks** — porter tokenizer is English-centric. User search for "fishing" matches "fish", "fishes". For international users this is imperfect but the current app has the same behavior.

6. **Large metadata JSON** — some items may have large metadata JSON (PDF with long author list). Column type is `TEXT` without a size limit; SQLite handles it. Parse only on demand.

7. **`driveId` column** — retained in schema for backward compatibility with Electron backups (swift_17) and migration (swift_25), even though no Swift-side code writes to it. Drop in v2 migration once migration path is dead.

8. **`wordCount` column** — deprecated per the Electron types.ts comment, still in schema for the same reason as `driveId`.

9. **App icon storage** — the Electron app stores icons as base64 blobs in `appIcon`. In Swift we store the bundle identifier as a string and resolve icons at render time via `NSWorkspace.shared.icon(forFile:)`. Storage shrinks dramatically, and icons update if the source app is replaced. The migration (swift_25) discards base64 icon data and re-resolves from bundle ID where available.

10. **Concurrent writes during capture burst** — `DatabasePool` serializes writes; readers don't block. A rapid burst of captures serializes through the writer queue but never blocks the UI's list-read queries.

11. **Vacuum policy** — call `PRAGMA incremental_vacuum` quarterly in a background task. `VACUUM` (full) only on user request from the Danger tab.

12. **Database file location** — `~/Library/Containers/tech.clipz.app/Data/Library/Application Support/clipz.db` (sandbox). Migration (swift_25) reads from the Electron app's `~/Library/Application Support/clipz/clipboard.db` via NSOpenPanel user grant.

## MAS notes

- SQLite is a bundled library; no sandbox concerns.
- WAL files (`-wal`, `-shm`) must live in the same directory as the main DB file — they do, because that's the container.
- `PRAGMA mmap_size` is allowed in sandbox.

## Open questions

- **BM25 ranking** — GRDB FTS5 supports it; the current Electron app doesn't tune ranking. Default BM25 is good enough for v1; add a ranking weight for title boost in notes later (e.g., `bm25(notes_fts, 10.0, 1.0)` to favor title matches).
- **Spellfix / fuzzy matching** — SQLite's `spellfix1` extension isn't bundled in Apple's SQLite. Skip.
- **Encryption at rest** — SQLCipher would change the whole stack. Skip for v1. Mac's FileVault provides disk-level encryption; app-level encryption is a separate ask.
- **Tags table** — not in v1; future v2 migration.
