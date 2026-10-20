# swift_17 — Backup and Restore

## Purpose

Create password-protectable backup archives containing the full database + media, and restore them to a fresh app install. Preserves the **exact archive format** from the Electron app's `electron/backup-manager.js` so users can migrate Electron-era backups to the Swift app on first launch.

Replaces: `electron/backup-manager.js` (~200 lines), `create-backup` / `restore-backup` / `validate-backup` / `get-backup-info` / `check-backup-password` IPC handlers.

## Current Electron format (to preserve)

Backup is a **ZIP archive** with a `.clipzbackup` extension. Contents:

```
backup.zip
├── manifest.json
├── clipz.db                 (SQLite main; no WAL since DB was checkpointed before backup)
└── media/
    ├── <uuid>.png
    ├── <uuid>.pdf
    ├── …
```

### Manifest shape

```json
{
  "version": 1,
  "format": "clipz-backup",
  "createdAt": "2026-04-10T18:23:01Z",
  "dbSchemaVersion": 1,
  "appVersion": "1.0.0-beta.13",
  "itemCount": 2451,
  "noteCount": 17,
  "taskCount": 8,
  "mediaFileCount": 1104,
  "totalBytes": 285700432,
  "encryption": {
    "algorithm": "AES-GCM",
    "kdfAlgorithm": "scrypt",
    "kdfParams": { "n": 16384, "r": 8, "p": 1 },
    "salt": "base64...",
    "nonce": "base64..."
  }
}
```

If `encryption` is present, `clipz.db` and `media/*` are encrypted. The Electron app uses AES-256-GCM with an scrypt-derived key. Our implementation matches this byte-for-byte.

If `encryption` is `null` (or absent), files are stored plain.

## Swift design

### Service

```swift
// Packages/ClipzCore/Sources/ClipzCore/Backup/BackupService.swift
import Foundation
import Compression
import CryptoKit

public final class BackupService: Sendable {
    private let database: AppDatabase
    private let fileStore: FileStore

    public init(database: AppDatabase, fileStore: FileStore) {
        self.database = database
        self.fileStore = fileStore
    }

    // MARK: - Create

    public func create(to destination: URL, password: String?)
        -> AsyncThrowingStream<BackupProgress, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    try await self.doCreate(to: destination, password: password,
                                             yield: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Restore

    public func restore(from source: URL, password: String?) async throws { … }

    public func getInfo(from source: URL) async throws -> BackupManifest { … }

    public func checkPassword(for source: URL, password: String) async throws -> Bool { … }
}

public struct BackupProgress: Sendable {
    public let stage: Stage
    public let fraction: Double       // 0.0 ... 1.0
    public var stageDescription: String { stage.description }

    public enum Stage: Sendable {
        case preparing
        case copyingDatabase
        case copyingMedia(done: Int, total: Int)
        case encrypting
        case compressing
        case writing
        case finished
    }
}
```

### Create flow

