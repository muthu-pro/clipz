# swift_25 — Migration from Electron

## Purpose

On first launch of the Swift Clipz, detect an existing Electron-era install and offer to import everything: clipboard items, media files, notes, tasks, settings. The Electron app stored its data at `~/Library/Application Support/clipz/`; the Swift app (sandboxed) lives at `~/Library/Containers/tech.clipz.app/Data/Library/Application Support/clipz/`. Different locations, different permissions, requiring explicit user grant to cross the boundary.

## Source format (Electron era)

Electron's storage directory:

```
~/Library/Application Support/clipz/
├── clipboard.db                    (better-sqlite3 format = standard SQLite, WAL)
├── clipboard.db-wal
├── clipboard.db-shm
├── <uuid>.png                      (media files, sibling to DB)
├── <uuid>.pdf
├── <uuid>_thumb.png
└── …
```

DB schema matches what swift_05 describes. The Swift app's schema is compatible at v1.

## User-facing flow

On first launch of the Swift Clipz:

1. Silent check: does `~/Library/Application Support/clipz/clipboard.db` exist? — We can't know without permission.
2. Show **Welcome** screen:
   > "**Welcome to Clipz**
   > If you've used the previous version of Clipz, we can import your clipboard history, notes, and tasks.
   > [Import from existing Clipz…] [Start Fresh]"
3. If user clicks Import:
   a. Prompt NSOpenPanel pre-set to `~/Library/Application Support/clipz`.
   b. User picks the folder; macOS grants read access.
   c. Show progress: "Reading database…", "Copying media files (123 of 2451)…", "Restoring notes…".
   d. On completion, dismiss welcome, show main list with imported data.
4. If Start Fresh: skip migration, mark `migrationSkipped = true` in UserDefaults so we don't re-prompt.

## Swift design

### Migration service

