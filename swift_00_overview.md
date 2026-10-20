# swift_00 — Overview

## Purpose

This file is the entry point for the Clipz Swift rewrite spec series. It fixes the stack, the module layout, the constraints, and the order in which subsequent files should be read and the rewrite should be implemented. Every later file (swift_01 … swift_26) assumes the decisions here.

## Product scope

Clipz is a macOS clipboard manager with notes and tasks bolted on. The current app (Electron + React + native C++ addon + three helper binaries) ships on GitHub release DMGs; the Swift rewrite will ship through the **Mac App Store only**. Feature surface to preserve:

- Tray-first capture of every clipboard change (text, image, screenshot, html, video, pdf, doc, docx, xls, xlsx, numbers — 11 kinds)
- Screenshot folder monitoring with optional auto-import/auto-delete
- Full-text search over clipboard + OCR + object detections + document text, with in-image OCR match highlighting
- On-device ML: OCR, whole-image classification, animal/human detection with bboxes, barcode detection — all via Apple Vision. PDF text extraction via PDFKit. Synonym-driven search expansion.
- Notes (rich text + FTS) and a simple todo list
- Backup/restore with password-protected zip
- System-appearance-aware UI (follows macOS Light/Dark; no in-app theme picker)
- Tray popup for quick drag-and-paste
- Retention-based auto-cleanup
- 30-day free trial, then mandatory one-time purchase via StoreKit 2 non-consumable IAP (hard lockout on expiry — no free tier)

Features dropped by intent: Windows/Linux support, iOS/iPadOS, Google Drive sync (gapi types exist in Electron but no implementation), debug window (deferred — may be cut).

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Swift 5.10 / 6.0** | Full concurrency checking, `@Observable` macro |
| Min OS | **macOS 14.0 Sonoma** | Unlocks Observation framework, modern SwiftUI |
| UI primary | **SwiftUI** | List, NavigationSplitView, Settings scene |
| UI bridges | **AppKit** | NSStatusItem, NSPopover, NSTextView (rich notes), NSFilePromiseProvider (drag-to-Finder), vibrancy materials, NSSavePanel |
| Persistence | **GRDB.swift 6.x** | SQLite wrapper with strong Swift ergonomics, FTS5, migrations, WAL out of the box |
| ML / Vision | **Apple Vision + PDFKit** | Replaces the three helper binaries (`live-text-extractor`, `obj-detection`, `pdf-extractor`) — App Sandbox forbids shipping standalone helpers that run outside the main process container. All-Apple APIs: `VNRecognizeTextRequest` (OCR), `VNClassifyImageRequest` (scene/object tags), `VNRecognizeAnimalsRequest` + `VNDetectHumanRectanglesRequest` (bboxed detections), `VNDetectBarcodesRequest`, `PDFKit`. No bundled ML model. |
| Crypto | **CryptoKit** | AES-GCM for backup encryption, SHA-256 for content hashing |
| Compression | **Apple Compression framework + AppleArchive** | Zip and gzip for backup bundles |
| IAP / license | **StoreKit 2** | `Transaction.currentEntitlements`, non-consumable "Clipz Pro" |
| Concurrency | **async/await + actors** | Replaces Node worker thread + ipcRenderer invoke calls |
| State | **@Observable + @State + @AppStorage** | Replaces React Context |
| Testing | **Swift Testing + XCUITest + swift-snapshot-testing** | |
| Packaging | **Xcode archive → App Store Connect** | No DMG, no notarize.cjs, no afterPack ASAR tricks |

## Module map

Split the codebase into Swift Packages so the app target is thin and each concern is independently testable:

