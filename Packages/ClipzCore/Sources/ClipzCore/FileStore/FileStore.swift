// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Container-scoped media file storage. Owns the directory where the app
/// writes clipboard-media bytes (PNG/JPEG/MOV/PDF/etc.) and the filename
/// → bytes mapping referenced from `clipboard_items.content`.
///
/// Path layout (under sandbox Application Support):
/// ```
/// clipz/
///   clipz.db             ← owned by AppDatabase
///   clipz.db-wal
///   clipz.db-shm
///   media/
///     <uuid>.png         ← writeMedia / importMedia
///     <uuid>_thumb.png   ← PDF/document thumbnails
///     <uuid>.bookmark    ← security-scoped bookmark for huge videos
/// ```
///
/// Intentionally a plain struct, not an actor: the file system is
/// already a shared resource and FileManager is thread-safe for
/// per-path operations. Callers (notably `ClipboardService`) serialize
/// access to the same filename themselves by actor isolation.
public struct FileStore: Sendable {
    public let rootDir: URL
    public let mediaDir: URL

    public init(rootDir: URL) throws {
        self.rootDir = rootDir
        self.mediaDir = rootDir.appendingPathComponent("media", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    /// Convenience — returns the sandbox-compatible default location
    /// (`~/Library/Application Support/clipz/`) resolved for the current
    /// container.
    public static func defaultApplicationSupport() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("clipz", isDirectory: true)
    }

    // MARK: - Writes

    /// Write a fresh blob for a freshly-captured clip.
    public func writeMedia(data: Data, filename: String) throws {
        try data.write(to: mediaURL(filename: filename), options: .atomic)
    }

    /// Copy a file into the store (drop-imports, migration, screenshot
    /// watcher). Overwrites any existing file at the same filename.
    public func importMedia(from source: URL, filename: String) throws {
        let dest = mediaURL(filename: filename)
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
    }

    /// Security-scoped bookmark bytes for large videos we don't want to
    /// copy into the container. Same writer path — the bytes happen to
    /// be a bookmark.
    public func writeBookmark(_ data: Data, filename: String) throws {
        try writeMedia(data: data, filename: filename)
    }

    // MARK: - Reads

    public func readMedia(filename: String) throws -> Data {
        try Data(contentsOf: mediaURL(filename: filename))
    }

    public func mediaURL(filename: String) -> URL {
        mediaDir.appendingPathComponent(filename)
    }

    public func mediaExists(filename: String) -> Bool {
        FileManager.default.fileExists(atPath: mediaURL(filename: filename).path)
    }

    // MARK: - Deletes

    /// Deletes a media file. Idempotent — a missing file is treated as
    /// success (the caller's invariant is "this file no longer exists").
    public func deleteMedia(filename: String) throws {
        let url = mediaURL(filename: filename)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let err as NSError where err.domain == NSCocoaErrorDomain
            && err.code == NSFileNoSuchFileError {
            return
        }
    }

    // MARK: - Stats

    /// Total size of the media directory in bytes. Walks the tree once;
    /// callers should cache — the UI calls this from the Danger tab.
    public func mediaBytes() -> Int64 {
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: mediaDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true, let size = values?.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// File count in the media directory — used by backup progress UI
    /// and the Danger tab.
    public func mediaFileCount() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mediaDir,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.count
    }
}

/// Aggregate storage usage — used by Settings → Danger to show the
/// breakdown bar (media / database / analysis).
public struct StorageUsage: Sendable {
    public let dbBytes: Int64
    public let mediaBytes: Int64
    public let itemCount: Int

    public init(
        dbBytes: Int64,
        mediaBytes: Int64,
        itemCount: Int
    ) {
        self.dbBytes = dbBytes
        self.mediaBytes = mediaBytes
        self.itemCount = itemCount
    }

    public var totalBytes: Int64 { dbBytes + mediaBytes }
}
