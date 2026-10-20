# swift_26 — Feature Parity Checklist

## Purpose

The master parity grid. Every IPC handler in the Electron app → corresponding Swift API. Every preload method → internal service call. Every UI screen/state → Swift view. Every setting → preference. Explicit markers for **dropped**, **deferred**, **changed**.

This file is the **go/no-go checklist** before the Swift app's 1.0 submission.

## Legend

- ✅ **Parity** — functionally equivalent in Swift; no user-visible difference.
- 🟡 **Changed** — same intent, different UX (usually due to sandbox/MAS constraints).
- 🔄 **Deferred** — not in v1, planned for future.
- ❌ **Dropped** — intentionally removed; not returning.

## IPC handlers → Swift APIs

From `electron/preload.js` + `electron/main.js`:

### Clipboard core (20 handlers)

| IPC channel | Status | Swift equivalent | Notes |
|---|---|---|---|
| `save-clipboard` | ✅ | `ClipboardService.capture(payload)` | Payload is a `ClassifiedPayload`. |
| `get-clipboard` | ✅ | `ClipboardService.fetchPage(limit: 1)` | |
| `get-all-clipboard-items` | 🟡 | `ClipboardService.fetchPage(limit: N)` | No "all" — must paginate. |
| `search-clipboard-items` | ✅ | `ClipboardService.search(query:)` | |
| `delete-clipboard-item` | ✅ | `ClipboardService.delete(id:)` | |
| `delete-clipboard-item-queued` | 🟡 | `ClipboardService.delete(id:)` | No queue — actor serialization suffices. |
| `get-clipboard-items` | ✅ | `ClipboardService.fetchPage(...)` | |
| `get-unique-apps` | ✅ | `ClipboardService.fetchUniqueSourceApps()` | |
| `get-clipboard-item` | ✅ | `ClipboardService.fetchItem(id:)` | |
| `read-clipboard` | ✅ | `NSPasteboard.general` | Direct use; no wrapper needed. |
| `read-clipboard-file-paths` | 🟡 | `NSPasteboard.general.readObjects(forClasses:)` | No AppleScript. |
| `read-native-image` | ✅ | `NSPasteboard.general.data(forType: .png)` | |
| `copy-text-to-clipboard` | ✅ | `ClipboardService.writeText(_:)` | |
| `copy-file-to-clipboard` | ✅ | `ClipboardService.writeFile(at:)` | |
| `set-ignore-next-clipboard-change` | ✅ | `ClipboardWatcher.ignoreNextChange()` | |
| `cleanup-old-items` | ✅ | `ClipboardService.deleteExpired(olderThanDays:)` | |
| `count-expired-items` | ✅ | `ClipboardService.countExpired(olderThanDays:)` | |
| `read-file` | ❌ | — | Not needed: direct file I/O via FileManager. |
| `read-file-buffer` | ❌ | — | Same. |
| `delete-file` | ❌ | — | Same; use `fileStore.deleteMedia(filename:)`. |

### Settings (13)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-retention-period` | ✅ | `settings.get(.retentionDays)` |
| `set-retention-period` | ✅ | `settings.set(.retentionDays, value)` |
| `get-theme` | ❌ | — (no in-app theme picker; macOS system appearance only, swift_15) |
| `set-theme` | ❌ | — (same) |
| `set-dock-icon` | ✅ | `NSApp.setActivationPolicy(...)` + `settings.set(.showDockIcon, ...)` |
| `get-monitor-clipboard` | ✅ | `settings.get(.monitorClipboard)` |
| `set-monitor-clipboard` | ✅ | `settings.set(.monitorClipboard, value)` + watcher start/stop |
| `get-monitor-clipboard-text-only` | ✅ | `settings.get(.monitorClipboardTextOnly)` |
| `set-monitor-clipboard-text-only` | ✅ | `settings.set(.monitorClipboardTextOnly, value)` |
| `get-mute-copy-sound` | ✅ | `settings.get(.muteCopySound)` |
| `set-mute-copy-sound` | ✅ | `settings.set(.muteCopySound, value)` |
| `get-hide-media-thumbnail` | ✅ | `settings.get(.hideMediaThumbnail)` |
| `set-hide-media-thumbnail` | ✅ | `settings.set(.hideMediaThumbnail, value)` |

