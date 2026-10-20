// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import QuickLookThumbnailing
import AppKit

/// QuickLook-backed thumbnail generation for Word, Excel, Numbers, and
/// other file types macOS knows how to render a preview for but our
/// own extractors don't. Routes through `QLThumbnailGenerator`, which
/// is sandbox-safe and uses the system's own previewer.
public struct DocumentThumbnailer: Sendable {
    public init() {}

    /// Async request for a thumbnail. Returns PNG bytes or nil if the
    /// system couldn't produce one (e.g., unknown format, corrupt file).
    /// 1024 pt at 4x scale = 4096 px on the long edge — enough headroom
    /// for the row preview to stay sharp when expanded, in fullscreen,
    /// and on external displays without re-rendering.
    public func renderThumbnail(
        from url: URL,
        size: CGSize = CGSize(width: 1024, height: 1024),
        scale: CGFloat = 4
    ) async -> Data? {
        // Preferred: a crisp, high-res content thumbnail. Some Office files
        // (certain .docx / .xlsx) can't be rendered at this size or only
        // expose a lower-quality representation, so the strict `.thumbnail`
        // request returns nil for them. Fall back to a smaller request that
        // also accepts a low-quality thumbnail — but never `.icon`, so a file
        // with no real preview still falls through to the UI's glyph tile
        // rather than showing a generic document icon.
        if let png = await generate(from: url, size: size, scale: scale,
                                    types: .thumbnail) {
            return png
        }
        return await generate(
            from: url,
            size: CGSize(width: 512, height: 512),
            scale: 2,
            types: [.thumbnail, .lowQualityThumbnail]
        )
    }

    private func generate(
        from url: URL,
        size: CGSize,
        scale: CGFloat,
        types: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: types
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ) { rep, _ in
                guard let rep, let png = Self.png(from: rep.nsImage) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    private static func png(from nsImage: NSImage) -> Data? {
        guard let tiff = nsImage.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}
