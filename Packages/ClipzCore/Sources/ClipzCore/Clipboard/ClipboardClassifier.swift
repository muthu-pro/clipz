// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import UniformTypeIdentifiers

/// Inspects an `NSPasteboard` and returns a `ClassifiedPayload` tagged
/// with one of the 11 `ClipboardKind`s. Stateless and cheap — the
/// watcher calls this on every change-count tick where a capture is
/// warranted.
///
/// Ordering matters: file URLs beat inline image data beat HTML beats
/// plain text. This matches macOS conventions (a file on the pasteboard
/// is the canonical form) and the Electron app's behavior.
public struct ClipboardClassifier: Sendable {

    public init() {}

    /// Returns `nil` if the pasteboard carries no content we want to
    /// capture, or carries a concealed / transient type we respect.
    public func classify(_ pb: NSPasteboard) -> ClassifiedPayload? {
        // Community-standard sensitivity signal — password managers, Keychain,
        // and browser password fields tag their writes with these types. This
        // is the *only* thing we treat as a password/key: we never inspect the
        // content of files, images, or large text. For inline text we mark the
        // clip `isSensitive` (the capture policy in ClipboardWatcher decides
        // whether to keep it); for files/images we keep the historical
        // behavior of skipping entirely.
        let concealed = Self.hasAnyType(pb, named: Self.concealedTypeNames)

        let source = SourceAppInspector.frontmostApp()
        let sourceName = source?.name
        let sourceBundle = source?.bundleID

        // 1) File URLs first — a file beats any rasterized preview.
        if let urls = fileURLs(from: pb), let firstURL = urls.first {
            // A concealed file/image is out of scope for the password/key
            // feature; keep skipping it entirely as before.
            if concealed { return nil }
            if let kind = documentKind(for: firstURL) {
                return ClassifiedPayload(
                    kind: kind,
                    data: .fileURL(firstURL),
                    sourceAppName: sourceName,
                    sourceAppBundleID: sourceBundle,
                    originalName: firstURL.lastPathComponent,
                    searchPreview: nil
                )
            }
        }

        // 2) Inline image data (TIFF/PNG) — Cmd+Shift+Ctrl+4 hotkey path
        //    and anything else that drops raster bytes without a URL.
        if let imageData = imageDataFromPasteboard(pb) {
            // Concealed image bytes are out of scope; skip as before.
            if concealed { return nil }
            let kind: ClipboardKind = sourceBundle == "com.apple.screencaptureui"
                ? .screenshot
                : .image
            return ClassifiedPayload(
                kind: kind,
                data: .imageData(imageData, ext: "png"),
                sourceAppName: sourceName,
                sourceAppBundleID: sourceBundle,
                originalName: nil,
                searchPreview: nil
            )
        }

        // 3) HTML — preferred over plain text when the source app
        //    publishes rich text.
        if let html = pb.string(forType: .html), !html.isEmpty {
            let preview = HTMLText.plain(from: html).prefix(500)
            return ClassifiedPayload(
                kind: .html,
                data: .inlineText(html),
                sourceAppName: sourceName,
                sourceAppBundleID: sourceBundle,
                originalName: nil,
                // Never index a secret for search.
                searchPreview: concealed ? nil : String(preview),
                isSensitive: concealed
            )
        }

        // 4) Plain text.
        if let text = pb.string(forType: .string), !text.isEmpty {
            let preview = text.prefix(500)
            return ClassifiedPayload(
                kind: .text,
                data: .inlineText(text),
                sourceAppName: sourceName,
                sourceAppBundleID: sourceBundle,
                originalName: nil,
                // Never index a secret for search.
                searchPreview: concealed ? nil : String(preview),
                isSensitive: concealed
            )
        }

        return nil
    }

    /// Public helper so the drop-import path (swift_07) can run the same
    /// UTI-based classification on a bare file URL.
    public func documentKind(for url: URL) -> ClipboardKind? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "doc": return .doc
        case "docx": return .docx
        case "xls": return .xls
        case "xlsx": return .xlsx
        case "numbers": return .numbers
        // Plain-text documents. Captured as file-backed `.doc` clips so they
        // get a QuickLook thumbnail (and searchable extracted text) like the
        // other document kinds, rather than being dropped on the floor.
        case "txt", "text", "md", "markdown": return .doc
        case "mp4", "mov", "m4v", "webm": return .video
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .image
        default:
            guard let uti = UTType(filenameExtension: ext) else { return nil }
            if uti.conforms(to: .image) { return .image }
            if uti.conforms(to: .movie) { return .video }
            if uti.conforms(to: .pdf) { return .pdf }
            if uti.conforms(to: .spreadsheet) { return .xlsx }
            return nil
        }
    }

    // MARK: - Internal helpers

    private func fileURLs(from pb: NSPasteboard) -> [URL]? {
        let objects = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let objects, !objects.isEmpty else { return nil }
        return objects
    }

    private func imageDataFromPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    // MARK: - Constants

    /// Pasteboard type names that indicate the writer doesn't want
    /// clipboard managers to pick up its content. Community convention.
    private static let concealedTypeNames: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        // Apple's own concealed flag for password pastes from password
        // autofill; undocumented but consistently present since macOS 12.
        "com.apple.AppleSensitiveData",
    ]

    private static func hasAnyType(_ pb: NSPasteboard, named names: Set<String>) -> Bool {
        guard let types = pb.types else { return false }
        for type in types where names.contains(type.rawValue) {
            return true
        }
        return false
    }

}