```swift
// Packages/ClipzCore/Sources/ClipzCore/Migration/ElectronMigrator.swift
import Foundation
import GRDB

public actor ElectronMigrator {
    private let targetDB: AppDatabase
    private let targetFS: FileStore

    public init(database: AppDatabase, fileStore: FileStore) {
        self.targetDB = database
        self.targetFS = fileStore
    }

    public func runIfNeeded() async {
        let done = UserDefaults.standard.bool(forKey: "tech.clipz.electronMigrationDone")
        let skipped = UserDefaults.standard.bool(forKey: "tech.clipz.electronMigrationSkipped")
        guard !done, !skipped else { return }
        // Trigger welcome screen; actual migration is user-initiated.
        await MainActor.run {
            NotificationCenter.default.post(name: .showWelcomeScreen, object: nil)
        }
    }

    public func importFromFolder(_ url: URL) async throws -> MigrationReport {
        guard url.startAccessingSecurityScopedResource() else {
            throw MigrationError.permissionDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let dbURL = url.appendingPathComponent("clipboard.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw MigrationError.sourceNotFound
        }

        let start = Date()
        var errors: [MigrationReport.MigrationError] = []

        // Open source DB read-only
        var sourceConfig = Configuration()
        sourceConfig.readonly = true
        let sourceQueue = try DatabaseQueue(path: dbURL.path, configuration: sourceConfig)

        // Capture counts for progress reporting
        let (itemCount, noteCount, taskCount) = try await sourceQueue.read { db in
            let i = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items") ?? 0
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
            let t = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? 0
            return (i, n, t)
        }

        // 1. Items + media
        var importedItems = 0
        var copiedMedia = 0
        try await sourceQueue.read { sourceDB in
            let rows = try ClipboardItemRow.fetchAll(sourceDB)
            for row in rows {
                do {
                    try await self.importItem(row: row, sourceFolder: url,
                                              copiedMedia: &copiedMedia)
                    importedItems += 1
                } catch {
                    errors.append(.init(entity: "clipboard_item", id: row.id,
                                        reason: error.localizedDescription))
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .migrationProgress,
                                                     object: MigrationProgress(
                        itemsDone: importedItems, itemsTotal: itemCount,
                        notesDone: 0, tasksDone: 0))
                }
            }
        }

        // 2. Notes
        var importedNotes = 0
        try await sourceQueue.read { sourceDB in
            let noteRows = try NoteRow.fetchAll(sourceDB)
            for row in noteRows {
                do {
                    try await targetDB.write { db in try row.insert(db) }
                    importedNotes += 1
                } catch {
                    errors.append(.init(entity: "note", id: row.id,
                                        reason: error.localizedDescription))
                }
            }
        }

        // 3. Tasks
        var importedTasks = 0
        try await sourceQueue.read { sourceDB in
            let taskRows = try TodoRow.fetchAll(sourceDB)
            for row in taskRows {
                do {
                    try await targetDB.write { db in try row.insert(db) }
                    importedTasks += 1
                } catch {
                    errors.append(.init(entity: "task", id: row.id,
                                        reason: error.localizedDescription))
                }
            }
        }

        // 4. Settings — selective
        try await importSettings(sourceQueue: sourceQueue)

        // 5. Analysis tables — optional, can re-analyze instead
        try await importAnalysis(sourceQueue: sourceQueue, errors: &errors)

        // Mark done so we don't re-prompt
        UserDefaults.standard.set(true, forKey: "tech.clipz.electronMigrationDone")

        return MigrationReport(
            itemsImported: importedItems,
            itemsFailed: errors.filter { $0.entity == "clipboard_item" }.count,
            notesImported: importedNotes,
            tasksImported: importedTasks,
            mediaFilesCopied: copiedMedia,
            errors: errors,
            startedAt: start,
            finishedAt: Date()
        )
    }

    private func importItem(row: ClipboardItemRow, sourceFolder: URL,
                             copiedMedia: inout Int) async throws {
        // Insert DB row
        try await targetDB.write { db in
            try row.insert(db)
        }

        // Copy media file if kind uses filesystem storage
        guard let filename = row.content, !filename.isEmpty,
              ClipboardKind(rawValue: row.type)?.isMedia == true else { return }

        let src = sourceFolder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: src.path) else { return }

        try targetFS.importMedia(from: src, filename: filename)
        copiedMedia += 1

        // Thumbnail (for PDFs)
        if let thumb = row.thumbnailPath {
            let thumbSrc = sourceFolder.appendingPathComponent(thumb)
            if FileManager.default.fileExists(atPath: thumbSrc.path) {
                try? targetFS.importMedia(from: thumbSrc, filename: thumb)
            }
        }
    }

    private func importSettings(sourceQueue: DatabaseQueue) async throws {
        let pairs: [(String, String)] = try await sourceQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
                .map { ($0["key"], $0["value"]) }
        }
        let carryOverKeys: Set<String> = [
            "retentionDays", "monitorClipboard", "monitorClipboardTextOnly",
            "muteCopySound", "hideMediaThumbnail", "screenshotMonitoring",
            "screenshotFileTypes", "screenshotAfterImport", "analysisEnabled",
            "showDockIcon"
        ]
        // Note: "theme" and "themeMode" are intentionally NOT carried over.
        // The Swift app uses system appearance only (swift_15); any Electron-era
        // theme choice is discarded so the user falls through to macOS defaults.
        try await targetDB.write { db in
            for (k, v) in pairs where carryOverKeys.contains(k) {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)
                """, arguments: [k, v])
            }
        }
        // Do NOT carry over: license-related keys, first-run flags, trial dates.
    }

    private func importAnalysis(sourceQueue: DatabaseQueue,
                                 errors: inout [MigrationReport.MigrationError]) async throws {
        // Simpler: mark all items as analysis_done=0 and let AnalysisService
        // re-run inline (swift_09). The Electron-era analysis data is format-compatible
        // and would save work, but verifying consistency across versions is fragile.
        // Opt: carry over without modification — it's the same schema.
        try await sourceQueue.read { sourceDB in
            let detections = try DetectionRow.fetchAll(sourceDB)
            let ocr = try OCRResultRow.fetchAll(sourceDB)
            let docs = try DocumentTextRow.fetchAll(sourceDB)
            try await targetDB.write { db in
                for d in detections { try? d.insert(db) }
                for o in ocr        { try? o.insert(db) }
                for doc in docs     { try? doc.insert(db) }
            }
        }
    }
}

public struct MigrationProgress: Sendable {
    public let itemsDone: Int
    public let itemsTotal: Int
    public let notesDone: Int
    public let tasksDone: Int
}
```