### Screenshots (5)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-screenshot-monitoring` | ✅ | `settings.get(.screenshotMonitoring)` |
| `set-screenshot-monitoring` | 🟡 | Plus ScreenshotWatcher start/stop AND folder permission flow |
| `get-screenshot-file-types` | ✅ | `settings.get(.screenshotFileTypes)` |
| `set-screenshot-file-types` | ✅ | `settings.set(.screenshotFileTypes, value)` |
| `get/set-screenshot-after-import` | 🟡 | Only `keep`/`delete(→Trash)`; no `move` — sandbox issue |

### Notes (7)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-all-notes` | ✅ | `NotesService.fetchAll()` |
| `get-note` | ✅ | `NotesService.fetch(id:)` |
| `create-note` | ✅ | `NotesService.create(...)` |
| `update-note` | ✅ | `NotesService.update(_:)` |
| `delete-note` | ✅ | `NotesService.delete(id:)` |
| `search-notes` | ✅ | `NotesService.search(query:)` |
| `print-notes-benchmark` | ❌ | Debug-only IPC; dropped |

### Tasks (4)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-all-tasks` | ✅ | `TasksService.fetchAll()` |
| `save-task` | ✅ | `TasksService.create(text:)` |
| `update-task` | ✅ | `TasksService.update(_:)` |
| `delete-task` | ✅ | `TasksService.delete(id:)` |

### Analysis (10)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-detections` | ✅ | `AnalysisService.detections(for: itemID)` |
| `get-ocr-results` | ✅ | `AnalysisService.ocrResults(for: itemID)` |
| `get-analysis-counts` | ✅ | `AnalysisService.counts()` |
| `get-document-text` | ✅ | `AnalysisService.documentText(for: itemID)` |
| `search-document-pages` | ✅ | `SearchEngine.searchDocumentPages(query:)` |
| `generate-page-thumbnail` | ✅ | `PDFExtractor.renderThumbnail(...)` |
| `reanalyze-item` | ✅ | `AnalysisService.reanalyze(itemID:)` |
| `get-analysis-enabled` | ✅ | `settings.get(.analysisEnabled)` |
| `set-analysis-enabled` | ✅ | `settings.set(.analysisEnabled, value)` |
| `get-class-synonyms` | ✅ | `SynonymsQueries.synonyms(forClass: id)` |
| `get-class-info` | ✅ | `SynonymsQueries.info(forClass: id)` |
| `get-synonym-classes` | ✅ | `SynonymsQueries.classes(for: synonym)` |

### License / trial (6)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `validate-license-key` | 🟡 | Replaced by `LicenseService.purchase()` + `restorePurchases()` (StoreKit 2 non-consumable) |
| `get-license-info` | ✅ | `LicenseService.state` |
| `remove-license` | ❌ | N/A — App Store handles |
| `get-first-run` | ✅ | `UserDefaults.standard.bool(forKey: "isFirstRun")` |
| `set-first-run` | ✅ | Same |
| `get-trial-status` | 🟡 | Derived from `LicenseService.state` (30-day self-timed trial; Keychain-backed first-launch date; clock-tamper ratchet). See swift_18. |
| `set-trial-start-date` | ❌ | N/A — trial clock is Keychain-managed, not user-settable. `#if DEBUG` menu item can reset it during development. |

### Backup (5)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `create-backup` | ✅ | `BackupService.create(to:password:)` |
| `restore-backup` | ✅ | `BackupService.restore(from:password:)` |
| `validate-backup` | ✅ | `BackupService.getInfo(from:)` |
| `get-backup-info` | ✅ | Same as validate |
| `check-backup-password` | ✅ | `BackupService.checkPassword(for:password:)` |

### Login item (2)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `get-start-at-login` | ✅ | `LoginItemManager.isEnabled()` |
| `set-start-at-login` | ✅ | `LoginItemManager.setEnabled(_:)` |

