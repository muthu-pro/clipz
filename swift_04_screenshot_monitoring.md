# swift_04 — Screenshot Monitoring

## Purpose

Detect newly created screenshots / screen recordings in the user-configured screenshot folder, import them into the clipboard history, and optionally delete the source file. This path complements the pasteboard-based capture (swift_03) — many screenshots land as files, not on the clipboard, especially `Cmd+Shift+4` (save-to-file) and full-screen recordings.

## Current Electron behavior

From `electron/clipboard-monitor/clipboard-monitor.mm` (screenshot section) and `electron/main.js`:

- Reads `com.apple.screencapture` user defaults to find the target directory (`defaults read com.apple.screencapture location`), defaulting to `~/Desktop`.
- Uses **FSEvents** (`FSEventStreamCreate` / `FSEventStreamScheduleWithRunLoop`) on that directory.
- Filters by filename patterns:
  - `Screenshot YYYY-MM-DD at HH.MM.SS AM/PM.png`
  - `Screen Recording YYYY-MM-DD at HH.MM.SS AM/PM.mov`
  - Also the simpler "Screen Shot …" legacy pattern.
- Reports events through an NAPI ThreadSafeFunction, same as the pasteboard watcher.
- Settings gate:
  - `screenshotMonitoring: boolean`
  - `screenshotFileTypes: ['png' | 'mov' | 'jpg' | …]` (allowlist)
  - `screenshotAfterImport: 'keep' | 'delete' | 'move'`
- No sandbox restrictions in Electron — the current app runs with a non-sandboxed entitlements set, so FSEvents on `~/Desktop` just works.

## The sandbox problem

Mac App Store apps are **forbidden** from reading `~/Desktop` (or any fixed path outside the container) without explicit user grant. The options:

1. **Ask the user to pick the screenshot folder** via `NSOpenPanel` — grants a security-scoped URL for that exact folder.
2. **Store a security-scoped bookmark** so we can re-open that URL on later launches without re-asking.
3. **Monitor with a sandbox-compatible API** — `NSMetadataQuery` or `DispatchSource.makeFileSystemObjectSource` — both work on security-scoped URLs.

FSEvents (`FSEventStreamCreate`) is *allowed* in sandbox but requires you to call `FSEventStreamCreate` with a path you have access to — once you have a security-scoped URL, FSEvents works. Apple's official recommendation for sandboxed apps is still FSEvents; `NSMetadataQuery` is the higher-level alternative and has better handling for network mounts and Spotlight-indexed locations.

## Swift design

### Settings surface

```swift
public struct ScreenshotMonitorSettings: Sendable {
    public var enabled: Bool                    // default: false
    public var folderBookmark: Data?            // security-scoped bookmark
    public var allowedExtensions: Set<String>   // default: {"png", "jpg", "mov"}
    public var afterImport: AfterImportAction   // default: .keep

    public enum AfterImportAction: String, Codable, Sendable {
        case keep, delete
        // "move to Trash" instead of "delete" — trashing is reversible and
        // sandbox-legal via NSWorkspace.shared.recycle
    }
}
```

### Permission flow

On first enable of screenshot monitoring, the Settings UI shows a "Choose Screenshot Folder…" button.

```swift
@MainActor
func requestScreenshotFolderAccess() async throws -> Data {
    // Determine current system location as a hint
    let hintPath = currentSystemScreenshotLocation() ?? NSString("~/Desktop").expandingTildeInPath

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Grant Access"
    panel.message = "Clipz needs access to your screenshot folder to detect new screenshots."
    panel.directoryURL = URL(fileURLWithPath: hintPath)

    let response = await panel.begin()
    guard response == .OK, let url = panel.url else {
        throw ScreenshotWatcherError.permissionDenied
    }

    return try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

func currentSystemScreenshotLocation() -> String? {
    // Read from `com.apple.screencapture` preferences.
    // CFPreferencesCopyAppValue works in sandbox for reading another app's prefs
    // that expose a public domain — this one is readable.
    guard let value = CFPreferencesCopyAppValue("location" as CFString,
                                                 "com.apple.screencapture" as CFString)
        as? String else { return nil }
    return (value as NSString).expandingTildeInPath
}
```

