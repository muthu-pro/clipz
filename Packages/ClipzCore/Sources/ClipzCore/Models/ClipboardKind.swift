// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The eleven kinds of content Clipz captures. Raw values match the `type`
/// column values in the Electron-era database so that migration (swift_25)
/// can move rows over without translation.
public enum ClipboardKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case image
    case screenshot
    case html
    case video
    case pdf
    case doc
    case docx
    case xls
    case xlsx
    case numbers

    /// Images and videos. Media is stored as files in `FileStore` and
    /// referenced from `clipboard_items.content` by filename.
    public var isMedia: Bool {
        switch self {
        case .image, .screenshot, .video: return true
        case .text, .html, .pdf, .doc, .docx, .xls, .xlsx, .numbers: return false
        }
    }

    /// Documents render document-style previews (page thumbnails, extracted
    /// text). They also live in `FileStore` as files.
    public var isDocument: Bool {
        switch self {
        case .pdf, .doc, .docx, .xls, .xlsx, .numbers: return true
        case .text, .html, .image, .screenshot, .video: return false
        }
    }

    /// True if the content column is a filename reference into `FileStore`
    /// (as opposed to inline UTF-8 text).
    public var isFilesystemBacked: Bool {
        isMedia || isDocument
    }
}