### Utilities & events (8)

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `handle-item-drop` | ✅ | `ClipboardService.importDroppedFiles(_:)` |
| `copy-to-desktop` | 🟡 | NSSavePanel-based flow (sandbox requires user pick) |
| `get-file-url` | ❌ | SwiftUI consumes URLs directly; not needed |
| `get-app-asset-url` | ❌ | `Bundle.main.url(forResource:...)` |
| `get-storage-usage` | ✅ | `FileStore.usage()` |
| `open-external` | ✅ | `NSWorkspace.shared.open(_:)` |
| `open-file-dialog` | ✅ | `NSOpenPanel` |
| `danger-delete` | ✅ | `ClipboardService.deleteEverything()` + similar for notes/tasks |

### Event channels (preload event listeners)

| Electron event | Status | Swift equivalent |
|---|---|---|
| `clipboard-item-added` | ✅ | `EventBroadcaster.captured(item)` |
| `clipboard-item-deleted` | ✅ | `EventBroadcaster.deleted(id:)` |
| `clipboard-item-updated` | ✅ | `EventBroadcaster.updated(item)` |
| `clipboard-item-icon-updated` | ✅ | Via `AppIconCache.invalidate()` on NSWorkspace notifications |
| `clipboard-file-deleted` | ✅ | Broadcaster + FileStore events |
| `alert` | ✅ | `AlertDialog.present(...)` |
| `new-note` | ✅ | `NotificationCenter.default.post(name: .openNote, ...)` |
| `item-analysis-updated` | ✅ | `EventBroadcaster.analysisUpdated(itemID:)` |
| `analysis-log` | 🔄 | Deferred — debug UI |
| `highlight-item` | ✅ | `WindowRouter.highlightItem(id:)` |

### Misc

| IPC channel | Status | Swift equivalent |
|---|---|---|
| `paste` | 🟡 | `PasteEngine.paste(_:)` with Accessibility TCC flow |
| `open-in-main-app` | ✅ | `WindowRouter.showMainWindow()` + highlight |
| `start-file-drag` | 🟡 | SwiftUI `.onDrag { NSItemProvider ... }` |
| `get-app-version` | ✅ | `Bundle.main.infoDictionary["CFBundleShortVersionString"]` |
| `get-system-info` | ✅ | `ProcessInfo.processInfo` |
| `get-clipboard-dir` | 🟡 | `FileStore.shared.mediaDir` (container-scoped) |

## UI pages & components → Swift views

### Pages (`src/pages/`)

| React page | Status | Swift view |
|---|---|---|
| `ClipboardPage.tsx` (5,535 lines) | ✅ | Decomposed into `Packages/ClipzUI/Sources/ClipzUI/Clipboard/` (10+ files) (swift_12) |
| `NotesListPage.tsx` | ✅ | `NotesSidebarView` (swift_13) |
| `NoteEditorPage.tsx` | ✅ | `NoteEditorView` (swift_13) |
| `TodoPage.tsx` | ✅ | `TasksRootView` (swift_13) |

### Components (`src/components/`)

