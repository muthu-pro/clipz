# swift_06 — Data Models

## Purpose

Swift domain types for every entity in the app: clipboard items, notes, tasks, settings, and the analysis entities (detections, OCR, object classes, synonyms, document text). This file defines the API that the rest of the app consumes; the `storage row ↔ domain model` conversion happens here.

## Design principles

- **Value types** (`struct`) for everything — we never mutate a record in place across the app.
- **Sendable** — every type is `Sendable` so it can cross actor boundaries cleanly.
- **Identifiable + Hashable + Equatable** — required by SwiftUI `List` / `ForEach`.
- **Separation of row types and domain types** — GRDB `FetchableRecord` conformance lives on storage-row types (`ClipboardItemRow`) in `Sources/ClipzCore/Database/`; the domain types here are plain Swift with no GRDB import. Conversions live in a small `DomainMapper` module.

## `ClipboardItem`

```swift
// Packages/ClipzCore/Sources/ClipzCore/Models/ClipboardItem.swift
import Foundation

public struct ClipboardItem: Identifiable, Hashable, Sendable {
    public let id: String                          // UUID string
    public let kind: ClipboardKind                 // 11 cases (swift_03)
    public let content: String                     // inline text OR filename
    public let searchPreview: String?              // first 500 chars for FTS
    public let createdAt: Date
    public let originalName: String?               // source filename for imported files
    public let sourceApp: SourceApp?               // attribution
    public let mediaInfo: MediaInfo?               // thumbnail, pageCount, wordCount
    public let metadata: ItemMetadata?             // decoded from metadata JSON
    public let contentHash: String?
    public let analysisStatus: AnalysisStatus

    public struct SourceApp: Hashable, Sendable, Codable {
        public let name: String
        public let bundleID: String?               // resolved to icon at render time
    }

    public struct MediaInfo: Hashable, Sendable {
        public let thumbnailFilename: String?      // "<id>_thumb.png" if generated
        public let pageCount: Int?                 // PDF / DOC pages
        public let wordCount: Int?                 // deprecated; kept for compat
    }

    public struct ItemMetadata: Hashable, Sendable, Codable {
        public var title: String?
        public var author: String?
        public var creator: String?
        public var subject: String?
        public var keywords: [String]?
        public var mimeType: String?
    }

    public struct AnalysisStatus: Hashable, Sendable {
        public var textDone: Bool                  // OCR/doc-text finished
        public var objectDone: Bool                // object detection finished
        public var updatedAt: Date?
    }

    public var isMedia: Bool { kind.isMedia }
    public var isDocument: Bool { kind.isDocument }
}
```

### Row ↔ domain mapping

```swift
extension ClipboardItem {
    init(row: ClipboardItemRow) {
        self.id = row.id
        self.kind = ClipboardKind(rawValue: row.type) ?? .text
        self.content = row.content ?? ""
        self.searchPreview = row.searchPreview
        self.createdAt = Date(timeIntervalSince1970: Double(row.createdAt) / 1000)
        self.originalName = row.originalName
        self.sourceApp = row.appName.map {
            .init(name: $0, bundleID: row.appIcon)
        }
        self.mediaInfo = .init(
            thumbnailFilename: row.thumbnailPath,
            pageCount: row.pageCount,
            wordCount: row.wordCount
        )
        self.metadata = row.metadata.flatMap {
            try? JSONDecoder().decode(ItemMetadata.self, from: Data($0.utf8))
        }
        self.contentHash = row.contentHash
        self.analysisStatus = .init(
            textDone: row.analysis_text_done == 1,
            objectDone: row.analysis_object_done == 1,
            updatedAt: row.analysis_updatedAt.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }
        )
    }

    func toRow() -> ClipboardItemRow {
        ClipboardItemRow(
            id: id,
            type: kind.rawValue,
            content: content,
            createdAt: Int64(createdAt.timeIntervalSince1970 * 1000),
            originalName: originalName,
            appName: sourceApp?.name,
            appIcon: sourceApp?.bundleID,
            searchPreview: searchPreview,
            driveId: nil,
            thumbnailPath: mediaInfo?.thumbnailFilename,
            pageCount: mediaInfo?.pageCount,
            wordCount: mediaInfo?.wordCount,
            metadata: metadata.flatMap {
                String(data: try! JSONEncoder().encode($0), encoding: .utf8)
            },
            contentHash: contentHash,
            analysis_text_done: analysisStatus.textDone ? 1 : 0,
            analysis_object_done: analysisStatus.objectDone ? 1 : 0,
            analysis_updatedAt: analysisStatus.updatedAt.map {
                Int64($0.timeIntervalSince1970 * 1000)
            }
        )
    }
}
```

