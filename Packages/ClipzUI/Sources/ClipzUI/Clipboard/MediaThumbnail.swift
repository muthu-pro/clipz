// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ImageIO
import AppKit
import PDFKit
import ClipzCore

/// Async-loading thumbnail for an image/screenshot/PDF row. Resolves the
/// file via `FileStore`, downsizes through `CGImageSourceCreateThumbnail`,
/// and falls back to a symbol placeholder if the file is missing or can't
/// be decoded (e.g. storage wiped from under us).
struct MediaThumbnail: View {
    let filename: String
    let size: CGFloat
    let fallbackSymbol: String
    let fallbackTint: Color

    @Environment(AppContainer.self) private var container
    @State private var image: NSImage?
    @State private var didAttempt = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(fallbackTint.opacity(0.15))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if didAttempt {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(fallbackTint)
                    .font(.system(size: size * 0.4, weight: .medium))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .task(id: filename) {
            await load()
        }
    }

    private func load() async {
        let url = await MainActor.run { container.fileStore.mediaURL(filename: filename) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Oversample at 4x display pixels (floor 1024px) so the popup
        // thumbnails stay sharp regardless of system zoom. ImageIO falls
        // back to the original resolution when the source is smaller.
        let target = max(Int(size * scale * 4), 1024)
        let isPDF = url.pathExtension.lowercased() == "pdf"
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return isPDF
                ? Self.renderPDFFirstPage(url: url, maxPixelSize: target)
                : Self.renderImage(url: url, maxPixelSize: target)
        }.value
        await MainActor.run {
            self.image = loaded
            self.didAttempt = true
        }
    }

    nonisolated private static func renderImage(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// First-page PDF render via bitmap CGContext (no NSImage.lockFocus,
    /// so safe off-main). White background so transparent PDFs don't
    /// read as empty thumbnails in the popup.
    nonisolated private static func renderPDFFirstPage(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            return nil
        }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let target = CGFloat(maxPixelSize)
        let scale = min(target / pageRect.width, target / pageRect.height)
        let pixelSize = CGSize(
            width: max(1, pageRect.width * scale),
            height: max(1, pageRect.height * scale)
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: pixelSize)
    }
}
