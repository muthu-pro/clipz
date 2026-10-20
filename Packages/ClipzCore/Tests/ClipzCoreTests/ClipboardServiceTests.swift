// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("ClipboardService")
struct ClipboardServiceTests {

    // MARK: - Harness

    /// Spins up an in-memory AppDatabase, a temp FileStore, and a
    /// ClipboardService wired to them. Cleans the temp dir on deinit.
    final class Harness {
        let tempDir: URL
        let db: AppDatabase
        let fileStore: FileStore
        let broadcaster: EventBroadcaster
        let settings: SettingsStore
        let service: ClipboardService

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipz-test-\(UUID().uuidString)")
            self.tempDir = tmp
            self.db = try AppDatabase.makeInMemory()
            self.fileStore = try FileStore(rootDir: tmp)
            self.broadcaster = EventBroadcaster()
            self.settings = SettingsStore(database: db)
            self.service = ClipboardService(
                database: db,
                fileStore: fileStore,
                broadcaster: broadcaster,
                settings: settings
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Capture

    @Test func captureOfInlineTextInsertsRow() async throws {
        let h = try Harness()
        let payload = ClassifiedPayload(
            kind: .text,
            data: .inlineText("hello world"),
            sourceAppName: "TestApp",
            sourceAppBundleID: "com.example.test",
            searchPreview: "hello world"
        )

        let captured = await h.service.capture(payload)
        #expect(captured != nil)
        #expect(captured?.content == "hello world")
        #expect(captured?.sourceApp?.name == "TestApp")
        #expect(captured?.sourceApp?.bundleID == "com.example.test")

        let count = try await h.service.countItems()
        #expect(count == 1)
    }

    @Test func captureDedupsIdenticalConsecutivePayloads() async throws {
        let h = try Harness()
        let payload = ClassifiedPayload(
            kind: .text,
            data: .inlineText("dup")
        )
        _ = await h.service.capture(payload)
        let second = await h.service.capture(payload)
        #expect(second == nil)

        let count = try await h.service.countItems()
        #expect(count == 1)
    }

    @Test func captureOfImageDataWritesFileAndRecordsFilename() async throws {
        let h = try Harness()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic header, good enough for the fixture
        let payload = ClassifiedPayload(
            kind: .image,
            data: .imageData(bytes, ext: "png")
        )
        let captured = try #require(await h.service.capture(payload))
        // content holds the on-disk filename "<id>.png"
        #expect(captured.content.hasSuffix(".png"))
        #expect(h.fileStore.mediaExists(filename: captured.content))

        // DB round-trip retrieves the same row
        let fetched = try await h.service.fetchItem(id: captured.id)
        #expect(fetched?.id == captured.id)
        #expect(fetched?.kind == .image)
    }

    // MARK: - Fetch

    @Test func fetchPageReturnsNewestFirst() async throws {
        let h = try Harness()
        for i in 0..<5 {
            _ = await h.service.capture(
                ClassifiedPayload(kind: .text, data: .inlineText("row-\(i)"))
            )
            // tiny sleep so ms timestamps differ
            try await Task.sleep(for: .milliseconds(2))
        }
        let page = try await h.service.fetchPage(limit: 10)
        #expect(page.count == 5)
        #expect(page.first?.content == "row-4")
        #expect(page.last?.content == "row-0")
    }

    @Test func fetchPageAppliesKindFilter() async throws {
        let h = try Harness()
        _ = await h.service.capture(ClassifiedPayload(kind: .text, data: .inlineText("t1")))
        _ = await h.service.capture(ClassifiedPayload(kind: .html, data: .inlineText("h1")))
        _ = await h.service.capture(ClassifiedPayload(kind: .text, data: .inlineText("t2")))

        let onlyText = try await h.service.fetchPage(kindFilter: [.text])
        #expect(onlyText.count == 2)
        #expect(onlyText.allSatisfy { $0.kind == .text })
    }

    @Test func fetchUniqueSourceAppsOrdersByRecency() async throws {
        let h = try Harness()
        _ = await h.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("a1"), sourceAppName: "Slack"
        ))
        try await Task.sleep(for: .milliseconds(2))
        _ = await h.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("a2"), sourceAppName: "Safari"
        ))
        try await Task.sleep(for: .milliseconds(2))
        _ = await h.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("a3"), sourceAppName: "Slack"
        ))
        let apps = try await h.service.fetchUniqueSourceApps()
        #expect(apps.map(\.name) == ["Slack", "Safari"])
        #expect(apps.first?.count == 2)
    }

    // MARK: - Delete

    @Test func deleteRemovesRowAndFile() async throws {
        let h = try Harness()
        let bytes = Data("imgdata".utf8)
        let item = try #require(await h.service.capture(
            ClassifiedPayload(kind: .image, data: .imageData(bytes, ext: "png"))
        ))
        #expect(h.fileStore.mediaExists(filename: item.content))

        try await h.service.delete(id: item.id)
        #expect(!h.fileStore.mediaExists(filename: item.content))
        #expect(try await h.service.fetchItem(id: item.id) == nil)
    }

    @Test func deleteEverythingWipesAllRowsAndFiles() async throws {
        let h = try Harness()
        _ = await h.service.capture(ClassifiedPayload(
            kind: .image, data: .imageData(Data("a".utf8), ext: "png")
        ))
        _ = await h.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("just text")
        ))
        try await h.service.deleteEverything()

        #expect(try await h.service.countItems() == 0)
        #expect(h.fileStore.mediaFileCount() == 0)
    }

    // MARK: - Retention

    @Test func retentionDeletesRowsOlderThanCutoff() async throws {
        let h = try Harness()

        // Seed one row dated well in the past (~20 days ago).
        let ancient = ClipboardItemRow(
            id: "ancient",
            type: ClipboardKind.text.rawValue,
            content: "ancient",
            createdAt: Int64((Date().timeIntervalSince1970 - 20 * 86_400) * 1000)
        )
        try await h.db.write { db in
            try ancient.insert(db)
        }

        // Fresh row via capture.
        _ = await h.service.capture(ClassifiedPayload(
            kind: .text, data: .inlineText("fresh")
        ))
        let expiredCount = try await h.service.countExpired(olderThanDays: 10)
        #expect(expiredCount == 1)

        let deleted = try await h.service.deleteExpired(olderThanDays: 10)
        #expect(deleted == 1)
        #expect(try await h.service.countItems() == 1)
    }

    @Test func foreverRetentionDeletesNothing() async throws {
        let h = try Harness()
        let ancient = ClipboardItemRow(
            id: "ancient",
            type: ClipboardKind.text.rawValue,
            content: "ancient",
            createdAt: 1_000
        )
        try await h.db.write { db in try ancient.insert(db) }

        let deleted = try await h.service.deleteExpired(olderThanDays: Int.max)
        #expect(deleted == 0)
    }
}