| React component | Status | Swift view |
|---|---|---|
| `Layout.tsx` | ✅ | `MainTabView` (swift_13) + `SettingsRootView` (swift_14) |
| `NotesLayout.tsx` | ✅ | `NotesRootView` (swift_13) |
| `NoteEditorPlain.tsx` | ✅ | `NoteTextEditor` (NSTextView bridge) (swift_13) |
| `NotesSidebar.tsx` | ✅ | `NotesSidebarView` (swift_13) |
| `TodoItem.tsx` | ✅ | `TodoRow` (swift_13) |
| `TodoList.tsx` | ✅ | Part of `TasksRootView` (swift_13) |
| `AddTodo.tsx` | ✅ | Part of `TasksRootView` (swift_13) |
| `settings/BackupTab.tsx` | ✅ | `BackupSettingsTab` (swift_14) |
| `settings/BackupProgress.tsx` | ✅ | ProgressView inline in `BackupSettingsTab` (swift_14) |
| `settings/BackupInfo.tsx` | ✅ | Inline in restore flow (swift_14, swift_17) |
| `settings/AlertModal.tsx` | ✅ | `AlertDialog` (swift_14) |
| `Modal.tsx` | ✅ | SwiftUI `.sheet` / `.alert` |
| `AlertModal.tsx` | ✅ | `AlertDialog` (swift_14) |
| `ConfirmModal.tsx` | ✅ | `ConfirmDialog` (swift_14) |
| `LicenseModal.tsx` | 🟡 | Replaced by `ProSettingsTab` + StoreKit UI (swift_14, swift_18) |
| `TrialExpiredModal.tsx` | ✅ | `TrialExpiredModal` (swift_18) |
| `SynonymsModal.tsx` | 🔄 | Defer — debug-tier utility |
| `Loading.tsx` | ✅ | SwiftUI `ProgressView()` |
| `LoadingSpinner.tsx` | ✅ | Same |
| `EmptyState.tsx` | ✅ | SwiftUI `ContentUnavailableView` |
| `DocIcon.tsx` | ✅ | `DocumentItemRenderer` (swift_12) |
| `AdobePdfIcon.tsx` | ✅ | `PDFItemRenderer` (swift_12) |

### Contexts (`src/contexts/`)

| React context | Status | Swift equivalent |
|---|---|---|
| `ThemeContext` | ❌ | Dropped — macOS system appearance only (swift_15); no observable theme store |
| `SettingsContext` | ✅ | `SettingsStore` (swift_05, swift_14) |

### Hooks (`src/hooks/`)

| React hook | Status | Swift equivalent |
|---|---|---|
| `useAudio` | ✅ | `SoundPlayer.playCaptureChime()` via `NSSound` (swift_07) |

### Services (`src/services/`)

| React service | Status | Swift equivalent |
|---|---|---|
| `clipboard.ts` (QueryCache) | ❌ | Dropped — in-process SQLite is fast enough (swift_22) |
| `notes.ts` | ✅ | `NotesService` (swift_13) |

### Utilities (`src/utils/`, `src/lib/`)

| Helper | Status | Swift equivalent |
|---|---|---|
| `wcag.ts` | ❌ | Dropped — SwiftUI semantic colors meet AAA under both Light and Dark; no runtime adjuster (swift_15, swift_23) |
| `benchmark.ts` | ✅ | `os_signpost` + `MXMetricPayload` |
| `cache/QueryCache.ts` | ❌ | Dropped |
| `cacheConfig.ts` | ❌ | Dropped |

## Settings parity (every toggle/field)

From Electron Layout.tsx tabs `[cmdc, backup, danger, about]`:

| Setting | Status | Swift location |
|---|---|---|
| Monitor clipboard | ✅ | ClipboardSettingsTab (swift_14) |
| Text-only mode | ✅ | ClipboardSettingsTab |
| Hide media thumbnails | ✅ | ClipboardSettingsTab |
| Retention period | ✅ | ClipboardSettingsTab |
| Screenshot monitoring | 🟡 | ScreenshotsSettingsTab (folder permission required) |
| Screenshot file types | ✅ | ScreenshotsSettingsTab |
| Screenshot after import | 🟡 | Only keep/trash (no move) |
| Theme | ❌ | Dropped — macOS system appearance only (swift_15) |
| Theme mode (auto/light/dark) | ❌ | Dropped — follows System Settings → Appearance |
| Show in Dock | ✅ | GeneralSettingsTab |
| Start at login | ✅ | GeneralSettingsTab (SMAppService) |
| Mute copy sound | ✅ | GeneralSettingsTab |
| Analysis enabled | ✅ | AnalysisSettingsTab (swift_14) |
| Re-analyze all items | ✅ | AnalysisSettingsTab |
| Create backup | ✅ | BackupSettingsTab |
| Create password-protected backup | ✅ | Available post-purchase (no free tier; everyone who has the app has it) |
| Restore backup | ✅ | BackupSettingsTab |
| Backup manifest info | ✅ | Inline display |
| License key entry | ❌ | Replaced by StoreKit IAP |
| Trial status | ✅ | Pro tab (swift_14) |
| Storage usage | ✅ | DangerSettingsTab (swift_14) |
| Erase everything (with captcha) | ✅ | DangerSettingsTab |
| About / version | ✅ | AboutTab (swift_14) |

