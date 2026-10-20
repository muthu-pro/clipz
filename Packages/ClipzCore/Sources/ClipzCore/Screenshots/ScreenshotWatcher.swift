// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Dispatch

/// Watches a user-granted folder for new screenshot / screen-recording
/// files and imports them into the clipboard history via the same
/// `ClipboardService.capture` path used by the pasteboard watcher. Both
/// paths dedup through `ContentHasher`, so the `Cmd+Shift+4` case (which
/// drops bytes on the pasteboard AND writes a file) collapses to one
/// clipboard row.
///
/// Uses `DispatchSource.makeFileSystemObjectSource` on a sandbox-scoped
/// URL — matches Apple's documented pattern for sandboxed apps, doesn't
/// require the more heavyweight `NSMetadataQuery`.
public actor ScreenshotWatcher {
    private let service: ClipboardService
    private let settings: SettingsStore

    private var monitor: (any DispatchSourceFileSystemObject)?
    private var fd: CInt = -1
    /// The URL we're watching. Used by `folderChanged` to list directory
    /// contents. Populated in both the production (bookmark) and test
    /// (direct URL) paths.
    private var watchedDir: URL?
    /// Only set when the URL was resolved from a security-scoped
    /// bookmark — used to release the extension on `stop`.
    private var scopedURL: URL?
    private var seenFilenames: Set<String> = []

    public init(service: ClipboardService, settings: SettingsStore) {
        self.service = service
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Start monitoring iff both:
    /// - the user enabled screenshot monitoring, AND
    /// - we have a valid security-scoped bookmark on file.
    public func startIfEnabled() async throws {
        guard await settings.get(SettingsKeys.screenshotMonitoring) else { return }
        guard let bookmark = await settings.get(SettingsKeys.screenshotFolderBookmark) else {
            return
        }
        try start(withBookmark: bookmark)
    }

    /// Start monitoring a folder resolved from `bookmark`. Throws if the
    /// bookmark is stale or the folder descriptor can't be opened.
    public func start(withBookmark bookmark: Data) throws {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw ScreenshotWatcherError.bookmarkStale
        }
        if isStale {
            throw ScreenshotWatcherError.bookmarkStale
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ScreenshotWatcherError.bookmarkStale
        }
        try startWatching(url: url, securityScoped: true)
    }

    /// Test seam: watch a folder directly, skipping both the security-
    /// scoped bookmark resolution AND the DispatchSource wiring. Tests
    /// drive `folderChanged()` themselves so the race between the
    /// dispatch-driven call and the manual one doesn't show up.
    internal func start(watchingURL url: URL) throws {
        stop()
        watchedDir = url
        scopedURL = nil
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) {
            seenFilenames = Set(contents.map { $0.lastPathComponent })
        }
    }

    private func startWatching(url: URL, securityScoped: Bool) throws {
        stop()

        watchedDir = url
        scopedURL = securityScoped ? url : nil

        // Prime `seenFilenames` so existing files don't get re-imported
        // as "new" when monitoring turns on for the first time against
        // a year-old screenshot folder.
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) {
            seenFilenames = Set(contents.map { $0.lastPathComponent })
        }

        let opened = open(url.path, O_EVTONLY)
        guard opened >= 0 else {
            let err = errno
            stop()
            throw ScreenshotWatcherError.openFailed(path: url.path, errno: err)
        }
        fd = opened

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: [.write, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        // Event handler runs on a Dispatch queue. Bridge to the actor
        // via an AsyncStream so the Swift 6 checker can see that the
        // sending Task captures only `Sendable` values (the continuation
        // + `self` as an actor reference).
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        source.setEventHandler {
            continuation.yield(())
        }
        source.setCancelHandler { [fd = opened] in
            continuation.finish()
            if fd >= 0 { close(fd) }
        }
        source.resume()
        monitor = source

        Task { [weak self] in
            for await _ in stream {
                await self?.folderChanged()
            }
        }
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
        fd = -1
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        watchedDir = nil
        seenFilenames.removeAll()
    }

    // MARK: - Internal

    /// Directly drive the watcher from tests. Call this after writing a
    /// file into the watched directory to run the new-file detector.
    internal func folderChanged() async {
        guard let url = watchedDir else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") { continue }
            if seenFilenames.contains(name) { continue }
            seenFilenames.insert(name)
            await handleNewFile(at: fileURL)
        }

        // Clean up deleted-then-recreated filenames so a subsequent
        // re-create is treated as new.
        seenFilenames.formIntersection(contents.map(\.lastPathComponent))
    }

    private func handleNewFile(at url: URL) async {
        let ext = url.pathExtension.lowercased()
        let allowed = await settings.get(SettingsKeys.screenshotFileTypes)
        guard allowed.contains(ext) else { return }
        guard matchesScreenshotPattern(url.lastPathComponent) else { return }

        // Wait for screen recordings to finish writing (they grow for a
        // few hundred ms after appearing on disk).
        await waitForStableSize(url: url)

        let kind: ClipboardKind = (ext == "mov" || ext == "mp4") ? .video : .screenshot

        let data: ClassifiedPayload.PayloadData
        if kind == .screenshot {
            guard let bytes = try? Data(contentsOf: url) else { return }
            data = .imageData(bytes, ext: ext)
        } else {
            data = .fileURL(url)
        }

        let payload = ClassifiedPayload(
            kind: kind,
            data: data,
            sourceAppName: "Screenshot",
            sourceAppBundleID: "com.apple.screencaptureui",
            sourceAppIconPNGData: nil,
            originalName: url.lastPathComponent,
            searchPreview: nil
        )
        _ = await service.capture(payload)

        // After-import: either keep the file, or move it to Trash.
        // `FileManager.trashItem` is sandbox-legal for user-granted
        // directories and reversible (vs. an outright delete).
        if await settings.get(SettingsKeys.screenshotAfterImport) == .delete {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func matchesScreenshotPattern(_ name: String) -> Bool {
        let prefix = ScreenshotPreferences.systemScreenshotNamePrefix()
        return name.hasPrefix(prefix)
            || name.hasPrefix("Screen Recording")
            || name.hasPrefix("Screen Shot")  // legacy macOS filenames
    }

    private func waitForStableSize(url: URL) async {
        var lastSize: Int64 = -1
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let size = fileSize(at: url) ?? -1
            if size >= 0 && size == lastSize { return }
            lastSize = size
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }
}