```
ClipzApp/                    # App target (main bundle)
  App.swift                  # @main, AppDelegate bridge
  Info.plist
  Clipz.entitlements
  Assets.xcassets

Packages/
  ClipzCore/                 # Pure-Swift, no UI
    Sources/ClipzCore/
      Models/                # ClipboardItem, Note, Task, Settings, …
      Database/              # GRDB setup, migrations, queries
      Services/              # ClipboardService, NotesService, TasksService
      Clipboard/             # NSPasteboard capture (actor)
      Screenshots/           # FSEvents / NSMetadataQuery watcher
      Search/                # FTS query building, highlight snippeting
      FileStore/             # Container-scoped media storage
      Backup/                # Backup/restore
      Licensing/             # StoreKit 2 wrapper
      Migration/             # Electron DB → Swift DB importer
      Concurrency/           # Task queues, debouncers
      Utils/                 # Hashing, logging, errors
    Tests/

  ClipzML/                   # Vision/CoreML pipeline
    Sources/ClipzML/
      OCRAnalyzer.swift
      ImageClassifier.swift  # VNClassifyImageRequest (whole-image tags)
      AnimalDetector.swift   # VNRecognizeAnimalsRequest (cats/dogs with bbox)
      HumanDetector.swift    # VNDetectHumanRectanglesRequest
      BarcodeDetector.swift
      PDFExtractor.swift
      DocumentExtractor.swift
      AnalysisCoordinator.swift
    Resources/
      image_tag_synonyms.json
    Tests/

  ClipzUI/                   # SwiftUI views + AppKit bridges
    Sources/ClipzUI/
      Clipboard/             # ClipboardView and its breakdown
      Notes/                 # NotesView, NoteEditorBridge (NSTextView)
      Tasks/                 # TasksView
      Settings/              # Settings scene + tabs
      Tray/                  # NSStatusItem + NSPopover
      Theming/               # Theme definitions, ColorPalette
      Components/            # Shared: Loading, EmptyState, DocIcon…
      Accessibility/         # WCAG contrast utilities
    Resources/
      Assets.xcassets        # theme color sets, app/tray icons
    Tests/
```

Why 3 packages: `ClipzCore` stays UI-free so it's testable with `swift test` from the command line; `ClipzML` quarantines the heavy Vision/CoreML dependencies so unit tests for the core don't pull them; `ClipzUI` is where everything wires together. The app target is essentially a thin shell: AppDelegate, Scene, and top-level composition root.

## Top-level composition

```swift
// ClipzApp/App.swift
@main
struct ClipzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var container = AppContainer.shared   // resolves services

    var body: some Scene {
        WindowGroup(id: "main") {
            ClipboardView(container: container)
                .environment(container.theme)
                .environment(container.settings)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsRoot(container: container)
        }
    }
}
```

`AppContainer` is a simple DI root (not a full DI framework) that owns the database, services, and theme. It's passed down via `Environment` or initializer. This matches modern SwiftUI idiom without reaching for a heavy library.

## Mac App Store constraints — cheat sheet

> ⚠️ **App Review is a hard gate with no workaround.** Read **swift_20 → "App Review hard rules"** before any implementation decision that touches permissions, IAP, privacy, or external SDKs. Rules HR-1 through HR-10 there are strictly enforced: any submission attempt that skips the HR-10 go/no-go gate must be aborted.


| Current Electron approach | Broken by sandbox | Swift replacement |
|---|---|---|
| Helper binaries shelled out to (`live-text-extractor`, `obj-detection`, `pdf-extractor`) | Yes — sandboxed app can't run arbitrary siblings with their own capabilities | Inline via Vision + Core ML + PDFKit (`ClipzML` package) |
| FSEvents on `~/Desktop` for screenshots | Yes — sandbox blocks arbitrary file-system access | Ask user via NSOpenPanel once → store **security-scoped bookmark** → `NSMetadataQuery` or `DispatchSourceFileSystemObject` on the bookmark-resolved URL |
| robotjs Cmd+V synthesis | Needs **Accessibility TCC grant** at runtime (still works in sandbox, just needs explicit user grant) | `CGEventPost` after `AXIsProcessTrustedWithOptions` check; fallback "press Cmd+V" toast when denied |
| AppleScript for clipboard file paths | Not needed in Swift — NSPasteboard exposes `.fileURL` reads natively | Drop AppleScript entirely |
| Copy-to-desktop (`copy-to-desktop` IPC) | Sandbox forbids writing to `~/Desktop` silently | NSSavePanel lets the user pick; the chosen URL is implicitly granted |
| `sha256(email+seed)` license | Redundant on MAS | StoreKit 2 non-consumable IAP "tech.clipz.pro" |
| `afterPack.cjs` strips ASAR integrity, notarize.cjs, sign-app.js | Not applicable | Xcode Archive → Organizer → App Store Connect |
| Certs + `cert.pem` in git | Becomes moot once Xcode automatic signing takes over | Rotate credentials, scrub repo; App Store signing is handled by Apple |
| ~91 IPC handlers | No IPC — everything is in-process | Replace with direct service calls (async functions / actor methods) |
| ClipboardPage.tsx monolith (~5,500 lines) | React-specific | Decompose into SwiftUI views + view models (~10 files) |