## Architecture items

| Electron-era | Status | Swift |
|---|---|---|
| Main process (electron/main.js, ~5,700 lines) | ✅ | Split across `ClipzCore` services (~800 lines total) |
| Renderer process (React) | ✅ | SwiftUI + AppKit in-process |
| Preload bridge (93 methods) | ✅ | Direct service calls — no bridge needed |
| Native C++ addon (clipboard-monitor.mm) | ✅ | `ClipboardWatcher` (swift_03) |
| Helper binary `live-text-extractor` | ✅ | Inline via `VNRecognizeTextRequest` (swift_09) |
| Helper binary `obj-detection` (YOLO12x) | ✅ | Replaced by Apple Vision combo: `VNClassifyImageRequest` + `VNRecognizeAnimalsRequest` + `VNDetectHumanRectanglesRequest` (swift_09). License-free, no bundled model. |
| Helper binary `pdf-extractor` | ✅ | Inline via PDFKit (swift_09) |
| Worker thread (dbWorker.js) | ✅ | Swift actors (swift_07) |
| IndexedDB renderer cache | ❌ | Dropped (swift_22) |
| electron-builder + afterPack + notarize | ✅ | Xcode Archive + App Store Connect (swift_21) |
| Main.js.backup (committed) | ❌ | Dropped |
| Certs in git (cert.pem, *.cer) | ❌ | Dropped (swift_19) |
| .env credentials | ✅ | Managed by Xcode / CI secrets |

## Explicitly deferred features (flagged in earlier specs)

- 🔄 **Google Drive sync** — types exist in Electron; no implementation. Deferred to v2.
- 🔄 **Custom keyboard shortcut config** — v1 ships fixed shortcuts; v1.1 adds rebinding.
- 🔄 **Custom theme creation** — v1 ships 2 built-ins; user creation in v2.
- 🔄 **Item pinning / favorites** — v1.1.
- 🔄 **Bulk multi-select actions** — v1.1.
- 🔄 **Markdown export for notes** — v1.1.
- 🔄 **iCloud sync** — v2 (requires CloudKit work).
- 🔄 **Share Extension** — v2 (requires separate extension target).
- 🔄 **Auto-backup schedule** — v1.1.
- 🔄 **Crash report upload UI** — v1.1 (MetricKit scaffolding in v1).
- 🔄 **Localization** — v1.1.
- 🔄 **Spreadsheet text extraction** (.xlsx, .numbers) — v1.1 with CoreXLSX.
- 🔄 **Debug window** — exists behind Cmd+Opt+Shift+D; not documented in UI.
- 🔄 **Retention sync across devices** — depends on iCloud sync; v2.

## Explicitly dropped features

- ❌ **Windows / Linux support** — macOS only.
- ❌ **iOS / iPadOS / Catalyst** — macOS only (per user decision).
- ❌ **Hash-based licensing** — StoreKit replaces.
- ❌ **DMG distribution** — App Store only.
- ❌ **Theme picker / custom themes / WCAG runtime adjuster** — macOS system appearance only. `Theme`, `ThemeStore`, `ColorResolver`, `ContrastEnforcer`, `AppearanceSettingsTab` are not ported (swift_15).
- ❌ **Free tier after trial** — 30-day trial then mandatory one-time purchase. No reduced-feature continuation (swift_18).
- ❌ **Trial length from Electron (14 days)** — extended to 30 days in the Swift rewrite.
- ❌ **Debug monitor window in release builds** — debug-only.
- ❌ **IndexedDB caching layer** — unnecessary in-process.
- ❌ **Base64 app-icon storage in DB** — resolve from bundle ID instead.
- ❌ **AppleScript file-path extraction** — NSPasteboard native.
- ❌ **Webpack + Vite dual build** — Xcode only.
- ❌ **Python TUI build tool (build.py)** — Xcode archives.
- ❌ **ASAR integrity manipulation** — no ASAR.
- ❌ **Driver-mode Google Drive code** (legacy `driveId` column) — retained in schema for compat only.

