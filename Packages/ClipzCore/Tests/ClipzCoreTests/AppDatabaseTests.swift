// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import GRDB
@testable import ClipzCore

@Suite("AppDatabase migrations")
struct AppDatabaseTests {

    @Test func v1InitialCreatesExpectedTables() async throws {
        let db = try AppDatabase.makeInMemory()

        let expected: Set<String> = [
            "clipboard_items",
            "settings",
            "object_classes",
            "object_synonyms",
            "detections",
            "ocr_results",
            "document_text",
            "clipboard_fts",
            "ocr_fts",
            "ocr_fts_trigram",
            "object_synonyms_fts",
            "object_synonyms_trigram",
            "document_fts",
        ]

        let found = try await db.read { db in
            try String.fetchSet(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table')
                AND name NOT LIKE 'sqlite_%'
                AND name NOT LIKE 'grdb_%'
            """)
        }

        for table in expected {
            #expect(found.contains(table), "missing table: \(table)")
        }
    }

    @Test func v1InitialSeedsSettingsDefaults() async throws {
        let db = try AppDatabase.makeInMemory()

        let pairs = try await db.read { db -> [String: String] in
            var map: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
            for row in rows {
                map[row["key"]] = row["value"]
            }
            return map
        }

        #expect(pairs["retentionDays"] == "90")
        #expect(pairs["monitorClipboard"] == "1")
        #expect(pairs["analysisEnabled"] == "1")
        #expect(pairs["screenshotAfterImport"] == "keep")
        // Theme-related settings are intentionally absent.
        #expect(pairs["theme"] == nil)
        #expect(pairs["themeMode"] == nil)
    }

    @Test func foreignKeyCascadeDeletesAnalysisRows() async throws {
        let db = try AppDatabase.makeInMemory()

        try await db.write { db in
            let item = ClipboardItemRow(
                id: "cascade-1",
                type: ClipboardKind.image.rawValue,
                content: "pic.png",
                createdAt: 1_700_000_000_000
            )
            try item.insert(db)

            let ocr = OCRResultRow(
                itemID: "cascade-1",
                kind: "text",
                text: "hello world"
            )
            try ocr.insert(db)

            let detection = DetectionRow(
                itemID: "cascade-1",
                classID: 1,
                confidence: 0.9
            )
            try detection.insert(db)

            let docText = DocumentTextRow(
                itemID: "cascade-1",
                fullText: "body",
                pages: nil
            )
            try docText.insert(db)
        }

        try await db.write { db in
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?",
                           arguments: ["cascade-1"])
        }

        let counts = try await db.read { db -> (Int, Int, Int) in
            let ocrCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM ocr_results WHERE item_id = ?",
                arguments: ["cascade-1"]) ?? -1
            let detCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM detections WHERE item_id = ?",
                arguments: ["cascade-1"]) ?? -1
            let docCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM document_text WHERE item_id = ?",
                arguments: ["cascade-1"]) ?? -1
            return (ocrCount, detCount, docCount)
        }

        #expect(counts.0 == 0, "ocr_results should cascade-delete")
        #expect(counts.1 == 0, "detections should cascade-delete")
        #expect(counts.2 == 0, "document_text should cascade-delete")
    }

    @Test func clipboardFtsIsPopulatedByInsertTrigger() async throws {
        let db = try AppDatabase.makeInMemory()

        try await db.write { db in
            let item = ClipboardItemRow(
                id: "fts-1",
                type: ClipboardKind.text.rawValue,
                content: "the quick brown fox jumps over the lazy dog",
                createdAt: 1_700_000_000_000,
                searchPreview: "the quick brown fox"
            )
            try item.insert(db)
        }

        let hits = try await db.read { db -> Int in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clipboard_fts WHERE clipboard_fts MATCH ?",
                arguments: ["quick"]) ?? 0
        }
        #expect(hits == 1, "FTS synchronize trigger should have indexed the row")
    }
}
