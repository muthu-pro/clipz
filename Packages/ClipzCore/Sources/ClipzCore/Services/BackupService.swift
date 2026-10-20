// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import GRDB
import ZIPFoundation

/// Creates and restores `.clipzbackup` packages — a folder holding the
/// (optionally AES-GCM-encrypted) database + media files + a manifest.
///
/// Restore can't safely overwrite the SQLite file while it's open, so it
/// **stages** the decrypted files and drops a marker; `bootstrap` calls
/// `applyPendingRestoreIfNeeded` on the next launch, before the database
/// is opened, to perform the swap atomically.
public struct BackupService: Sendable {
    private let database: AppDatabase
    private let rootDir: URL
    private let mediaDir: URL

    public init(database: AppDatabase, fileStore: FileStore) {
        self.database = database
        self.rootDir = fileStore.rootDir
        self.mediaDir = fileStore.mediaDir
    }

    private var dbURL: URL { rootDir.appendingPathComponent(Self.dbName) }

    private static let manifestName = "manifest.json"
    private static let dbName = "clipz.db"
    private static let mediaDirName = "media"
    private static let stagingDirName = ".restore-staging"
    private static let markerName = ".pending-restore"
    private static let backupFormat = "clipz-backup"
    private static let backupVersion = 1

    // MARK: - Create

    /// Write a backup to `destination` (a single zip archive). When
    /// `password` is set every file inside is AES-GCM encrypted with a key
    /// derived from it. The manifest carries the backup + app + schema
    /// versions.
    public func createBackup(to destination: URL, password: String?) async throws {
        try await database.checkpoint()

        let fm = FileManager.default
        // Assemble the contents in a temp folder, then zip it.
        let work = fm.temporaryDirectory
            .appendingPathComponent("clipz-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let workMedia = work.appendingPathComponent(Self.mediaDirName, isDirectory: true)
        try fm.createDirectory(at: workMedia, withIntermediateDirectories: true)

        var salt: Data?
        var key: SymmetricKey?
        if let password {
            let generated = Self.randomSalt()
            salt = generated
            key = Self.deriveKey(password: password, salt: generated)
        }

        // Database.
        let dbData = try Data(contentsOf: dbURL)
        try Self.writeFile(dbData, to: work.appendingPathComponent(Self.dbName), key: key)
        var totalBytes = Int64(dbData.count)

        // Media.
        var mediaCount = 0
        let mediaFiles = (try? fm.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil
        )) ?? []
        for file in mediaFiles where !file.hasDirectoryPath {
            let data = try Data(contentsOf: file)
            try Self.writeFile(data, to: workMedia.appendingPathComponent(file.lastPathComponent), key: key)
            mediaCount += 1
            totalBytes += Int64(data.count)
        }

        // Manifest.
        let itemCount = (try? await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
        }) ?? 0

        let encryption: BackupManifest.EncryptionInfo? = salt.map {
            .init(algorithm: "AES-GCM", kdfAlgorithm: "HKDF-SHA256",
                  kdfParams: .init(n: 0, r: 0, p: 0), salt: $0, nonce: Data())
        }
        let manifest = BackupManifest(
            version: Self.backupVersion,
            format: Self.backupFormat,
            createdAt: Date(),
            dbSchemaVersion: AppDatabase.currentSchemaVersion,
            appVersion: Self.appVersion,
            itemCount: itemCount,
            mediaFileCount: mediaCount,
            totalBytes: totalBytes,
            encryption: encryption
        )
        try JSONEncoder().encode(manifest)
            .write(to: work.appendingPathComponent(Self.manifestName), options: .atomic)

