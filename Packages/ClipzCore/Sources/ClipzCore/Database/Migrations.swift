// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

extension AppDatabase {
    /// Ordered migration set. GRDB records the applied migrations in its
    /// own `grdb_migrations` table; append new migrations at the end —
    /// never renumber or edit existing ones.
    ///
    /// Theme-related settings (`theme`, `themeMode`) are intentionally
    /// omitted from the seed because Clipz follows the system appearance
    /// and exposes no in-app picker (swift_15).
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        #if DEBUG
        // Dev-only: lets engineers iterate on schema without manually
        // deleting the DB file. Never enabled in release.
        m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1-initial") { db in
            try createClipboardItems(db)
            try createSettings(db)
            try createAnalysisTables(db)
            try createFTSTables(db)
            try seedDefaultSettings(db)
        }

        // Frame timestamp (seconds) for OCR text pulled from video frames,
        // so a search hit can seek the player to where the text appeared.
        // NULL for image/PDF OCR. Appended — never edit v1 — so existing
        // databases migrate forward without an erase.
        m.registerMigration("v2-ocr-frame-time") { db in
            try db.alter(table: "ocr_results") { t in
                t.add(column: "frame_time", .double)
            }
        }

        // Pinned / favorite flag. Pinned clips sort to a section at the top
        // and are exempt from retention cleanup. Appended migration.
        m.registerMigration("v3-pinned") { db in
            try db.alter(table: "clipboard_items") { t in
                t.add(column: "pinned", .integer).notNull().defaults(to: 0)
            }
        }

        // Sensitive flag. Set when the source app marked the pasteboard
        // private (password managers, Keychain, browser password fields);
        // drives the blur + Touch-ID gate. Appended migration.
        m.registerMigration("v4-sensitive") { db in
            try db.alter(table: "clipboard_items") { t in
                t.add(column: "isSensitive", .integer).notNull().defaults(to: 0)
            }
        }

        return m
    }

    // MARK: - v1 table creation

    private static func createClipboardItems(_ db: Database) throws {
        try db.create(table: "clipboard_items") { t in
            t.column("id", .text).primaryKey()
            t.column("type", .text).notNull()
            t.column("content", .text)
            t.column("createdAt", .integer).notNull().indexed()
            t.column("originalName", .text)
            t.column("appName", .text)
            // Column name is "appIcon" for Electron compatibility; the
            // Swift app stores a bundle ID here (not a base64 blob).
            // See ClipboardItemRow + DomainMapping for details.
            t.column("appIcon", .text)
            t.column("searchPreview", .text)
            // Legacy Google-Drive id; kept for Electron backup compatibility.
            t.column("driveId", .text)
            t.column("thumbnailPath", .text)
            t.column("pageCount", .integer)
            t.column("wordCount", .integer)
            t.column("metadata", .text)
            t.column("contentHash", .text).indexed()
            t.column("analysis_text_done", .integer).notNull().defaults(to: 0)
            t.column("analysis_object_done", .integer).notNull().defaults(to: 0)
            t.column("analysis_updatedAt", .integer)
        }
        try db.create(
            index: "idx_items_type",
            on: "clipboard_items",
            columns: ["type"]
        )
        try db.create(
            index: "idx_items_type_createdAt",
            on: "clipboard_items",
            columns: ["type", "createdAt"]
        )
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
            t.column("kind", .text).notNull()
            t.column("text", .text)
            t.column("symbology", .text)
            t.column("payload", .text)
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
            t.column("pages", .text)  // JSON array of page strings
        }
    }

    private static func createFTSTables(_ db: Database) throws {
        // clipboard_fts — trigram for substring-friendly UI search.
        try db.create(virtualTable: "clipboard_fts", using: FTS5()) { t in
            t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
            t.column("searchPreview")
            t.column("content")
            t.synchronize(withTable: "clipboard_items")
        }

        // OCR results: porter for language-aware word search, plus a
        // trigram copy for in-image substring matching. Dual indexing
        // matches the Electron app's behavior.
        try db.create(virtualTable: "ocr_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("text")
            t.column("payload")
            t.synchronize(withTable: "ocr_results")
        }
        try db.create(virtualTable: "ocr_fts_trigram", using: FTS5()) { t in
            t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
            t.column("text")
            t.column("payload")
            t.synchronize(withTable: "ocr_results")
        }

        // Object synonyms: porter + trigram.
        try db.create(virtualTable: "object_synonyms_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("synonym")
            t.synchronize(withTable: "object_synonyms")
        }
        try db.create(virtualTable: "object_synonyms_trigram", using: FTS5()) { t in
            t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
            t.column("synonym")
            t.synchronize(withTable: "object_synonyms")
        }

        // Document full text.
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.tokenizer = .porter()
            t.column("full_text")
            t.synchronize(withTable: "document_text")
        }
    }

    /// Seed the settings K/V table with the defaults that the Settings
    /// view expects to find. `INSERT OR IGNORE` so a re-run (from a v2
    /// migration later) won't overwrite a user's choices.
    private static func seedDefaultSettings(_ db: Database) throws {
        let defaults: [(String, String)] = [
            ("retentionDays", "90"),
            ("monitorClipboard", "1"),
            ("monitorClipboardTextOnly", "0"),
            ("muteCopySound", "0"),
            ("screenshotMonitoring", "0"),
            ("screenshotFileTypes", "[\"png\",\"jpg\",\"mov\"]"),
            ("screenshotAfterImport", "keep"),
            ("analysisEnabled", "1"),
            ("showDockIcon", "1"),
        ]
        for (k, v) in defaults {
            try db.execute(
                sql: "INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)",
                arguments: [k, v]
            )
        }
    }
}