## `Note`

```swift
public struct Note: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var title: String?
    public var contentJSON: NoteContent        // rich representation
    public var contentText: String             // searchable plain text (FTS)
    public let createdAt: Date
    public var updatedAt: Date
}

/// Structured rich note content, persisted as JSON in `notes.content_json`.
/// Matches the current Electron app's block-based format so migration doesn't lose data.
public enum NoteContent: Codable, Hashable, Sendable {
    case document(blocks: [Block])

    public enum Block: Codable, Hashable, Sendable {
        case heading(level: Int, inline: [Inline])
        case paragraph(inline: [Inline])
        case list(ordered: Bool, items: [[Inline]])
        case codeBlock(language: String?, text: String)
        case quote(inline: [Inline])
    }

    public struct Inline: Codable, Hashable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        public var link: URL?
    }
}
```

The editor (swift_13) uses `NSAttributedString` as its working format; conversion to/from `NoteContent` happens on save/load. Two representations exist because:

- `NoteContent` is stable, portable JSON (good for backups + migration).
- `NSAttributedString` is AppKit-native (good for `NSTextView`).

Both `contentText` (plain) and `contentJSON` (rich) are stored; `contentText` feeds FTS, `contentJSON` feeds the editor. Derived-at-save; the DB is the source of truth.

## `Task`

```swift
public struct Task: Identifiable, Hashable, Sendable {
    public let id: String
    public var text: String
    public var completed: Bool
    public let createdAt: Date

    public init(id: String = UUID().uuidString, text: String, completed: Bool = false,
                createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.completed = completed
        self.createdAt = createdAt
    }
}
```

Note: name collision with `Swift.Task` (async). Inside `ClipzCore`, always refer to this as `TodoItem` or import with a disambiguating alias. Recommend renaming the type:

```swift
public struct TodoItem: Identifiable, Hashable, Sendable { … }
```

The DB table remains `tasks` (for migration compatibility); the Swift type is `TodoItem`.

## Analysis types

```swift
// Object detection
public struct Detection: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let itemID: String
    public let classID: Int
    public let confidence: Double
    public let bbox: BoundingBox?
}

public struct BoundingBox: Hashable, Sendable, Codable {
    public let x: Double      // [0,1] normalized
    public let y: Double
    public let width: Double
    public let height: Double
}

// OCR result (text OR barcode)
public struct OCRResult: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let itemID: String
    public let kind: Kind
    public let text: String?
    public let barcodeSymbology: BarcodeSymbology?
    public let barcodePayload: String?
    public let confidence: Double?
    public let bbox: BoundingBox?

    public enum Kind: String, Codable, Sendable { case text, barcode }

    public enum BarcodeSymbology: String, Codable, Sendable {
        case qr, ean8, ean13, upc, code39, code128, pdf417, dataMatrix, aztec, other
    }
}

public struct ObjectClass: Identifiable, Hashable, Sendable {
    public let id: Int          // class_id (e.g., 15 for "cat" in COCO)
    public let name: String     // class_name
}

public struct ObjectSynonym: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let classID: Int
    public let synonym: String
}

public struct DocumentText: Hashable, Sendable {
    public let itemID: String
    public let fullText: String
    public let pages: [String]   // decoded from JSON array
}
```

