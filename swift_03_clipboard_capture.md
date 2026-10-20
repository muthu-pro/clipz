# swift_03 — Clipboard Capture

## Purpose

Capture every change to the system pasteboard, classify it into one of the 11 supported item kinds, dedupe, persist, and notify the UI. This is the single most important subsystem — it's what the product *is*.

## Current Electron behavior

Implemented across:

- `electron/clipboard-monitor/clipboard-monitor.mm` — the native Objective-C++ addon.
  - Polls `[NSPasteboard generalPasteboard].changeCount` on a timer (event-like via a timer because Cocoa doesn't give a proper NSPasteboard change notification).
  - On change, fires a NAPI `ThreadSafeFunction` callback into JS.
- `electron/clipboard-monitor.js` — JS wrapper that exposes `startMonitoring(cb)` / `stopMonitoring()`. Falls back to polling-in-JS if the addon isn't built.
- `electron/clipboard-file-paths.js` — AppleScript bridge that reads file URLs from the pasteboard when the native addon reports file signatures. Has a 2s timeout. Falls back to regex-parsing a `text/uri-list` buffer.
- `electron/main.js` (the bulk of capture logic):
  - `performPaste()` (`:25–156`) — the outgoing side; strips HTML → plain text via a chain of regex passes, then triggers Cmd+V via robotjs.
  - Tracked globals at `:200–234`: `lastClipboardSig` (string equality dedup), `clipboardTextOnly` (setting), `ignoreNextClipboardChange` (guard for self-triggered changes), `captureQueue`, `captureQueueRunning`, `lastSavedContent`.
  - Capture handler reads each declared pasteboard type, converts media to a file in Application Support (`~/Library/Application Support/clipz/`), then inserts into the DB and broadcasts `'clipboard-item-added'` via IPC.

11 item kinds (from `src/types/clipboard.ts`):

```typescript
type ClipboardType = 'text' | 'image' | 'screenshot' | 'html' | 'video'
                   | 'pdf' | 'doc' | 'docx' | 'xls' | 'xlsx' | 'numbers';
```

Each item record carries:

```typescript
{ id, type, content /* inline text OR filename path */, searchPreview, createdAt,
  driveId?, originalName?, appName?, appIcon?, thumbnailPath?, pageCount?, wordCount?, metadata? }
```

Dedup today is string equality on `lastClipboardSig` — collisions possible and partial content is signed, not a hash.

## Swift design

### High-level flow

```
 NSPasteboard.changeCount changes
         │
         ▼
 ClipboardWatcher.poll() [actor]      ← respects ignore-next flag
         │
         ▼
 ClipboardClassifier.classify(pb)      ← returns ClassifiedPayload (enum)
         │
         ▼
 ContentHasher.hash(payload)           ← SHA-256 over canonicalized bytes
         │
         ├── if hash == lastCapturedHash  → drop (dedup)
         │
         ▼
 ClipboardService.capture(payload, hash)
         │
         ├── writes media to FileStore (if applicable)
         ├── writes row to DB (clipboard_items)
         ├── enqueues analysis (if enabled; see swift_09)
         │
         ▼
 NotificationCenter: `clipboardItemCaptured(item)`
         │
         ▼
 SwiftUI views observe, list updates via @Observable
```

### Types

```swift
// Packages/ClipzCore/Sources/ClipzCore/Clipboard/ClipboardKind.swift

public enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text, image, screenshot, html, video
    case pdf, doc, docx, xls, xlsx, numbers

    public var isMedia: Bool {
        switch self {
        case .image, .screenshot, .video, .pdf, .doc, .docx, .xls, .xlsx, .numbers: return true
        case .text, .html: return false
        }
    }

    public var isDocument: Bool {
        switch self { case .pdf, .doc, .docx, .xls, .xlsx, .numbers: return true; default: return false }
    }
}
```

Kept as a flat string enum (not associated-values) so it maps cleanly to the existing `type` column in the DB — preserving the ability to load old backups made by the Electron app (see swift_25).

### Payload struct

Separate in-memory value for an unsaved, classified capture:

```swift
public struct ClassifiedPayload: Sendable {
    public let kind: ClipboardKind
    public let data: PayloadData
    public let sourceAppName: String?
    public let sourceAppBundleID: String?
    public let sourceAppIconPNGData: Data?   // 32×32 @2x, for list display
    public let originalName: String?         // filename if clipboard had a file
    public let searchPreview: String?        // first 500 chars for indexable text

    public enum PayloadData: Sendable {
        case inlineText(String)              // kinds: text, html
        case imageData(Data, ext: String)    // kinds: image, screenshot
        case fileURL(URL)                    // kinds: pdf/doc/docx/xls/xlsx/numbers/video
    }
}
```

### Watcher

```swift
// Packages/ClipzCore/Sources/ClipzCore/Clipboard/ClipboardWatcher.swift
import AppKit

public actor ClipboardWatcher {
    private let service: ClipboardService
    private let settings: SettingsStore
    private let classifier = ClipboardClassifier()
    private var lastChangeCount: Int = 0
    private var ignoreNextEpoch: Date?   // set by ignore-next; valid for 1s
    private var pollTask: Task<Void, Never>?
    private var pausedForSleep = false

    init(service: ClipboardService, settings: SettingsStore) {
        self.service = service
        self.settings = settings
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func startIfEnabled() async {
        guard await settings.monitorClipboard, pollTask == nil else { return }
        pollTask = Task.detached(priority: .utility) { [weak self] in
            await self?.pollLoop()
        }
        await installSleepHandlers()
    }

    public func stop() async {
        pollTask?.cancel(); pollTask = nil
    }

    public func ignoreNextChange() {
        ignoreNextEpoch = Date()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            await tick()
        }
    }

    private func tick() async {
        guard !pausedForSleep else { return }
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let ignored = ignoreNextEpoch, Date().timeIntervalSince(ignored) < 1 {
            ignoreNextEpoch = nil
            return
        }

        guard let payload = await classifier.classify(pb) else { return }

        // Text-only mode
        if await settings.monitorClipboardTextOnly, payload.kind.isMedia { return }

        await service.capture(payload)
    }

    private func installSleepHandlers() async {
        NotificationCenter.default.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setPaused(true) }
        }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setPaused(false) }
        }
    }

    private func setPaused(_ paused: Bool) {
        self.pausedForSleep = paused
        if !paused { self.lastChangeCount = NSPasteboard.general.changeCount }
    }
}
```

**Polling cadence**: 250 ms. This matches a typical clipboard manager's perceived-instant latency while keeping CPU negligible. The current Electron native addon polls on a CFRunLoopTimer at 500 ms; tightening to 250 ms is free under Swift async and feels snappier.

Alternative considered: listen for `NSPasteboardDidChangeNotification`. That notification doesn't exist (Cocoa has never shipped one). Polling changeCount is the official pattern.

### Classifier

This is where the 11-kind detection lives, driving off UTType and raw pasteboard type names:

```swift
// Packages/ClipzCore/Sources/ClipzCore/Clipboard/ClipboardClassifier.swift
import AppKit
import UniformTypeIdentifiers

public struct ClipboardClassifier {
    public func classify(_ pb: NSPasteboard) async -> ClassifiedPayload? {
        // Prefer file URLs first — a file on the clipboard beats a rasterized preview.
        if let urls = fileURLs(from: pb), let firstURL = urls.first {
            if let kind = documentKind(for: firstURL) {
                return ClassifiedPayload(
                    kind: kind,
                    data: .fileURL(firstURL),
                    sourceAppName: frontmostAppName(),
                    sourceAppBundleID: frontmostAppBundleID(),
                    sourceAppIconPNGData: frontmostAppIconPNG(),
                    originalName: firstURL.lastPathComponent,
                    searchPreview: nil
                )
            }
        }

        // PDF inline (some apps paste PDF data directly without a file URL)
        if let pdfData = pb.data(forType: .pdf) {
            let tmp = try? FileStore.shared.writeTemp(data: pdfData, ext: "pdf")
            if let tmp {
                return makePayload(kind: .pdf, data: .fileURL(tmp), originalName: "Clipped.pdf")
            }
        }

        // Image: TIFF / PNG / JPEG all come through NSImage-compatible types
        if pb.canReadObject(forClasses: [NSImage.self], options: nil),
           let imageData = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(pngDataFromTIFF) {
            return makePayload(kind: screenshotKindIfFromScreencapture() ? .screenshot : .image,
                               data: .imageData(imageData, ext: "png"),
                               searchPreview: nil)
        }

        // HTML (preferred over plain text when present)
        if let html = pb.string(forType: .html) {
            let preview = stripHTMLToPlain(html).prefix(500)
            return makePayload(kind: .html, data: .inlineText(html),
                               searchPreview: String(preview))
        }

        // Plain text (last resort)
        if let text = pb.string(forType: .string) {
            let preview = text.prefix(500)
            return makePayload(kind: .text, data: .inlineText(text),
                               searchPreview: String(preview))
        }

        return nil
    }

    // MARK: - Helpers

    private func fileURLs(from pb: NSPasteboard) -> [URL]? {
        guard let objects = pb.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return nil }
        return objects.isEmpty ? nil : objects
    }

    private func documentKind(for url: URL) -> ClipboardKind? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "doc": return .doc
        case "docx": return .docx
        case "xls": return .xls
        case "xlsx": return .xlsx
        case "numbers": return .numbers
        case "mp4", "mov", "m4v", "webm": return .video
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .image
        default:
            // Fall back to UTType hierarchy
            if let uti = UTType(filenameExtension: ext) {
                if uti.conforms(to: .image) { return .image }
                if uti.conforms(to: .movie) { return .video }
                if uti.conforms(to: .pdf) { return .pdf }
                if uti.conforms(to: .spreadsheet) { return .xlsx }
            }
            return nil
        }
    }

    // Heuristic: if the frontmost app is `screencapture` or the image arrived from
    // the Screenshot hotkey path (NSPasteboardType "public.tiff" only, no file URL),
    // classify as .screenshot. The screenshot watcher (swift_04) is a separate,
    // authoritative path — this heuristic is a best-effort secondary signal.
    private func screenshotKindIfFromScreencapture() -> Bool {
        frontmostAppBundleID() == "com.apple.screencaptureui"
    }
}
```

### Dedup & hashing

```swift
// Packages/ClipzCore/Sources/ClipzCore/Clipboard/ContentHasher.swift
import CryptoKit

public enum ContentHasher {
    public static func hash(_ payload: ClassifiedPayload) -> String {
        var hasher = SHA256()
        hasher.update(data: payload.kind.rawValue.data(using: .utf8)!)
        switch payload.data {
        case .inlineText(let s):
            hasher.update(data: s.data(using: .utf8) ?? Data())
        case .imageData(let d, _):
            hasher.update(data: d)
        case .fileURL(let url):
            // Hash filename + size + mtime rather than entire file bytes to avoid
            // blocking on large videos. Re-hashing on content change would require
            // reading the full file — deliberate tradeoff.
            hasher.update(data: url.lastPathComponent.data(using: .utf8) ?? Data())
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let size = attrs[.size] as? Int {
                    hasher.update(data: withUnsafeBytes(of: size, Data.init))
                }
                if let mtime = attrs[.modificationDate] as? Date {
                    hasher.update(data: withUnsafeBytes(of: mtime.timeIntervalSinceReferenceDate, Data.init))
                }
            }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

### Service integration

Dedup happens **in the service**, not the watcher, so that other capture sources (screenshot watcher, drag-import) go through the same dedup:

```swift
public actor ClipboardService {
    private var lastCapturedHash: String?

    public func capture(_ payload: ClassifiedPayload) async {
        let hash = ContentHasher.hash(payload)
        if hash == lastCapturedHash { return }

        // Also dedup against the DB (last item of same kind in last 5s)
        if await database.hasRecentItem(contentHash: hash, withinSeconds: 5) { return }
        lastCapturedHash = hash

        let id = UUID().uuidString
        let stored = try? await persist(payload: payload, id: id, contentHash: hash)
        guard let stored else { return }
        await broadcast(.captured(stored))
        await analysisService?.enqueue(itemID: id, kind: payload.kind)
    }

    private func persist(payload: ClassifiedPayload, id: String, contentHash: String) async throws -> ClipboardItem {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var stored: ClipboardItem

        switch payload.data {
        case .inlineText(let s):
            stored = ClipboardItem(
                id: id, kind: payload.kind, content: s,
                searchPreview: payload.searchPreview ?? String(s.prefix(500)),
                createdAt: now, contentHash: contentHash,
                originalName: nil, appName: payload.sourceAppName,
                appIcon: payload.sourceAppBundleID,
                thumbnailPath: nil, pageCount: nil, wordCount: nil,
                metadata: nil
            )
        case .imageData(let data, let ext):
            let filename = "\(id).\(ext)"
            try fileStore.writeMedia(data: data, filename: filename)
            stored = ClipboardItem(id: id, kind: payload.kind, content: filename, …)
        case .fileURL(let url):
            let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
            let filename = "\(id).\(ext)"
            try fileStore.importMedia(from: url, filename: filename)
            stored = ClipboardItem(id: id, kind: payload.kind, content: filename,
                                    originalName: url.lastPathComponent, …)
        }

        try await database.insert(stored)
        return stored
    }
}
```

### Ignore-next-change protocol

The outgoing paste flow and the "copy text to clipboard" IPC in the current app both write to the pasteboard themselves — they don't want that write to be re-captured. Today's Electron code sets a `setIgnoreNextClipboardChange` flag before writing. Swift version:

```swift
// Called before programmatically setting the pasteboard
await clipboardWatcher.ignoreNextChange()
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(someText, forType: .string)
```

The watcher's `ignoreNextEpoch` expires after 1 second as a safety net — if something prevents the expected NSPasteboard write from happening, we don't silently swallow a genuine later clipboard change.

### Outgoing paste helpers

Replacements for the `copy-text-to-clipboard` / `copy-file-to-clipboard` IPC handlers:

```swift
extension ClipboardService {
    public func writeText(_ s: String) async {
        await watcher.ignoreNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    public func writeFile(at url: URL) async {
        await watcher.ignoreNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    public func writeImage(_ data: Data) async {
        await watcher.ignoreNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}
```

### HTML → plain text stripping

The current `performPaste()` chains multiple regex passes to strip HTML before a paste (when the user has a HTML item selected but they're pasting into a plain-text field). Swift version uses `NSAttributedString`:

```swift
func stripHTMLToPlain(_ html: String) -> String {
    guard let data = html.data(using: .utf8),
          let attr = try? NSAttributedString(
              data: data,
              options: [.documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue],
              documentAttributes: nil) else {
        return html
    }
    return attr.string
}
```

Advantages over regex: handles entities (`&amp;`, `&nbsp;`), nested tags, malformed HTML — the current Electron code is brittle here.

## Edge cases & gotchas

1. **Launch-time first change** — on app launch, `changeCount` is already whatever the last clipboard state is. Initialize `lastChangeCount` from `NSPasteboard.general.changeCount` at construction time so the first tick doesn't re-capture whatever's already there. The 2-second post-launch dedup window (swift_02) is a second line of defense.

2. **Multi-format pasteboards** — if the clipboard contains both PNG and HTML (common for image drags), we classify as image (file/image beats HTML beats text). The classifier's order enforces this.

3. **Password managers** — 1Password / Bitwarden write to the pasteboard with `org.nspasteboard.ConcealedType`. Respect this by dropping captures where `NSPasteboard.general.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true`. This is a community convention; not enforced by Apple but universally respected by clipboard managers.

4. **Transient pasteboards** — `org.nspasteboard.TransientType` or `org.nspasteboard.AutoGeneratedType`. Drop these too. The current Electron app doesn't respect this convention; fixing it in the rewrite is a user-visible improvement.

5. **Large videos** — `.mov` files can be gigabytes. Don't copy them into Application Support by default; keep a reference to the source URL with a security-scoped bookmark. If the source file is deleted, the item becomes a broken reference. Alternative: ask the user on first large file capture whether to inline-store or reference. Open question.

6. **Screenshot from system UI vs from clipboard watcher** — the screenshot *hotkey* path (`Cmd+Shift+Ctrl+4`) goes directly to the pasteboard; the *save-to-file* path (`Cmd+Shift+4`) goes to the FS. The screenshot watcher (swift_04) handles the FS path; the clipboard watcher handles the in-memory path. Both must dedup against each other via content-hash, hence the shared hash in the service.

7. **Clipboard retention during handoff** — if the user Handoff-copies from iPhone, it arrives as a transient universal-clipboard read on the Mac side. These trigger NSPasteboard change events; capture as usual. Respect `org.nspasteboard.TransientType` if set.

8. **Empty strings** — NSPasteboard can briefly hold an empty string during a change. Drop captures where the payload would be a zero-length string or zero-byte file.

9. **Text with trailing whitespace** — **do not trim.** Users copy code intentionally with trailing whitespace; trimming breaks paste fidelity. The current app preserves this; keep the behavior.

10. **Rich text from Pages/Word** — may come in as RTF without HTML. Treat `.rtf` as `kind = .html` for storage simplicity, with content stored as RTF string. Render via `NSAttributedString(rtf:)` in the view.

11. **Bundle IDs for app attribution** — `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at the moment of capture. The frontmost app at watcher-tick time is the correct "source app" because the paste happens from that app. Race: if the user Cmd-Tabs between pb-write and our tick (≤250 ms), we get the wrong app. Acceptable.

12. **App icons** — `NSWorkspace.shared.icon(forFile: appPath)` returns an NSImage; PNG-encode at 32×32 @2x for storage. Cache by bundle ID in memory.

## MAS notes

- `NSPasteboard.general` is sandbox-compatible; no entitlement.
- Reading pasted file URLs (`readObjects(forClasses: [NSURL.self])`) is sandbox-compatible — the file URLs are granted an implicit sandbox extension for read/write when the user dragged or copied them in another app.
- **Persisting those URLs across launches** requires `com.apple.security.files.bookmarks.app-scope`. For the capture pipeline we don't persist URLs — we copy the file bytes into our container. Only when we store a **reference** (option considered for large videos) do bookmarks come into play.
- The `AXIsProcessTrustedWithOptions` call for paste automation lives in swift_10; capture itself needs no Accessibility grant.
- Outgoing writes to the pasteboard are fully sandboxed-allowed.

## Open questions

- **Poll cadence** — 250 ms vs 500 ms. Start at 250, measure CPU in idle state, drop to 500 if meaningful. Swift `Task.sleep` at 250 ms consumes essentially zero CPU, so this is probably a non-issue.
- **Large video handling** — inline-store vs bookmark-reference. Default behavior: inline if < 100 MB, bookmark otherwise; prompt the user. Flagged in swift_07.
- **Respect transient/concealed conventions** — yes for v1 (it's one-liner dropout; big UX win for password manager users).
- **Capture source bundle ID storage** — currently the Electron DB stores a readable `appName` and a base64 icon blob. Keep the name; store the bundle ID instead of the full icon blob and resolve the icon on render using `NSWorkspace.shared.icon(forFile:)` to avoid blowing up the DB. Also allows icons to update if the user upgrades the source app.