```swift
private func doCreate(to destination: URL, password: String?,
                      yield: (BackupProgress) -> Void) async throws {
    yield(BackupProgress(stage: .preparing, fraction: 0.05))

    // 1. Check free space
    let usage = fileStore.usage()
    let expected = usage.totalBytes
    let free = try freeDiskSpace(at: destination)
    guard free > Int64(Double(expected) * 1.2) else {
        throw BackupError.insufficientSpace(required: expected, available: free)
    }

    // 2. Stage to tmp
    let stageDir = fileStore.tempDir.appendingPathComponent("backup-\(UUID())",
                                                             isDirectory: true)
    try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stageDir) }

    // 3. Database: WAL checkpoint to ensure clipz.db is self-contained, then copy
    yield(BackupProgress(stage: .copyingDatabase, fraction: 0.10))
    try await database.checkpoint()
    let dbCopy = stageDir.appendingPathComponent("clipz.db")
    try FileManager.default.copyItem(at: fileStore.databaseURL, to: dbCopy)

    // 4. Media files
    let mediaDest = stageDir.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDest, withIntermediateDirectories: true)
    let mediaFiles = (try? FileManager.default.contentsOfDirectory(at: fileStore.mediaDir,
        includingPropertiesForKeys: nil)) ?? []
    for (i, url) in mediaFiles.enumerated() {
        try FileManager.default.copyItem(at: url,
            to: mediaDest.appendingPathComponent(url.lastPathComponent))
        yield(BackupProgress(stage: .copyingMedia(done: i + 1, total: mediaFiles.count),
                              fraction: 0.10 + 0.6 * (Double(i + 1) / Double(mediaFiles.count))))
    }

    // 5. Manifest
    var manifest = BackupManifest(
        version: 1, format: "clipz-backup", createdAt: Date(),
        dbSchemaVersion: 1, appVersion: Bundle.main.shortVersion,
        itemCount: try await countItems(),
        noteCount:  try await countNotes(),
        taskCount:  try await countTasks(),
        mediaFileCount: mediaFiles.count,
        totalBytes: expected,
        encryption: nil
    )

    // 6. Encrypt (if password) — encrypts the db + each media file in place
    var encryption: BackupManifest.EncryptionInfo? = nil
    if let password {
        yield(BackupProgress(stage: .encrypting, fraction: 0.72))
        encryption = try encryptInPlace(stageDir: stageDir, password: password)
        manifest.encryption = encryption
    }

    // 7. Write manifest
    let manifestData = try JSONEncoder.iso8601.encode(manifest)
    try manifestData.write(to: stageDir.appendingPathComponent("manifest.json"))

    // 8. Zip to destination
    yield(BackupProgress(stage: .compressing, fraction: 0.80))
    try ZipArchiver.zip(contentsOf: stageDir, to: destination,
                        progress: { frac in
                            yield(BackupProgress(stage: .writing,
                                                  fraction: 0.80 + 0.20 * frac))
                        })
    yield(BackupProgress(stage: .finished, fraction: 1.0))
}
```

### Encryption

Uses **AES-256-GCM** with a scrypt-derived key, matching the Electron format.

```swift
// Packages/ClipzCore/Sources/ClipzCore/Backup/BackupCrypto.swift
import CryptoKit
import Foundation

enum BackupCrypto {
    static func deriveKey(password: String, salt: Data,
                          n: Int, r: Int, p: Int) throws -> SymmetricKey {
        // Apple's CryptoKit doesn't ship scrypt. Use Apple's CommonCrypto CCKeyDerivationPBKDF
        // or a small bundled scrypt implementation.
        //
        // Recommendation: use swift-crypto + bcrypt? No — we must match the Electron
        // manifest's scrypt params. Ship a tiny scrypt.c vendored in the package, or
        // import a SwiftPM library like `Sodium` or `swift-scrypt`.
        let derived = try Scrypt.deriveKey(password: password, salt: salt,
                                            n: n, r: r, p: p, dkLen: 32)
        return SymmetricKey(data: derived)
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce)
        throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        // Store nonce + ciphertext + tag concatenated; manifest carries nonce once
        // but per-file encryption uses a derived-per-file nonce (nonce || filename).
        return sealed.ciphertext + sealed.tag
    }

    static func decrypt(_ ciphertext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce)
        throws -> Data {
        // Ciphertext must be split: last 16 bytes are the tag.
        let tagSize = 16
        let ct = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(sealed, using: key)
    }
}
```

Use the Scrypt implementation from swift-crypto-extras or a vendored C source. Sandbox imposes no restriction; just SPM dependency.

### File-by-file encryption protocol

For each file in the staged backup directory:

1. Derive nonce: `HMAC-SHA256(key, filename)` → take first 12 bytes.
2. Read the file bytes.
3. Encrypt with AES-GCM (key, nonce) → produces ciphertext + tag.
4. Overwrite the file with `nonce || ciphertext || tag`.

On restore, reverse the steps.

This is the protocol the Electron app uses (verified against `electron/backup-manager.js`). Keeping it identical means backups are interoperable in both directions.

### Zip

Use `Compression` framework + a small zip-format layer. Two options:

1. **Apple's `AppleArchive`** — newer, not POSIX-ZIP compatible without extra layers. The Electron app produces POSIX ZIP (via `archiver` Node module). Using AppleArchive would break compatibility.
2. **Vendor a minimal Zip writer** — e.g., `ZIPFoundation` (MIT) SPM library. Supports streaming, POSIX-ZIP format, progress reporting.

**Recommendation**: `ZIPFoundation`.

```swift
import ZIPFoundation

enum ZipArchiver {
    static func zip(contentsOf dir: URL, to destination: URL,
                    progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard let archive = Archive(url: destination, accessMode: .create) else {
            throw BackupError.corruptBackup
        }
        let files = try fm.subpathsOfDirectory(atPath: dir.path)
        for (i, rel) in files.enumerated() {
            let src = dir.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            try archive.addEntry(with: rel, relativeTo: dir,
                                  compressionMethod: .deflate)
            progress(Double(i + 1) / Double(files.count))
        }
    }

    static func unzip(_ source: URL, to dir: URL,
                      progress: (Double) -> Void = { _ in }) throws {
        try FileManager.default.unzipItem(at: source, to: dir, progress: nil, preferredEncoding: .utf8)
    }
}
```

### Restore flow

```swift
public func restore(from source: URL, password: String?) async throws {
    let stageDir = fileStore.tempDir.appendingPathComponent("restore-\(UUID())",
                                                             isDirectory: true)
    try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stageDir) }

    // 1. Unzip
    try ZipArchiver.unzip(source, to: stageDir)

    // 2. Read manifest
    let manifestData = try Data(contentsOf: stageDir.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder.iso8601.decode(BackupManifest.self, from: manifestData)

    // 3. Compatibility check
    try checkCompatibility(manifest: manifest)

    // 4. Decrypt (if needed)
    if let encryption = manifest.encryption {
        guard let password else { throw BackupError.passwordRequired }
        try decryptInPlace(stageDir: stageDir, encryption: encryption, password: password)
    }

    // 5. Close current DB
    try await database.closeForRestore()

    // 6. Move current data aside (enables rollback on failure)
    let oldDBURL = fileStore.databaseURL.appendingPathExtension("old")
    try? FileManager.default.removeItem(at: oldDBURL)
    if FileManager.default.fileExists(atPath: fileStore.databaseURL.path) {
        try FileManager.default.moveItem(at: fileStore.databaseURL, to: oldDBURL)
    }
    let oldMediaURL = fileStore.root.appendingPathComponent("media.old", isDirectory: true)
    try? FileManager.default.removeItem(at: oldMediaURL)
    try FileManager.default.moveItem(at: fileStore.mediaDir, to: oldMediaURL)

    // 7. Copy new data in
    try FileManager.default.moveItem(at: stageDir.appendingPathComponent("clipz.db"),
                                       to: fileStore.databaseURL)
    try FileManager.default.moveItem(at: stageDir.appendingPathComponent("media"),
                                       to: fileStore.mediaDir)

    // 8. Re-open and run migrations for newer schemas
    _ = try AppDatabase.make(at: fileStore.databaseURL)

    // 9. Clean up old data (safe now)
    try? FileManager.default.removeItem(at: oldDBURL)
    try? FileManager.default.removeItem(at: oldMediaURL)
}

private func checkCompatibility(manifest: BackupManifest) throws {
    let supportedSchemaVersion = 1
    if manifest.dbSchemaVersion > supportedSchemaVersion {
        throw BackupError.versionTooNew(
            fileVersion: manifest.dbSchemaVersion,
            supportedVersion: supportedSchemaVersion)
    }
    // Older schema: the normal DatabaseMigrator handles upgrades after restore.
}
```

### Password check

Verify the password without fully decrypting:

```swift
public func checkPassword(for source: URL, password: String) async throws -> Bool {
    let manifest = try await getInfo(from: source)
    guard let enc = manifest.encryption else { return true }

    let key = try BackupCrypto.deriveKey(
        password: password, salt: enc.salt,
        n: enc.kdfParams.n, r: enc.kdfParams.r, p: enc.kdfParams.p)

    // Try to decrypt the first media file header; fail = wrong password
    let stageDir = fileStore.tempDir.appendingPathComponent("check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: stageDir) }
    try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
    try ZipArchiver.unzipSinglePath(source, path: "clipz.db", to: stageDir)
    let encData = try Data(contentsOf: stageDir.appendingPathComponent("clipz.db"))
    let nonce = try AES.GCM.Nonce(data: encData.prefix(12))
    let body = encData.dropFirst(12)
    _ = try BackupCrypto.decrypt(Data(body), key: key, nonce: nonce)
    return true
}
```

If decrypt throws (`CryptoKit.CryptoKitError.authenticationFailure`), password is wrong.

### Info (manifest only, fast)

```swift
public func getInfo(from source: URL) async throws -> BackupManifest {
    let tmp = fileStore.tempDir.appendingPathComponent("info-\(UUID())")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try ZipArchiver.unzipSinglePath(source, path: "manifest.json", to: tmp)
    let data = try Data(contentsOf: tmp.appendingPathComponent("manifest.json"))
    return try JSONDecoder.iso8601.decode(BackupManifest.self, from: data)
}
```

## Edge cases & gotchas

1. **WAL checkpoint before backup** — `PRAGMA wal_checkpoint(TRUNCATE)` flushes WAL into main DB so the `clipz.db` file alone is complete. Otherwise a restore might be missing recent writes. Implemented as `database.checkpoint()`.

2. **In-flight captures during backup** — serialize with `DatabasePool`. No reader can see a half-written state thanks to WAL; the backup is a consistent snapshot as of checkpoint time.

3. **Password wrong** — decrypt throws authenticationFailure; surface as `BackupError.invalidPassword`. Don't leak timing/bytes.

4. **Backup larger than free disk** — check space *before* starting. Include a 20% margin for compression inefficiency in the worst case.

5. **Electron-era backups without encryption info** — older manifests may lack the `encryption` field. Decoder treats missing field as `nil` (not encrypted). Fine.

6. **Newer backup than app supports** — `BackupError.versionTooNew`. Show user "Update Clipz to restore this backup."

7. **Partial restore failure** — rollback: the "move current aside" step provides a rollback window. If anything fails after step 7, restore `oldDBURL` + `oldMediaURL` back. Worst case: user has original state intact.

8. **Restore during an active backup** — block mutually; only one of `create`/`restore` runs at a time, gated by a shared actor.

9. **Large video bookmarks in backup** — bookmarks reference external files the user selected. Don't export bookmarks; they won't resolve on another machine. On export, bookmarked items' `content` field still references the `.bookmark` file, which backs up as-is. On restore to a different machine, those items become broken references; the service can detect and mark them "unreachable" in the UI.

10. **Timezone of `createdAt` in manifest** — always UTC (ISO8601 `Z` suffix). JSONEncoder.iso8601 uses UTC.

11. **App version string for compat** — `Bundle.main.shortVersion` at backup time; useful for user-facing "Backup from Clipz 1.0.2" display.

12. **Relaunch after restore** — in the Settings UI (swift_14), after a successful restore, call `NSApp.relaunch()` (custom helper using `NSWorkspace.openApplication` + `NSApp.terminate`) so the app starts clean against the new DB.

## MAS notes

- **Destination path** — NSSavePanel provides a user-scoped URL; writing there is sandbox-legal.
- **Source path** — NSOpenPanel likewise for restore.
- **tmp/** staging stays in container.
- **CryptoKit / Compression** — sandbox-safe.
- **ZIPFoundation** — pure Swift, no external dependencies; sandbox-safe.

## Open questions

- **Incremental backups** — v1 is full backup only. Incremental (only-changed-media) could cut backup size for heavy users. Defer.
- **Cloud backup** — via iCloud Drive? Not in v1; users can manually drop a backup into iCloud Drive by saving there.
- **Backup encryption algorithm upgrade** — if Apple deprecates scrypt, we'd need a v2 manifest format. Design room for it via `version` in manifest.
- **Auto-backup schedule** — "Back up to this folder every week" — nice feature, out of v1. When added, use `BGTaskScheduler` with a security-scoped bookmark to the target folder.
