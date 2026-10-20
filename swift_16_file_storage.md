# swift_16 — File Storage

## Purpose

Where media files (images, screenshots, videos, PDFs, Office docs) live on disk, how they're named, how they're cleaned up, and how the UI fetches URLs for rendering. Replaces `~/Library/Application Support/clipz/` from the Electron app (where it was unsandboxed) with the container-scoped `~/Library/Containers/tech.clipz.app/Data/Library/Application Support/clipz/media/` (sandbox).

## Current Electron behavior

- Media saved to `~/Library/Application Support/clipz/` with filenames derived from item UUIDs plus original extension.
- Renderer gets paths via `get-file-url` IPC → returns `file://` URL.
- Storage usage read via `get-storage-usage` IPC (sum of directory + DB).
- No explicit orphan sweep; heuristic cleanup on delete.

## Swift design

### Directory layout

```
~/Library/Containers/tech.clipz.app/Data/Library/
  Application Support/
    clipz/
      clipz.db                  (SQLite main + WAL companions)
      clipz.db-wal
      clipz.db-shm
      media/                    (media files)
        <uuid>.png
        <uuid>.pdf
        <uuid>_thumb.png        (PDF thumbnails)
        <uuid>.bookmark         (security-scoped bookmarks for large videos)
      tmp/                      (transient staging during capture/backup)
      bookmarks/
        screenshot-folder.bookmark
```

All of this lives inside the container — no entitlement beyond base sandbox needed.

### FileStore type

```swift
// Packages/ClipzCore/Sources/ClipzCore/FileStore/FileStore.swift
import Foundation

public struct FileStore: Sendable {
    public static let shared: FileStore = {
        try! .applicationSupport
    }()

    public static var applicationSupport: FileStore {
        get throws {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("clipz", isDirectory: true)
            return try FileStore(root: root)
        }
    }

    public let root: URL
    public let mediaDir: URL
    public let tempDir: URL
    public let bookmarksDir: URL
    public let databaseURL: URL

    private init(root: URL) throws {
        self.root = root
        self.mediaDir    = root.appendingPathComponent("media", isDirectory: true)
        self.tempDir     = root.appendingPathComponent("tmp", isDirectory: true)
        self.bookmarksDir = root.appendingPathComponent("bookmarks", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("clipz.db")
        try createDirectories()
    }

    private func createDirectories() throws {
        for dir in [mediaDir, tempDir, bookmarksDir] {
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: - Media operations

    public func mediaURL(for filename: String) -> URL {
        mediaDir.appendingPathComponent(filename)
    }

    public func mediaURLIfExists(for filename: String) -> URL? {
        let url = mediaURL(for: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func writeMedia(data: Data, filename: String) throws {
        let url = mediaURL(for: filename)
        try data.write(to: url, options: .atomic)
    }

    public func importMedia(from source: URL, filename: String) throws {
        let dest = mediaURL(for: filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
    }

    public func deleteMedia(filename: String) throws {
        let url = mediaURL(for: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func writeBookmark(_ data: Data, filename: String) throws {
        let url = mediaDir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
    }

    public func readBookmark(filename: String) throws -> URL? {
        let url = mediaDir.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: data,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        return stale ? nil : resolved
    }

    // MARK: - Temp

    public func writeTemp(data: Data, ext: String) throws -> URL {
        let name = "\(UUID().uuidString).\(ext)"
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func clearTemp() {
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Usage

    public func usage() -> StorageUsage {
        StorageUsage(
            dbBytes: size(at: databaseURL)
                   + size(at: databaseURL.appendingPathExtension("-wal"))
                   + size(at: databaseURL.appendingPathExtension("-shm")),
            mediaBytes: directorySize(mediaDir),
            tempBytes: directorySize(tempDir)
        )
    }

    private func size(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: dir,
            includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(s)
        }
        return total
    }
}

public struct StorageUsage: Sendable {
    public let dbBytes: Int64
    public let mediaBytes: Int64
    public let tempBytes: Int64
    public var totalBytes: Int64 { dbBytes + mediaBytes + tempBytes }
}
```

### URL → SwiftUI rendering

SwiftUI consumes URLs natively:

```swift
AsyncImage(url: FileStore.shared.mediaURL(for: item.content))
```

No `getFileUrl` IPC needed. The URL is a container file URL — sandbox-legal for read/write.

### Extended attribute: no-backup flag

The app's primary storage *is* backed up via Time Machine (user expectation). Don't set `isExcludedFromBackup`.

