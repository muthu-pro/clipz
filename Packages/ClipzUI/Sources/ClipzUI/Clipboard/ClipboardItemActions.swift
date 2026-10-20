// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import UniformTypeIdentifiers
import ClipzCore

/// Pure-function-style helpers for the card action buttons. `copy`
/// writes the item into the general pasteboard (the same shape
/// `PasteboardWriter` uses); `save` presents an NSSavePanel and
/// copies the file out.
@MainActor
enum ClipboardItemActions {

    static func copy(
        _ item: ClipboardItem,
        fileStore: FileStore,
        watcher: ClipboardWatcher
    ) async {
        await PasteboardWriter.write(item, fileStore: fileStore, watcher: watcher)
    }

    /// Pick a destination with NSSavePanel, then copy the clip's
    /// underlying file (or write its text) to the chosen URL.
    /// No-ops on cancel. Uses `begin(completionHandler:)` so it
    /// behaves correctly from SwiftUI button actions — the runloop
    /// keeps pumping, unlike `runModal()` which has been flaky when
    /// fired from hover-revealed controls inside hiddenTitleBar
    /// windows.
    static func save(_ item: ClipboardItem, fileStore: FileStore) {
        // When a SwiftUI button is clicked the app is already key, but
        // belt-and-braces: some hover states can leave the key window
        // flagged as inactive. `activate(ignoringOtherApps:)` is a
        // no-op if we're already frontmost.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: item)
        panel.message = "Save this clip to your Mac."
        if let types = allowedContentTypes(for: item) {
            panel.allowedContentTypes = types
            panel.allowsOtherFileTypes = true
        }

        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            Task { @MainActor in
                performCopy(item: item, fileStore: fileStore, to: dest)
            }
        }
    }

    // MARK: - Copy implementation

    private static func performCopy(
        item: ClipboardItem,
        fileStore: FileStore,
        to dest: URL
    ) {
        do {
            switch item.kind {
            case .image, .screenshot,
                 .video, .pdf,
                 .doc, .docx, .xls, .xlsx, .numbers:
                let src = fileStore.mediaURL(filename: item.content)
                guard FileManager.default.fileExists(atPath: src.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)

            case .text, .html:
                try item.content.write(to: dest, atomically: true, encoding: .utf8)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save the file."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Helpers

    /// The Save dialog's initial filename. When the clip was captured
    /// from a real file on disk (screenshot folder watcher, drag-in,
    /// Electron migration), `originalName` is already the source
    /// filename — use that verbatim so the user gets "Screenshot 2026-
    /// 04-24 at 09.42.13.png" instead of a UUID. For pasteboard-only
    /// captures (no source file) we generate a human timestamp name.
    private static func suggestedFilename(for item: ClipboardItem) -> String {
        if let name = item.originalName, !name.isEmpty { return name }
        let stamp = timestamp(for: item.createdAt)
        switch item.kind {
        case .text:         return "Clip \(stamp).txt"
        case .html:         return "Clip \(stamp).html"
        case .image:        return "Image \(stamp).png"
        case .screenshot:   return "Screenshot \(stamp).png"
        case .video:        return "Video \(stamp).mov"
        case .pdf:          return "Document \(stamp).pdf"
        case .doc:          return "Document \(stamp).doc"
        case .docx:         return "Document \(stamp).docx"
        case .xls:          return "Spreadsheet \(stamp).xls"
        case .xlsx:         return "Spreadsheet \(stamp).xlsx"
        case .numbers:      return "Spreadsheet \(stamp).numbers"
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        // Same shape macOS uses for screenshot filenames, so users see
        // something familiar.
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private static func timestamp(for date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// UTTypes to advertise on the save panel. Only set for kinds where
    /// a *specific* UTType exists — passing `.data` as the filter makes
    /// the panel treat every filename as a .data extension and rewrites
    /// the user's input, so we return `nil` for those and let the panel
    /// accept whatever the filename says.
    private static func allowedContentTypes(for item: ClipboardItem) -> [UTType]? {
        switch item.kind {
        case .text:         return [.plainText]
        case .html:         return [.html, .plainText]
        case .image:        return [.png, .jpeg, .image]
        case .screenshot:   return [.png, .image]
        case .video:        return [.movie, .quickTimeMovie, .mpeg4Movie]
        case .pdf:          return [.pdf]
        case .doc, .docx,
             .xls, .xlsx,
             .numbers:
            return nil
        }
    }
}