## Reading and implementation order

Follow the files in number order; they are ordered such that later files can reference earlier ones without forward-references. During implementation, the recommended build order is:

1. **Foundations (swift_00–02)** — overview, project skeleton, app lifecycle
2. **Persistence (swift_05, 06)** — database + models; nothing works without this
3. **Services (swift_07, 08)** — clipboard service + search
4. **Capture (swift_03, 04)** — clipboard and screenshot producers feeding the service
5. **File storage (swift_16)** — used by capture for media files
6. **ML (swift_09)** — analysis pipeline, consumes items from the service
7. **Paste / drag (swift_10)** and **window management (swift_11)** — UI substrate
8. **Accessibility (swift_23)** — referenced by every view. No theme picker (swift_15 is the minimal "system appearance + tray template image" stub).
9. **Views (swift_12–14)** — clipboard, notes/tasks, settings
10. **Backup (swift_17)** and **licensing (swift_18)** — settings-adjacent features
11. **Permissions + MAS + packaging (swift_19–21)** — ship
12. **Performance (swift_22)** — measure and tune
13. **Testing (swift_24)** — throughout, not at the end
14. **Migration (swift_25)** — ship the importer with the 1.0 release
15. **Parity check (swift_26)** — before GA

## File format

Every `swift_NN_*.md` in this series has the same skeleton:

1. **Purpose** — 1–2 sentences
2. **Current Electron behavior** — what the app does today, with `file_path:line` references
3. **Swift design** — the replacement, with types, APIs, flow diagrams
4. **Edge cases & gotchas** — every weird behavior from the Electron version that must be preserved
5. **MAS notes** — sandbox implications specifically for that feature
6. **Open questions** — decisions I haven't locked down; flagged for the user

## Versioning policy

- `CFBundleShortVersionString`: user-visible, semver-ish (start at **1.0**)
- `CFBundleVersion`: monotonically increasing integer, auto-bumped by CI
- Drop the three-source version drift in the current app (package.json vs WARP.md vs main.js line 12). Single source of truth: Xcode target settings, read at runtime via `Bundle.main.infoDictionary`.

## Repository layout note

The Swift rewrite is a **new repository** (not a branch off `clipz.tech`). The current Electron repo should be tagged `electron-final` and archived; the Swift repo starts fresh to avoid dragging a thousand abandoned scripts, cert files, and Electron build artifacts into a Mac App Store submission. The Electron repo remains the reference for behavior; the Swift repo's git history stays clean.

## Open questions

- **Retention sync** — current app has retention, but it's device-local. Should retention settings sync via iCloud key-value store if the user is signed in? Defer to swift_14 and swift_20.
- **ML coverage** — Apple's `VNClassifyImageRequest` + animal/human detectors give us license-free, sandbox-safe on-device classification without bundling a model. Trade-off vs the original YOLO12x plan: richer tag taxonomy, fewer per-object bounding boxes (bboxes only for OCR text, animals, humans, and barcodes). Revisit adding a permissive custom model later if coverage gaps surface.
- **App Review acceptance of 30-day hard-lockout trial** — self-timed trial + required non-consumable IAP has shipped on MAS, but Guideline 3.1.1/3.1.2 interpretation can shift. Contingency if rejected: swap to an auto-renewable subscription with a 30-day intro offer. Decision locked: one-time purchase model until Apple forces otherwise.