### Watcher

```swift
// Packages/ClipzCore/Sources/ClipzCore/Screenshots/ScreenshotWatcher.swift

public actor ScreenshotWatcher {
    private let service: ClipboardService
    private let settings: SettingsStore
    private var monitor: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private var scopedURL: URL?      // owns the sandbox extension
    private var seenFilenames = Set<String>()

    public func startIfEnabled() async {
        guard await settings.screenshotMonitoring,
              let bookmark = await settings.screenshotFolderBookmark else { return }
        await start(withBookmark: bookmark)
    }

    public func start(withBookmark bookmark: Data) async {
        stop()

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            // Bookmark is stale; surface a notification asking the user to re-grant.
            await NotificationCenter.default.post(
                name: .screenshotPermissionRevoked, object: nil)
            return
        }
        scopedURL = url

        // Prime seenFilenames with the current directory contents so existing files
        // don't get re-imported as "new".
        if let contents = try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: nil) {
            seenFilenames = Set(contents.map { $0.lastPathComponent })
        }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in Task { await self?.folderChanged() } }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        src.resume()
        monitor = src
    }

    public func stop() {
        monitor?.cancel(); monitor = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        seenFilenames.removeAll()
    }

    private func folderChanged() async {
        guard let url = scopedURL else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        for file in contents {
            let name = file.lastPathComponent
            if seenFilenames.contains(name) { continue }
            seenFilenames.insert(name)
            await handleNewFile(at: file)
        }
        // Also drop names that no longer exist so deletions + re-creations are seen
        seenFilenames.formIntersection(contents.map(\.lastPathComponent))
    }

    private func handleNewFile(at url: URL) async {
        let ext = url.pathExtension.lowercased()
        guard await settings.screenshotAllowedExtensions.contains(ext) else { return }
        guard matchesScreenshotPattern(url.lastPathComponent) else { return }

        // Wait for file to stabilize (screencapture writes atomically but
        // screen recording writes progressively).
        try? await waitForStableSize(url: url)

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
        await service.capture(payload)

        if await settings.screenshotAfterImport == .delete {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func matchesScreenshotPattern(_ name: String) -> Bool {
        // User may have customized `com.apple.screencapture name` prefix.
        let prefix = currentSystemScreenshotNamePrefix() ?? "Screenshot"
        return name.hasPrefix(prefix)
            || name.hasPrefix("Screen Recording")
            || name.hasPrefix("Screen Shot")  // legacy
    }

    private func waitForStableSize(url: URL) async throws {
        var lastSize: Int64 = -1
        for _ in 0..<20 {  // max ~2s
            try await Task.sleep(for: .milliseconds(100))
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? -1
            if size == lastSize && size >= 0 { return }
            lastSize = size
        }
    }
}
```

### Settings UI integration

In the Settings → Screenshots tab:

```
Enable screenshot monitoring  [ toggle ]
Screenshot folder:            /Users/muthu/Desktop  [ Choose… ]
Detect file types:            [x] .png  [x] .jpg  [x] .mov  [ ] .gif
After import:                 ( ) Keep file  (•) Move to Trash
```

"Choose…" triggers `requestScreenshotFolderAccess()`. If the chosen folder isn't the current `com.apple.screencapture` location, show a small disclosure:

> Your screenshots are currently saved to `~/Desktop`. You've chosen `~/Pictures/Screenshots`. Change macOS's save location to match? **[Change]** **[Leave]**