## `Theme`

```swift
public struct Theme: Identifiable, Hashable, Sendable {
    public let id: String              // "light-plus", "gruvbox-dark"
    public let displayName: String
    public let appearance: Appearance  // .light | .dark | .auto
    public let palette: Palette

    public enum Appearance: String, Codable, Sendable { case light, dark, auto }

    public struct Palette: Hashable, Sendable {
        // 21 colors matching src/themes.ts exactly
        public let background: String        // hex
        public let backgroundSecondary: String
        public let text: String
        public let textSecondary: String
        public let border: String
        public let accent: String
        public let hover: String
        public let overlay: String
        public let warning: String
        public let danger: String
        public let success: String
        public let disabled: String
        public let active: String
        public let completed: String
        public let skeleton: String
        public let contextMenuBg: String
        public let contextMenuBorder: String
        public let contextMenuHover: String
        public let contextMenuText: String
        public let primaryButtonBg: String
        public let primaryButtonHover: String
        public let primaryButtonText: String
    }
}
```

At runtime the hex strings are converted to `NSColor` / `SwiftUI.Color` via a cached resolver in `ClipzUI.Theming`. Theme records themselves live in code (not DB) — `Theme.allBuiltIns` returns the set.

## `SettingsRecord`

Not really a domain type — `SettingsStore` exposes typed getters. But for the Settings view to render a complete state, a snapshot struct is useful:

```swift
public struct SettingsSnapshot: Sendable {
    public var retentionDays: Int
    public var monitorClipboard: Bool
    public var monitorClipboardTextOnly: Bool
    public var muteCopySound: Bool
    public var hideMediaThumbnail: Bool
    public var screenshotMonitoring: Bool
    public var screenshotFileTypes: Set<String>
    public var screenshotAfterImport: ScreenshotAfterImportAction
    public var analysisEnabled: Bool
    public var theme: String                    // theme id
    public var themeMode: ThemeMode              // auto | light | dark
    public var showDockIcon: Bool
    public var startAtLogin: Bool                // derived from SMAppService, not DB
}

public enum ThemeMode: String, Codable, Sendable {
    case auto, light, dark
}

public enum ScreenshotAfterImportAction: String, Codable, Sendable {
    case keep, delete
}
```

## `LicenseState`

```swift
public enum LicenseState: Equatable, Sendable {
    case trialing(daysRemaining: Int)
    case expired(trialEndedAt: Date)
    case licensed(productID: String, purchasedAt: Date)
    case unknown
}
```

Replaces the current `validateLicenseKey` / `getLicenseInfo` / `getTrialStatus` tuple. Details in swift_18.

## `BackupManifest`

```swift
public struct BackupManifest: Codable, Sendable {
    public let version: Int                   // starts at 1
    public let format: String                 // "clipz-backup"
    public let createdAt: Date
    public let dbSchemaVersion: Int
    public let appVersion: String
    public let itemCount: Int
    public let noteCount: Int
    public let taskCount: Int
    public let mediaFileCount: Int
    public let totalBytes: Int64
    public let encryption: EncryptionInfo?

    public struct EncryptionInfo: Codable, Sendable {
        public let algorithm: String          // "AES-GCM"
        public let kdfAlgorithm: String       // "scrypt"
        public let kdfParams: KDFParams
        public let salt: Data
        public let nonce: Data
    }

    public struct KDFParams: Codable, Sendable {
        public let n: Int                     // scrypt N (2^14 recommended)
        public let r: Int                     // scrypt r (8)
        public let p: Int                     // scrypt p (1)
    }
}
```

Implementation details in swift_17. Compatibility note: the Electron app's current manifest format and field names are preserved so backups produced by the Electron app can be restored by the Swift app.

## `MigrationReport`

