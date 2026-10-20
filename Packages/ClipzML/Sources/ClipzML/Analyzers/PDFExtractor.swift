// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import PDFKit
import AppKit

/// Inline PDF text extraction via PDFKit. Replaces the Electron app's
/// `pdf-extractor` helper binary. Per-page output lets the search layer
/// jump to the matching page without re-scanning.
public struct PDFExtractor: Sendable {
    public init() {}

    /// Extract per-page text and the full concatenation. Returns an
    /// empty result (not an error) for un-openable or empty PDFs so the
    /// capture's search-preview still indexes — just without body text.
    public func extract(from url: URL) -> PDFExtraction {
        guard let doc = PDFDocument(url: url) else {
            return PDFExtraction(fullText: "", pages: [])
        }
        var pages: [String] = []
        pages.reserveCapacity(doc.pageCount)
        for index in 0..<doc.pageCount {
            pages.append(doc.page(at: index)?.string ?? "")
        }
        return PDFExtraction(
            fullText: pages.joined(separator: "\n\n"),
            pages: pages
        )
    }

    /// First-page thumbnail for list previews. Rendered at the supplied
    /// `size` (in points, backing scale applied by the caller at display
    /// time). 2048 pt per side gives a sharp result well beyond Retina
    /// display targets. Nil on failure — UI uses a generic PDF icon
    /// placeholder.
    public func renderThumbnail(
        from url: URL,
        size: CGSize = CGSize(width: 2048, height: 2048)
    ) -> Data? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0)
        else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let renderSize = CGSize(
            width: pageRect.width * scale,
            height: pageRect.height * scale
        )
        let image = NSImage(size: renderSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.scaleBy(x: scale, y: scale)
            // Render on a white background so transparent PDFs don't
            // produce an empty transparent thumbnail.
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: pageRect.size))
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    public struct PDFExtraction: Sendable, Equatable {
        public let fullText: String
        public let pages: [String]

        public init(fullText: String, pages: [String]) {
            self.fullText = fullText
            self.pages = pages
        }

        public var pageCount: Int { pages.count }
    }
}
