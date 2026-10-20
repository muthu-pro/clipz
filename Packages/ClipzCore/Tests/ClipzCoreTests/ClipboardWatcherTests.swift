// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import Testing
@testable import ClipzCore

@Suite("ClipboardWatcher")
struct ClipboardWatcherTests {

    /// Per-test NSPasteboard (keyed by a unique `Name` so the watcher
    /// and the test share the same underlying pasteboard instance
    /// without crossing isolation with a non-Sendable type).
    final class Bench {
        let tempDir: URL
        let db: AppDatabase
        let fileStore: FileStore
        let service: ClipboardService
        let settings: SettingsStore
        let watcher: ClipboardWatcher
        let pasteboardName: NSPasteboard.Name

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipz-watcher-\(UUID().uuidString)")
            self.tempDir = tmp
            self.db = try AppDatabase.makeInMemory()
            self.fileStore = try FileStore(rootDir: tmp)
            let br = EventBroadcaster()
            let st = SettingsStore(database: db)
            self.settings = st
            self.service = ClipboardService(
                database: db, fileStore: fileStore, broadcaster: br, settings: st
            )
            self.pasteboardName = NSPasteboard.Name("tech.clipz.watcher.\(UUID().uuidString)")
            self.watcher = ClipboardWatcher(
                service: service,
                settings: settings,
                pasteboardName: pasteboardName
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// Named pasteboards in macOS are process-wide singletons — the
        /// test and the watcher hold references to the same underlying
        /// object because both ask for the same name.
        var pasteboard: NSPasteboard {
            NSPasteboard(name: pasteboardName)
        }
    }

    @Test func tickCapturesTextOnPasteboardChange() async throws {
        let b = try Bench()
        b.pasteboard.clearContents()
        b.pasteboard.setString("captured-by-watcher", forType: .string)

        let item = try #require(await b.watcher.tick())
        #expect(item.kind == .text)
        #expect(item.content == "captured-by-watcher")
    }

    @Test func ignoreNextSkipsTheFollowingCapture() async throws {
        let b = try Bench()
        b.pasteboard.clearContents()
        b.pasteboard.setString("baseline", forType: .string)
        _ = await b.watcher.tick()

        await b.watcher.ignoreNextChange()
        b.pasteboard.clearContents()
        b.pasteboard.setString("should-be-ignored", forType: .string)
        let second = await b.watcher.tick()
        #expect(second == nil)

        // And the next one comes through.
        b.pasteboard.clearContents()
        b.pasteboard.setString("third", forType: .string)
        let third = await b.watcher.tick()
        #expect(third?.content == "third")
    }

    @Test func tickIsNoOpIfChangeCountHasNotAdvanced() async throws {
        let b = try Bench()
        let result = await b.watcher.tick()
        #expect(result == nil)
    }
}