        // Zip the assembled folder into a single archive at `destination`.
        try? fm.removeItem(at: destination)
        try fm.zipItem(at: work, to: destination, shouldKeepParent: false, compressionMethod: .deflate)
    }

    // MARK: - Restore (stage + marker)

    /// Validate and decrypt a backup, staging it for the next-launch swap.
    /// Returns the manifest so the UI can confirm the item count before the
    /// app relaunches.
    @discardableResult
    public func stageRestore(from archive: URL, password: String?) throws -> BackupManifest {
        let fm = FileManager.default

        // Unzip into a temp folder we read from.
        let source = fm.temporaryDirectory
            .appendingPathComponent("clipz-restore-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: source)
        do {
            try fm.unzipItem(at: archive, to: source)
        } catch {
            throw BackupError.invalidFormat
        }
        defer { try? fm.removeItem(at: source) }

        let manifestURL = source.appendingPathComponent(Self.manifestName)
        guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.invalidFormat }

        let manifest = try? JSONDecoder().decode(
            BackupManifest.self, from: Data(contentsOf: manifestURL)
        )
        guard let manifest, manifest.format == Self.backupFormat else {
            throw BackupError.invalidFormat
        }
        guard manifest.dbSchemaVersion <= AppDatabase.currentSchemaVersion else {
            throw BackupError.versionTooNew(
                fileVersion: manifest.dbSchemaVersion,
                supportedVersion: AppDatabase.currentSchemaVersion
            )
        }

        var key: SymmetricKey?
        if let enc = manifest.encryption {
            guard let password, !password.isEmpty else { throw BackupError.passwordRequired }
            key = Self.deriveKey(password: password, salt: enc.salt)
        }

        let staging = rootDir.appendingPathComponent(Self.stagingDirName, isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagingMedia = staging.appendingPathComponent(Self.mediaDirName, isDirectory: true)
        try fm.createDirectory(at: stagingMedia, withIntermediateDirectories: true)

        // Database.
        let dbData = try Self.readFile(at: source.appendingPathComponent(Self.dbName), key: key)
        try dbData.write(to: staging.appendingPathComponent(Self.dbName), options: .atomic)

        // Media.
        let srcMedia = source.appendingPathComponent(Self.mediaDirName, isDirectory: true)
        let mediaFiles = (try? fm.contentsOfDirectory(
            at: srcMedia, includingPropertiesForKeys: nil
        )) ?? []
        for file in mediaFiles where !file.hasDirectoryPath {
            let data = try Self.readFile(at: file, key: key)
            try data.write(to: stagingMedia.appendingPathComponent(file.lastPathComponent), options: .atomic)
        }

        // Marker — picked up on the next launch.
        try Data().write(to: rootDir.appendingPathComponent(Self.markerName))
        return manifest
    }

    // MARK: - Apply at launch (before the DB is opened)

    /// If a staged restore is pending, swap it into place. Must run *before*
    /// any database connection is opened.
    public static func applyPendingRestoreIfNeeded(rootDir: URL) {
        let fm = FileManager.default
        let marker = rootDir.appendingPathComponent(markerName)
        guard fm.fileExists(atPath: marker.path) else { return }

        let staging = rootDir.appendingPathComponent(stagingDirName, isDirectory: true)
        let stagedDB = staging.appendingPathComponent(dbName)
        guard fm.fileExists(atPath: stagedDB.path) else {
            try? fm.removeItem(at: marker)
            try? fm.removeItem(at: staging)
            return
        }

        // Replace the database (+ drop stale WAL/SHM so SQLite rebuilds).
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: rootDir.appendingPathComponent(dbName + suffix))
        }
        try? fm.moveItem(at: stagedDB, to: rootDir.appendingPathComponent(dbName))

        // Replace media wholesale.
        let stagedMedia = staging.appendingPathComponent(mediaDirName, isDirectory: true)
        if fm.fileExists(atPath: stagedMedia.path) {
            let liveMedia = rootDir.appendingPathComponent(mediaDirName, isDirectory: true)
            try? fm.removeItem(at: liveMedia)
            try? fm.moveItem(at: stagedMedia, to: liveMedia)
        }

        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: marker)
    }

    // MARK: - Crypto / IO

    private static func writeFile(_ data: Data, to url: URL, key: SymmetricKey?) throws {
        guard let key else {
            try data.write(to: url, options: .atomic)
            return
        }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw BackupError.interrupted }
        try combined.write(to: url, options: .atomic)
    }

    private static func readFile(at url: URL, key: SymmetricKey?) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard let key else { return raw }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: raw), using: key)
        } catch {
            throw BackupError.invalidPassword
        }
    }

    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: SHA256.hash(data: Data(password.utf8)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("clipz-backup".utf8),
            outputByteCount: 32
        )
    }

    private static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
