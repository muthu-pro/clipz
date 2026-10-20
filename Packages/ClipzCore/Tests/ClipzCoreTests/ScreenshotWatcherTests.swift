// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("ScreenshotWatcher")
struct ScreenshotWatcherTests {

    /// Test harness that seeds the watcher against a temp folder rather
    /// than a security-scoped user-granted folder. The public bookmark
    /// path is exercised separately by `ScreenshotPermissionsTests`
    /// (system UI tests; not part of this suite).
    final class Bench {
        let watchDir: URL
        let db: AppDatabase
        let fileStore: FileStore
        let service: ClipboardService
        let settings: SettingsStore
        let watcher: ScreenshotWatcher

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipz-screen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            self.watchDir = tmp

            let media = tmp.appendingPathComponent("container")
            self.db = try AppDatabase.makeInMemory()
            self.fileStore = try FileStore(rootDir: media)
            let br = EventBroadcaster()
            let st = SettingsStore(database: db)
            self.settings = st
            self.service = ClipboardService(
                database: db, fileStore: fileStore, broadcaster: br, settings: st
            )
            self.watcher = ScreenshotWatcher(service: service, settings: settings)
        }

        deinit {
            try? FileManager.default.removeItem(at: watchDir)
        }

    }

    @Test func newPngFileTriggersCapture() async throws {
        let b = try Bench()
        try await b.watcher.start(watchingURL: b.watchDir)

        // Pretend to be macOS and write a Screenshot-named PNG.
        let png = b.watchDir.appendingPathComponent("Screenshot 2026-04-22 at 10.15.44 AM.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)

        // DispatchSource dispatches asynchronously — call folderChanged
        // directly so the test is deterministic.
        await b.watcher.folderChanged()

        let items = try await b.service.fetchPage()
        #expect(items.count == 1)
        #expect(items.first?.kind == .screenshot)
        #expect(items.first?.originalName == png.lastPathComponent)
    }

    @Test func preExistingFilesAreNotReImported() async throws {
        let b = try Bench()

        // Seed a "year-old" screenshot BEFORE starting the watcher.
        let old = b.watchDir.appendingPathComponent("Screenshot old.png")
        try Data([0x89, 0x50]).write(to: old)

        try await b.watcher.start(watchingURL: b.watchDir)
        await b.watcher.folderChanged()
        #expect(try await b.service.countItems() == 0)
    }

    @Test func nonScreenshotFilesAreSkipped() async throws {
        let b = try Bench()
        try await b.watcher.start(watchingURL: b.watchDir)

        let noise = b.watchDir.appendingPathComponent("random-document.pdf")
        try Data([0x25, 0x50]).write(to: noise)
        await b.watcher.folderChanged()

        let miscPng = b.watchDir.appendingPathComponent("wallpaper.png")
        try Data([0x89, 0x50]).write(to: miscPng)
        await b.watcher.folderChanged()

        // Neither is a screenshot-prefixed file; neither is captured.
        #expect(try await b.service.countItems() == 0)
    }

    @Test func deleteAfterImportTrashesSourceFile() async throws {
        let b = try Bench()
        await b.settings.set(SettingsKeys.screenshotAfterImport, .delete)
        try await b.watcher.start(watchingURL: b.watchDir)

        let png = b.watchDir.appendingPathComponent("Screenshot trash-me.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        await b.watcher.folderChanged()

        // The file should no longer be at its original path (moved to Trash).
        #expect(!FileManager.default.fileExists(atPath: png.path))
        #expect(try await b.service.countItems() == 1)
    }
}