### Welcome view

```swift
// Packages/ClipzUI/Sources/ClipzUI/Migration/WelcomeView.swift
struct WelcomeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle, pickingFolder
        case importing(MigrationProgress)
        case done(MigrationReport)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 72))
                .foregroundStyle(.accent)
            Text("Welcome to Clipz").font(.largeTitle.bold())

            switch phase {
            case .idle:
                Text("If you've used the previous version of Clipz, we can import your clipboard history, notes, and tasks.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Start Fresh") {
                        UserDefaults.standard.set(true, forKey: "tech.clipz.electronMigrationSkipped")
                        dismiss()
                    }
                    Button("Import from Existing Clipz…") {
                        Task { await pickAndImport() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .importing(let p):
                ProgressView(value: Double(p.itemsDone), total: Double(p.itemsTotal)) {
                    Text("Importing clips (\(p.itemsDone) of \(p.itemsTotal))…")
                }
            case .done(let report):
                Label("Import complete", systemImage: "checkmark.seal.fill")
                    .font(.title3).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("Imported:")
                    Text("• \(report.itemsImported) clipboard items")
                    Text("• \(report.notesImported) notes")
                    Text("• \(report.tasksImported) tasks")
                    Text("• \(report.mediaFilesCopied) media files")
                    if !report.errors.isEmpty {
                        Text("\(report.errors.count) items couldn't be imported.")
                            .foregroundStyle(.orange)
                    }
                }
                Button("Start Using Clipz") { dismiss() }
                    .buttonStyle(.borderedProminent)
            case .failed(let msg):
                Label("Import failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(msg).font(.caption)
                Button("Try Again") { phase = .idle }
            case .pickingFolder:
                ProgressView().controlSize(.small)
            }
        }
        .padding(40)
        .frame(width: 480, height: 400)
    }

    private func pickAndImport() async {
        phase = .pickingFolder

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Select your existing Clipz data folder"
        panel.directoryURL = URL(fileURLWithPath:
            NSHomeDirectory() + "/Library/Application Support/clipz")

        guard await panel.begin() == .OK, let url = panel.url else {
            phase = .idle
            return
        }

        // Observe progress
        Task { @MainActor in
            for await note in NotificationCenter.default.notifications(named: .migrationProgress) {
                if let p = note.object as? MigrationProgress {
                    phase = .importing(p)
                }
            }
        }

        do {
            let report = try await container.migrator.importFromFolder(url)
            phase = .done(report)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
```

### Notifications

```swift
extension Notification.Name {
    static let showWelcomeScreen   = Notification.Name("clipz.welcome.show")
    static let migrationProgress   = Notification.Name("clipz.migration.progress")
}
```

Shown in the main window as a sheet triggered on app-first-launch.

## Data transformations during migration

Most rows migrate as-is (schema is compatible at v1). A few transformations:

1. **`appIcon` column** — Electron stored base64-encoded icon data. Swift treats this column as bundle ID (swift_06). During migration, if value looks like base64 (starts with `data:image` or is > 200 chars), drop it (`NULL`); icon will resolve from `appName` best-effort. If bundle ID is genuinely stored, carry over.

2. **Timestamps** — both apps store milliseconds-since-epoch as `Int64`. No conversion.

3. **`driveId`** — carry over but never use. Will be zero for most items.

4. **Content file references** — the `content` column references filenames. Files must be copied (`importMedia`) for this to work after migration.

