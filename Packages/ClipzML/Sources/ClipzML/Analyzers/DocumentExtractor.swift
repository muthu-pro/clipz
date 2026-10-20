// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit

/// Plain-text extraction from RTF and Word documents via AppKit's
/// `NSAttributedString` readers. Spreadsheets (.xlsx / .numbers) are
/// deferred to v1.1 — they need CoreXLSX or similar and have lower
/// signal-to-effort than screenshot OCR.
public struct DocumentExtractor: Sendable {
    public init() {}

    public func extract(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "rtf":
            return extract(url: url, options: [
                .documentType: NSAttributedString.DocumentType.rtf
            ])
        case "doc", "docx":
            // Word reader handles both legacy .doc and OOXML .docx.
            // macOS's WebKit-based reader must run on the main thread,
            // so callers should dispatch to MainActor before calling us.
            return extract(url: url, options: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML
            ])
        case "txt", "text", "md", "markdown":
            // Plain-text / Markdown: read the file directly (UTF-8 first,
            // then a lenient fallback for other encodings).
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url))
                ?? ""
        default:
            return ""
        }
    }

    private func extract(
        url: URL,
        options: [NSAttributedString.DocumentReadingOptionKey: Any]
    ) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        guard let attr = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else { return "" }
        return attr.string
    }
}