```swift
public struct MigrationReport: Sendable {
    public let itemsImported: Int
    public let itemsFailed: Int
    public let notesImported: Int
    public let tasksImported: Int
    public let mediaFilesCopied: Int
    public let errors: [MigrationError]
    public let startedAt: Date
    public let finishedAt: Date

    public struct MigrationError: Sendable {
        public let entity: String
        public let id: String
        public let reason: String
    }
}
```

## Equatable / Hashable implementation

All types use synthesized `Equatable` / `Hashable` on their stored properties. For identity-only equality on `ClipboardItem` (used in SwiftUI diffing), a custom implementation is *not* needed — the auto-synthesis compares all fields, which is correct since any field change should trigger a re-render.

Exception: for very large text items, comparing `content` on every diff pass is wasteful. SwiftUI `List` uses `id` for identity (via `Identifiable`) and re-renders when any property changes — but for the rendered row, the stable identity prevents row churn. We don't need to override equality.

## Codable conformance

Every Codable type above uses the default snake-or-pascal-case keys — matching the current Electron JSON where it's serialized to disk (backup manifest, note content JSON, item metadata). Document the exact JSON shape in swift_17 (backup) and swift_25 (migration).

## Error types

```swift
public enum ClipboardError: Error, Sendable {
    case itemNotFound(id: String)
    case fileOperationFailed(underlying: Error)
    case invalidPayload(reason: String)
    case databaseError(underlying: Error)
}

public enum AnalysisError: Error, Sendable {
    case modelLoadFailed(reason: String)
    case imageDecodeFailed
    case unsupportedFormat(extension: String)
    case cancelled
}

public enum BackupError: Error, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case corruptBackup
    case invalidFormat
    case versionTooNew(fileVersion: Int, supportedVersion: Int)
    case migrationFailed(reason: String)
    case invalidPassword
    case passwordRequired
    case fileNotFound
    case interrupted
}
```

Error codes match the current Electron `backup-manager.js` error enum so that user-facing error messages remain stable.

## Edge cases & gotchas

1. **Timestamps** — stored as `Int64` milliseconds-since-epoch in DB; surfaced as `Date` in domain types. Conversion is centralized in the mapper; one place to change if we ever switch to seconds.

2. **Optional content** — `ClipboardItem.content` is declared non-optional `String` but the DB column is nullable. We default to empty string in the mapper. Items in the DB with `NULL` content are rare edge cases (broken captures); the UI handles empty content gracefully.

3. **Orphaned media files** — if a file in `FileStore` has no matching DB row, it's an orphan. The service has a periodic sweep (swift_16); the domain type doesn't need to model orphans.

4. **Metadata JSON shape evolution** — `ItemMetadata` uses optional fields for everything and adds new ones via non-breaking additions. Decoding is lenient: unknown fields are ignored by `JSONDecoder` by default.

5. **Note rename collision** — `Note` is fine; no conflict with Foundation or SwiftUI. `Task` vs `Swift.Task` — rename the DB-backed one to `TodoItem`.

6. **Enum raw values == DB strings** — for enums that persist to DB (`ClipboardKind`, `ScreenshotAfterImportAction`, `ThemeMode`), the `rawValue` must match the Electron DB's exact values. Any rename is a breaking change that needs a migration.

7. **`sourceApp.bundleID` vs `appIcon` column name** — historical; the Electron schema named the column `appIcon` because it stored a base64 blob. We keep the column name (no schema change needed) but store a bundle ID string in it. Document this mismatch in a code comment on `ClipboardItemRow`.

8. **`driveId` field** — preserved in row type for migration compat; never set on new items; not exposed in domain type. Drop in v2.

## Open questions

- **`Note.title` optional vs empty string?** — current Electron has nullable title. Keep `String?` — `nil` means "no title at all" (use content excerpt), `""` means "user explicitly cleared title".
- **Source app icon caching** — use an `actor AppIconCache` keyed by bundle ID, storing `NSImage` references. Render layer calls `AppIconCache.shared.icon(for: bundleID)`. Separate from domain types. Defined in swift_16.
- **Tag model** — future addition; not in v1.