## Edge cases & gotchas

1. **Very large migrations** (100k+ items) — the current code is sequential; could take minutes. Show progress; allow cancel. If cancelled, leave target DB in partial state; user can retry and we re-insert-or-replace.

2. **Duplicate IDs between source and fresh target** — fresh target has no items (first launch), so no collision. If a user somehow runs migration twice, `INSERT OR REPLACE` handles it gracefully.

3. **Electron app still running** — WAL file is held by the source process; reads may see uncommitted state. Instruct user to quit the old app first. Detect via presence of `-shm` file > 0 bytes + very recent mtime; warn user if it looks active.

4. **Old Electron DB with newer schema** — if the user is running a Clipz beta with a future schema we don't support, fail with `versionTooNew`. Rare.

5. **Bookmark-referenced large videos** — Electron didn't use bookmarks; all media was stored inline. Swift only creates bookmarks for its own captures; migration carries all items as filesystem-backed data.

6. **Missing media files** — DB row references `<uuid>.png` but file doesn't exist on disk (deleted by user outside the app). Row is still imported; file is missing; UI handles gracefully (placeholder).

7. **Sandbox access drop after migration** — the security-scoped URL is only valid during the migration's `startAccessingSecurityScopedResource()` lifetime. After migration completes, we can't read the source folder anymore — which is fine because we've copied what we need.

8. **User picks wrong folder** — the picker pre-selects `~/Library/Application Support/clipz/` but user might navigate elsewhere. If the folder has no `clipboard.db`, throw `MigrationError.sourceNotFound` with helpful message.

9. **Analysis data inconsistency** — Electron's `detections` rows use COCO integer class IDs (0–79 from YOLO). Swift's `object_classes` table autoincrements string-keyed IDs (Apple Vision identifiers like `cat`, `laptop`). On migration, the Electron class_ids are effectively orphaned — the rows are imported but the joined `object_classes` lookup will miss. Mitigations: (a) skip importing Electron `detections` entirely and enqueue images for fresh re-analysis under Apple Vision (recommended default); (b) seed `object_classes` with a "COCO compat" mapping when Electron-era rows are present. Opt-in "Re-analyze imported items" button in the post-migration summary covers both cases.

10. **Welcome screen shown again after Start Fresh** — set the `migrationSkipped` flag to prevent re-prompting. If user wants to migrate later, add a "Import from Clipz (Electron)…" button in Settings → Backup.

## Post-migration cleanup

Offer the user a choice after successful import:

> "Your data has been imported. Would you like to delete the old Clipz data folder to save space?"
> [Delete Old Folder] [Keep It]

Deleting is done via `FileManager.default.trashItem(at: url)` on the same security-scoped URL (still valid while it's open). Sandbox allows trashing a user-selected folder.

Default: keep. Users can manually delete later if they want.

## MAS notes

- `NSOpenPanel` for folder grant — sandbox-compatible (Powerbox mechanism).
- Reading arbitrary files from the granted folder — allowed during the security-scoped access window.
- GRDB on the source `.db` — works read-only inside the sandbox-extended URL.
- No additional entitlement beyond `com.apple.security.files.user-selected.read-write` (already declared).

## Open questions

- **Auto-detect vs explicit opt-in** — we could scan `~/Library/Application Support/` for the `clipz` folder via a sandbox-exempt path (Sandbox actually allows reading `~/Library/Preferences/` but not `Application Support`). No auto-detection; always require user-initiated picker.
- **Cross-platform Electron backups** — users who backed up their Electron app via the old `create-backup` IPC will have `.clipzbackup` archives that the new app can restore via the Backup tab. That's a secondary migration path. Document in release notes.
- **Partial re-migration** — if a user runs "Start Fresh" then later wants to migrate some data, support only a full re-migration (via the Settings import button). Merging partial data is too complex.
- **Delete old Clipz app bundle** — suggest after migration, but don't automate. Let the user drag to Trash themselves.