## Pre-submission checklist (cross-cutting)

Before the very first App Store submission, walk this list:

- [ ] swift_00 overview: stack pinned, Xcode project built end-to-end
- [ ] swift_01 structure: three SPM packages compile
- [ ] swift_02 lifecycle: tray launches, close-hides-window works
- [ ] swift_03 capture: text + image + screenshot + files captured
- [ ] swift_04 screenshot: folder pick → bookmark → monitoring works
- [ ] swift_05 schema: v1 migration applies cleanly
- [ ] swift_06 models: row ↔ domain conversion round-trips
- [ ] swift_07 service: capture, search, delete, retention cleanup all pass
- [ ] swift_08 search: trigram + porter + synonym expansion + OCR bboxes present
- [ ] swift_09 ML: OCR + object detection + PDF extraction produce rows
- [ ] swift_10 paste: TCC grant flow works; fallback toast when denied
- [ ] swift_11 windows: main + tray popover + settings + debug all open
- [ ] swift_12 clipboard view: infinite scroll, search, context menu, OCR overlay all work
- [ ] swift_13 notes/tasks: create/edit/delete both; NSTextView bridge stable
- [ ] swift_14 settings: every tab saves to DB and reflects on restart; AppearanceSettingsTab is absent (system appearance only)
- [ ] swift_15 system appearance: UI renders correctly under Light, Dark, and "Increase contrast"; tray icon template image tints correctly
- [ ] swift_16 files: container storage, bookmarks, orphan sweep work
- [ ] swift_17 backup: create + restore with & without password
- [ ] swift_18 pro: StoreKit test purchase + restore works; 30-day trial ratchets correctly (clock tamper defended); PaywallWindow cannot be bypassed; LockedTabPlaceholder shown on non-Pro/About settings tabs when expired
- [ ] swift_19 entitlements: match the declared set; no unused
- [ ] swift_20 MAS: every constraint acknowledged; no banned APIs
- [ ] swift_21 packaging: Xcode archive uploads to App Store Connect
- [ ] swift_22 performance: p95 targets met on M1 baseline
- [ ] swift_23 a11y: VoiceOver walks + keyboard-only works
- [ ] swift_24 tests: 90% core coverage + 5 UI flows green on CI
- [ ] swift_25 migration: Electron app data imports cleanly

All boxes ticked = ship.

## Critical blockers before 1.0

- **App Review acceptance** — first submission reveals unknown unknowns. **Full compliance with `swift_20` App Review hard rules HR-1 through HR-10 is mandatory**, not aspirational. The HR-10 go/no-go gate must be verified against the exact archive before every submission; any unchecked box aborts the submission. Budget 4 weeks of buffer before any announced launch date, assuming 2–3 rejection cycles.
- **Cert rotation** — pre-public-repo cleanup of committed `cert.pem` and related files.

## Post-1.0 roadmap (v1.1, v2)

### v1.1 (3–6 months after 1.0)

- Localization (de, fr, ja, zh-Hans)
- Item pinning / favorites
- Bulk multi-select actions
- Markdown export for notes
- Spreadsheet text extraction
- Auto-backup schedule
- Keyboard shortcut rebinding
- Custom themes (via Asset Catalog extension)

### v2.0 (12+ months)

- iCloud sync
- Share Extension
- Google Drive integration (if demanded)
- iOS / iPadOS companion app (separate target)
- Teams / shared clipboard (huge scope)

## Open questions

- **App naming** — "Clipz" or rebrand? Check for trademark conflicts in App Store before submission.
- **Pricing** — $14.99 one-time vs subscription; revisit after TestFlight signals.
- **Open-sourcing** — the Electron app has been public; the Swift rewrite could be proprietary or open-source. Affects cert/secret handling. No pre-commitment.
- **Migration tool availability** — ship with the app in v1, or as a separate one-time tool? Ship with app (simpler for user).
