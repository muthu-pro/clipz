// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import GRDB
@testable import ClipzCore

@Suite("BackupService")
struct BackupServiceTests {

    /// Full pipeline: seed a DB + media file, create an *encrypted* zip
    /// backup, restore it into a fresh container, apply the staged swap,
    /// and confirm the row + media survive.
    @Test("encrypted zip backup → restore round-trip")
    func roundTrip() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipz-bk-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        // Source container with one item + one media file.
        let containerA = tmp.appendingPathComponent("A")
        try fm.createDirectory(at: containerA, withIntermediateDirectories: true)
        let dbA = try AppDatabase.make(at: containerA.appendingPathComponent("clipz.db"))
        let storeA = try FileStore(rootDir: containerA)

        let itemID = UUID().uuidString
        try await dbA.write { db in
            try ClipboardItemRow(
                id: itemID,
                type: ClipboardKind.image.rawValue,
                content: "\(itemID).png",
                createdAt: 1000
            ).insert(db)
        }
        try storeA.writeMedia(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), filename: "\(itemID).png")

        // Create an encrypted zip backup.
        let zip = tmp.appendingPathComponent("Clipz Backup.zip")
        try await BackupService(database: dbA, fileStore: storeA)
            .createBackup(to: zip, password: "hunter2")
        #expect(fm.fileExists(atPath: zip.path), "backup zip written")

        // Restore into a fresh container (DB not yet open there).
        let containerB = tmp.appendingPathComponent("B")
        try fm.createDirectory(at: containerB, withIntermediateDirectories: true)
        let storeB = try FileStore(rootDir: containerB)
        let restorer = BackupService(database: dbA, fileStore: storeB)  // db unused by restore
        let manifest = try restorer.stageRestore(from: zip, password: "hunter2")
        #expect(manifest.itemCount == 1)
        #expect(manifest.format == "clipz-backup")

        BackupService.applyPendingRestoreIfNeeded(rootDir: containerB)

        let dbB = try AppDatabase.make(at: containerB.appendingPathComponent("clipz.db"))
        let count = try await dbB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }
        #expect(count == 1, "row restored")
        #expect(fm.fileExists(atPath: storeB.mediaURL(filename: "\(itemID).png").path),
                "media restored")
    }

    @Test("wrong password is rejected")
    func wrongPassword() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipz-bk-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let containerA = tmp.appendingPathComponent("A")
        try fm.createDirectory(at: containerA, withIntermediateDirectories: true)
        let dbA = try AppDatabase.make(at: containerA.appendingPathComponent("clipz.db"))
        let storeA = try FileStore(rootDir: containerA)

        let zip = tmp.appendingPathComponent("b.zip")
        try await BackupService(database: dbA, fileStore: storeA)
            .createBackup(to: zip, password: "correct")

        let containerB = tmp.appendingPathComponent("B")
        try fm.createDirectory(at: containerB, withIntermediateDirectories: true)
        let storeB = try FileStore(rootDir: containerB)
        let restorer = BackupService(database: dbA, fileStore: storeB)
        #expect(throws: BackupError.self) {
            try restorer.stageRestore(from: zip, password: "wrong")
        }
    }
}