(Changing writes `defaults write com.apple.screencapture location "~/Pictures/Screenshots"` + `killall SystemUIServer` — but **sandbox forbids** `defaults write` on other apps' domains. So this button can't exist inside a MAS app. Instead, show an instruction: "To make macOS save screenshots here, run this in Terminal:" with a copy-to-clipboard button.)

## Edge cases & gotchas

1. **Custom filename prefix** — user may have set `defaults write com.apple.screencapture name "MyScreenshot"`. Read this via `CFPreferencesCopyAppValue` and use as prefix filter.

2. **Date-stamped full-screen recordings** — `.mov` files can be **huge** (100 MB+). Store as file-URL reference via security-scoped bookmark rather than copying bytes into container. For screenshots (PNG, typically < 5 MB), copy bytes — they're small.

3. **Existing files at watcher start** — prime `seenFilenames` with the directory contents at start so old files don't re-import. If the user enables monitoring for the first time *after* a year of screenshots, we don't want to ingest all of them.

4. **Stale bookmark** — if the user moves the screenshot folder, the bookmark becomes stale. Detect via `bookmarkDataIsStale` and prompt re-grant. Surface as a one-time settings notification, not a nagging modal.

5. **Screen Recording progressive writes** — `screencapture -V` / `.mov` recordings grow over time. Wait until size is stable for 200 ms before importing. Without this, we grab a half-written MOV.

6. **Duplicate capture via pasteboard** — after taking a screenshot with `Cmd+Shift+4`, macOS copies the image to clipboard *and* writes a file. Both paths trigger capture. Dedup via `ContentHasher.hash` in `ClipboardService`; the second path (whichever arrives second) drops.

7. **Move to Trash fails** — if the folder is read-only (rare), trash fails silently in our code. Log; don't error loudly.

8. **`.DS_Store` and hidden files** — skip anything starting with `.`.

9. **Volume unmounted** — if the user's screenshot folder is on an external volume and that volume unmounts, the file descriptor becomes invalid; DispatchSource fires an error event. Gracefully stop and show a notification.

10. **Multiple rapid screenshots** — one DispatchSource event may encompass many new files. The current implementation iterates the directory on each event and processes every new name, so burst captures work.

## MAS notes

- **`com.apple.security.files.user-selected.read-write`** — required. Granted when the user picks via `NSOpenPanel`.
- **`com.apple.security.files.bookmarks.app-scope`** — required for persistent bookmarks.
- **`NSDesktopFolderUsageDescription`** — required privacy string in Info.plist if the default folder is Desktop. macOS shows this text in the permission dialog the first time we call `startAccessingSecurityScopedResource`.
- **`CFPreferencesCopyAppValue`** on `com.apple.screencapture` — this works in sandbox because that preference domain is publicly readable. Confirmed on macOS 14.
- **`FileManager.default.trashItem(at:)`** — sandbox-compatible for user-selected folders.
- **App Review friction** — be explicit in the review notes: "The screenshot folder access is used solely to detect new screenshots for clipboard history; no files are read that weren't created after permission was granted." The app has historically been flagged for overbroad file access in App Review; the explicit `NSOpenPanel` + bookmark flow is the sanctioned path.

## Open questions

- **NSMetadataQuery as alternative** — `NSMetadataQuery` with a predicate like `kMDItemContentTypeTree CONTAINS 'public.image' && kMDItemFSContentChangeDate > $now`. Pros: handles indexed folders well, gives us metadata for free (EXIF, creation date). Cons: depends on Spotlight being enabled; misses files if the folder is excluded from Spotlight. Stick with `DispatchSource` for reliability; revisit if users report false negatives.
- **Import older screenshots on first enable?** — default **no**. Add a secondary "Import existing screenshots" button that bulk-processes the directory. Scope creep for v1; defer.
- **Wallpaper screenshots by Apple's Wallpaper suggester** — macOS Sequoia writes `.png` files to `~/Library/Mobile Documents/…` for iCloud sync. Not relevant; the user-selected folder is the only watched location.
