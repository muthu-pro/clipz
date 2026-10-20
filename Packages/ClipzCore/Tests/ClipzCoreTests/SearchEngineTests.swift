// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("SearchEngine")
struct SearchEngineTests {

    /// Convenience: build an in-memory AppDatabase and a ClipboardService,
    /// the same harness as ClipboardServiceTests.
    final class Bench {
        let tempDir: URL
        let db: AppDatabase
        let fileStore: FileStore
        let service: ClipboardService
        let engine: SearchEngine

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipz-search-\(UUID().uuidString)")
            self.tempDir = tmp
            self.db = try AppDatabase.makeInMemory()
            self.fileStore = try FileStore(rootDir: tmp)
            let br = EventBroadcaster()
            let settings = SettingsStore(database: db)
            self.service = ClipboardService(
                database: db,
                fileStore: fileStore,
                broadcaster: br,
                settings: settings
            )
            self.engine = SearchEngine(database: db)
        }

        deinit { try? FileManager.default.removeItem(at: tempDir) }
    }

    @Test func returnsEmptyPageForEmptyQuery() async throws {
        let b = try Bench()
        let page = try await b.engine.search(query: "")
        #expect(page.results.isEmpty)
    }

    @Test func matchesPorterIndexedContent() async throws {
        let b = try Bench()
        _ = await b.service.capture(ClassifiedPayload(
            kind: .text,
            data: .inlineText("the quick brown fox jumps"),
            searchPreview: "the quick brown fox jumps"
        ))
        _ = await b.service.capture(ClassifiedPayload(
            kind: .text,
            data: .inlineText("a completely different sentence about dogs"),
            searchPreview: "a completely different sentence about dogs"
        ))

        let page = try await b.engine.search(query: "brown")
        #expect(page.results.count == 1)
        #expect(page.results.first?.item.content.contains("fox") == true)
        #expect(page.results.first?.matches.first?.source == .content)
    }

    @Test func shortQueryFallsBackToLike() async throws {
        let b = try Bench()
        _ = await b.service.capture(ClassifiedPayload(
            kind: .text,
            data: .inlineText("a quick experiment"),
            searchPreview: "a quick experiment"
        ))
        // 1-char query triggers LIKE fallback.
        let page = try await b.engine.search(query: "a")
        #expect(page.results.count >= 1)
    }

    @Test func dedupsMultipleSourcesToOneResultPerItem() async throws {
        let b = try Bench()
        _ = await b.service.capture(ClassifiedPayload(
            kind: .image,
            data: .imageData(Data([0x89, 0x50]), ext: "png"),
            searchPreview: "keychain dedup image"
        ))
        // Attach an OCR result that ALSO matches the query — the CTE
        // should group both sources into a single SearchResult.
        let itemID = try await b.db.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT id FROM clipboard_items LIMIT 1")
        }
        try #require(itemID != nil)

        try await b.db.write { db in
            let row = OCRResultRow(
                itemID: itemID!,
                kind: "text",
                text: "keychain ratchet excerpt from OCR"
            )
            try row.insert(db)
        }

        let page = try await b.engine.search(query: "keychain")
        #expect(page.results.count == 1)
        #expect(page.results.first?.matches.count ?? 0 >= 2)
        let sources = Set((page.results.first?.matches ?? []).map(\.source))
        #expect(sources.contains(.content) || sources.contains(.ocrText))
    }

    @Test func respectsKindFilter() async throws {
        let b = try Bench()
        _ = await b.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("keychain in text"),
            searchPreview: "keychain in text"
        ))
        _ = await b.service.capture(ClassifiedPayload(
            kind: .html, data: .inlineText("keychain in html"),
            searchPreview: "keychain in html"
        ))
        let page = try await b.engine.search(query: "keychain", kindFilter: [.text])
        #expect(page.results.count == 1)
        #expect(page.results.first?.item.kind == .text)
    }
}