Exception: the **tmp/** directory is transient; mark it excluded:

```swift
private func createDirectories() throws {
    for dir in [mediaDir, tempDir, bookmarksDir] {
        try FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
    }
    var tempValues = URLResourceValues()
    tempValues.isExcludedFromBackup = true
    var tempURL = tempDir
    try tempURL.setResourceValues(tempValues)
}
```

### Orphan sweep

Periodic sweep finds files in `media/` with no matching DB row and removes them. Keeps storage clean after crashes or partial deletes:

```swift
extension ClipboardService {
    public func sweepOrphans() async {
        let filenames: Set<String> = try? await database.read { db in
            let items = try String.fetchAll(db, sql: "SELECT content FROM clipboard_items")
            let thumbs = try String.fetchAll(db, sql: """
                SELECT thumbnailPath FROM clipboard_items WHERE thumbnailPath IS NOT NULL
            """)
            return Set(items + thumbs)
        } ?? []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: fileStore.mediaDir, includingPropertiesForKeys: nil) else { return }

        let now = Date()
        for url in contents {
            let name = url.lastPathComponent
            if filenames.contains(name) { continue }
            // Grace period: only delete if file hasn't been touched for 24 h,
            // protecting in-flight captures.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .contentModificationDate ?? now
            if now.timeIntervalSince(mtime) > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
```

Run weekly from a background task kicked off on app start.

### App icon cache (for source-app attribution)

```swift
// Packages/ClipzUI/Sources/ClipzUI/Theming/AppIconCache.swift
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]

    public func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[bundleID] = icon
        return icon
    }

    public func invalidate() { cache.removeAll() }
}
```

UI usage:

```swift
struct AppIconView: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let bundleID, let icon = AppIconCache.shared.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            }
        }
    }
}
```

Refresh the cache on `NSWorkspace.didLaunchApplicationNotification` so newly-installed apps get their icons resolved without an app restart.

### PDF thumbnail generation

```swift
// Packages/ClipzCore/Sources/ClipzCore/FileStore/PDFInspector.swift
import PDFKit

public enum PDFInspector {
    public static func pageCount(fileURL: URL) -> Int? {
        PDFDocument(url: fileURL)?.pageCount
    }

    public static func renderThumbnail(fileURL: URL, page: Int = 0,
                                        size: CGSize = CGSize(width: 200, height: 260))
        throws -> Data {
        guard let doc = PDFDocument(url: fileURL),
              let pdfPage = doc.page(at: page) else {
            throw NSError(domain: "ClipzFileStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open PDF"])
        }
        let image = pdfPage.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipzFileStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return png
    }
}
```

Called from `ClipboardService.persist` (swift_07) when saving a PDF item.

### Vacuum / maintenance

```swift
extension AppDatabase {
    public func vacuum() async throws {
        try await write { db in try db.execute(sql: "VACUUM") }
    }

    public func incrementalVacuum() async throws {
        try await write { db in try db.execute(sql: "PRAGMA incremental_vacuum") }
    }
}
```

`incrementalVacuum` scheduled quarterly; full `VACUUM` only on user request from the Danger tab (swift_14).

## Edge cases & gotchas

1. **Filename collision** — UUID-based; collision probability is negligible. No collision check needed.

2. **Large video file copy** — `FileManager.copyItem` is synchronous but fast for filesystem-local copies (APFS clone). For cross-volume sources, it's slower; acceptable because capture is already off the main thread.

3. **Bookmark staleness** — handled per-file; we store a `.bookmark` sibling with the same UUID stem. Reading the bookmark may return `isStale=true`; in that case, surface a "restore permission" prompt for that item.

4. **iCloud Drive in user-selected location** — user could pick an iCloud-synced folder as the screenshot source; the bookmark stays valid but reads may stall if the file is evicted from local cache. Not our problem to solve; works eventually.

5. **Disk full during capture** — `data.write(to:options:.atomic)` throws; service logs and drops the capture. No data corruption thanks to atomic writes.

6. **Media older than container** — if the user reinstalls after an uninstall, the container is recreated fresh; old media is gone. Backups (swift_17) are the recovery path.

7. **tmp/** growth — `clearTemp()` invoked on app launch and on backup completion. Transient files never persist across sessions.

8. **Security scoping for bookmarks** — `startAccessingSecurityScopedResource()` must be called before every read of a bookmarked URL, paired with `stopAccessingSecurityScopedResource()` when done. Wrap in a Swift `withExtendedLifetime`-style helper:

   ```swift
   public func withBookmarkedURL<T>(_ filename: String,
                                     perform: (URL) throws -> T) throws -> T {
       guard let url = try readBookmark(filename: filename) else {
           throw FileStoreError.bookmarkStale
       }
       guard url.startAccessingSecurityScopedResource() else {
           throw FileStoreError.permissionDenied
       }
       defer { url.stopAccessingSecurityScopedResource() }
       return try perform(url)
   }
   ```

9. **App group shared container** — `com.apple.security.application-groups` would let future extensions (e.g., a Share Extension in v2) share the container. The entitlements include the group for forward-compat even if nothing uses it in v1. Storage path then becomes `containerURL(forSecurityApplicationGroupIdentifier: "group.tech.clipz.shared")`.

10. **AsyncImage over file URLs** — `AsyncImage(url:)` supports `file://` URLs natively but doesn't handle security-scoped resources. If we ever render a bookmarked video thumbnail, use `AsyncImage(url: resolvedURL)` inside `withBookmarkedURL`.

## MAS notes

- Container directory is always writable; no entitlement.
- Security-scoped bookmarks need `com.apple.security.files.bookmarks.app-scope` — added in swift_19's entitlements list.
- Reading from user-granted folders (screenshot folder) via `startAccessingSecurityScopedResource` — works in sandbox.
- App group container — needs `com.apple.security.application-groups` entitlement. Declared in entitlements even if unused today.

## Open questions

- **CloudKit sync** — v2 target; would require moving media to a CloudKit-backed store. Out of v1.
- **Content-addressable storage** (store files by content hash, dedup across items) — cleaner but complicates retention + backup. Skip; UUID-based storage is pragmatic.
- **Per-kind subdirectories** (media/images, media/pdfs, ...) — helps filesystem-level browsing but doesn't help the app. Skip.
- **Spotlight indexing of our container** — can be opted out via `kMDItemSupportFileType` exclusion. Not currently indexed; acceptable.
