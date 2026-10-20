// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ImageIO
import AppKit
import PDFKit
import ClipzCore

/// Full-width hero preview for media-backed clipboard rows. Loads the
/// image at a resolution generous enough for the card's visible size
/// (so the thumbnail stays sharp on Retina), then aspect-fills into a
/// rounded container with a tinted fallback if decoding fails.
struct LargeMediaPreview: View {
    let filename: String
    let maxHeight: CGFloat
    let fallbackSymbol: String
    let fallbackTint: Color
    /// Optional source file to open when the preview is clicked. When
    /// nil, clicking does nothing — the preview behaves like a static
    /// image. Most callers pass the same FileStore URL they're reading
    /// the thumbnail from.
    var openableURL: URL? = nil
    /// When set, the view fetches that item's object detections and draws
    /// labeled bounding boxes over the image. Left nil for previews where
    /// detection overlays don't apply (e.g. document thumbnails).
    var detectionItemID: String? = nil
    /// Forces detection boxes visible regardless of the opt-in toggle —
    /// set when this image is a search hit on a detected object, so the
    /// user immediately sees *what* matched (e.g. searching "person"
    /// boxes the people).
    var forceShowBoxes: Bool = false

    @Environment(AppContainer.self) private var container
    @State private var image: NSImage?
    @State private var imagePixelSize: CGSize = .zero
    @State private var detections: [DetectedObject] = []
    @State private var didAttempt = false
    @State private var isHoveringPreview = false
    /// Detection boxes are opt-in — hidden until the user toggles them on
    /// (here or in the full-screen viewer), so the preview reads as a
    /// clean image by default.
    @State private var showBoxes = false
    @State private var showFullView = false

    /// Tapping an image opens the in-app full viewer; PDFs (which have no
    /// in-app viewer here) still hand off to the system default app.
    private var isPDFSource: Bool {
        openableURL?.pathExtension.lowercased() == "pdf"
    }

    /// Boxes draw when the user opted in *or* the search forced them on.
    private var boxesVisible: Bool { showBoxes || forceShowBoxes }

    /// Source aspect ratio (w/h). Drives the fit so the *whole* image
    /// shows and the card height tracks the current width. Falls back to
    /// 4:3 until the pixel size is known (avoids a divide-by-zero and a
    /// jarring first-frame).
    private var imageAspect: CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return 4.0 / 3.0 }
        return imagePixelSize.width / imagePixelSize.height
    }

    var body: some View {
        previewContent
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isHoveringPreview = hovering
            if hovering, openableURL != nil {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            // Images open the in-app full viewer; anything else (PDFs,
            // doc thumbnails) defers to the system default app.
            if image != nil, !isPDFSource {
                showFullView = true
            } else if let url = openableURL {
                NSWorkspace.shared.open(url)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHoveringPreview)
        .animation(.easeInOut(duration: 0.12), value: showBoxes)
        .task(id: filename) { await load() }
        .task(id: detectionItemID) { await observeDetections() }
        .sheet(isPresented: $showFullView) {
            if let image {
                FullImageViewer(
                    image: image,
                    imageSize: imagePixelSize,
                    detections: detections,
                    openExternalURL: openableURL,
                    initialShowBoxes: forceShowBoxes
                )
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var previewContent: some View {
        if let image {
            imageContent(image)
        } else {
            placeholder
        }
    }

    /// The image, fit to the card's full width with height following the
    /// aspect ratio (capped at `maxHeight`). Because it's `.fit`, the whole
    /// image stays visible and simply rescales when the window width
    /// changes — nothing gets cropped. A tinted backing fills any
    /// letterbox bands for very tall images.
    private func imageContent(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(imageAspect, contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(fallbackTint.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if boxesVisible, !detections.isEmpty, imagePixelSize.width > 0 {
                    DetectionBoxOverlay(
                        detections: detections,
                        imageSize: imagePixelSize,
                        fill: false
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
                }
            }
            .overlay { hoverChrome }
    }

    /// Loading / decode-failure state. Holds a stable height so the row
    /// doesn't jump before the image resolves.
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(fallbackTint.opacity(0.08))
            if didAttempt {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(fallbackTint)
                    .font(.system(size: 48, weight: .light))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(maxHeight, 240))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var hoverChrome: some View {
        if isHoveringPreview {
            // Opt-in "objects" toggle (top-leading) + tap hint
            // (bottom-trailing).
            if !detections.isEmpty {
                VStack {
                    HStack {
                        chip(
                            systemImage: boxesVisible ? "viewfinder.circle.fill" : "viewfinder",
                            text: boxesVisible ? "Hide boxes" : "\(detections.count) objects"
                        )
                        .onTapGesture { showBoxes = !boxesVisible }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
                .transition(.opacity)
            }

            if openableURL != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        chip(
                            systemImage: isPDFSource
                                ? "arrow.up.forward.app"
                                : "arrow.up.left.and.arrow.down.right",
                            text: isPDFSource ? "Open" : "View"
                        )
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
    }

    /// Small translucent pill used for the hover affordances.
    private func chip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .contentShape(Capsule())
    }

    /// Load this item's detections, then keep them current: image analysis
    /// runs on a background queue *after* capture, so the boxes usually
    /// land a moment after the preview first renders. We reload whenever
    /// the broadcaster reports this item was updated (which analysis now
    /// emits on completion).
    private func observeDetections() async {
        guard let id = detectionItemID else { return }
        await loadDetections(id: id)
        let stream = await container.broadcaster.events()
        for await event in stream {
            if case let .updated(item) = event, item.id == id {
                await loadDetections(id: id)
            }
        }
    }

    private func loadDetections(id: String) async {
        let result = (try? await container.clipboard.fetchDetections(forItemID: id)) ?? []
        await MainActor.run { self.detections = result }
    }

    private func load() async {
        let url = await MainActor.run { container.fileStore.mediaURL(filename: filename) }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        // Oversample aggressively (4x the card's height, floor 4096px) so
        // thumbnails stay sharp on Retina, in fullscreen, and after the
        // user expands the row. ImageIO's thumbnail mode returns the
        // full image when the original is smaller than the target, so
        // this is effectively "max quality up to 4K".
        let pixelTarget = max(Int(maxHeight * scale * 4), 4096)
        let isPDF = url.pathExtension.lowercased() == "pdf"
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return isPDF
                ? Self.renderPDFFirstPage(url: url, maxPixelSize: pixelTarget)
                : Self.renderImage(url: url, maxPixelSize: pixelTarget)
        }.value
        await MainActor.run {
            self.image = loaded
            self.didAttempt = true
            // Pixel dimensions (not NSImage.size, which is .zero for the
            // ImageIO path) so the overlay can reproduce the aspect-fill.
            if let rep = loaded?.representations.first {
                self.imagePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
    }

    /// ImageIO path for raster sources (PNG / JPEG / HEIC / pre-generated
    /// document thumbnails). Returns nil if the URL isn't a decodable
    /// image — the caller falls back to the kind glyph.
    /// `CreateThumbnailFromImageAlways` forces a render from the full
    /// image (ignoring any low-res embedded thumbnail); combined with a
    /// generous max-pixel cap that yields the best quality ImageIO can
    /// produce short of returning the original raw decode.
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

    /// PDFKit path for `.pdf` URLs. Renders the first page on-demand so
    /// PDFs preview correctly even before the background analyzer has
    /// cached a `<id>_thumb.png` for them. Uses a bitmap CGContext (not
    /// NSImage.lockFocus) so it's safe to call off the main thread.
    /// White background under the page so transparent PDFs don't read
    /// as empty thumbnails.
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
        // Highest-fidelity rasterization for vector PDF content: full
        // antialiasing on edges and text, smooth font hinting, and
        // high-quality interpolation for any embedded raster images.
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelQuantizeFonts(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: pixelSize)
    }
}

/// Draws labeled detection rectangles over an aspect-filled image. The
/// boxes are normalized to the image (top-left origin, 0…1), so we first
/// reconstruct where the aspect-fill placed the image inside the
/// container, then map each box into that frame. A `Canvas` keeps this
/// cheap regardless of how many boxes there are.
private struct DetectionBoxOverlay: View {
    let detections: [DetectedObject]
    /// Pixel dimensions of the source image, for the aspect math.
    let imageSize: CGSize
    /// `true` for the aspect-*fill* inline preview, `false` for the
    /// aspect-*fit* full-screen viewer. Must match how the image is laid
    /// out or the boxes won't line up.
    var fill: Bool = true

    private let stroke = Color.green

    var body: some View {
        Canvas { ctx, size in
            let frame = Self.imageFrame(image: imageSize, in: size, fill: fill)
            for d in detections {
                let r = Self.boxRect(d.bbox, in: frame)
                ctx.stroke(
                    Path(roundedRect: r, cornerRadius: 3),
                    with: .color(stroke),
                    lineWidth: 1.5
                )
                let label = ctx.resolve(
                    Text(d.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(stroke)
                )
                // Sit the label just above the box, dropping inside when
                // the box hugs the top edge.
                let labelY = r.minY - 7 < 6 ? r.minY + 7 : r.minY - 7
                ctx.draw(label, at: CGPoint(x: r.minX + 2, y: labelY), anchor: .leading)
            }
        }
    }

    /// Where the image lands inside `container`. Fill (max scale) may
    /// extend past the edges — the caller clips it; fit (min scale)
    /// letterboxes inside.
    static func imageFrame(image: CGSize, in container: CGSize, fill: Bool) -> CGRect {
        guard image.width > 0, image.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let sx = container.width / image.width
        let sy = container.height / image.height
        let scale = fill ? max(sx, sy) : min(sx, sy)
        let w = image.width * scale
        let h = image.height * scale
        return CGRect(
            x: (container.width - w) / 2,
            y: (container.height - h) / 2,
            width: w,
            height: h
        )
    }

    static func boxRect(_ bbox: BoundingBox, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + bbox.x * frame.width,
            y: frame.minY + bbox.y * frame.height,
            width: bbox.width * frame.width,
            height: bbox.height * frame.height
        )
    }
}

/// In-app full-screen image viewer presented when an image preview is
/// tapped. Fits the whole image on a dark backdrop, with an opt-in
/// detection-box toggle and a hand-off to the system default app.
private struct FullImageViewer: View {
    let image: NSImage
    let imageSize: CGSize
    let detections: [DetectedObject]
    let openExternalURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var showBoxes: Bool

    init(
        image: NSImage,
        imageSize: CGSize,
        detections: [DetectedObject],
        openExternalURL: URL?,
        initialShowBoxes: Bool = false
    ) {
        self.image = image
        self.imageSize = imageSize
        self.detections = detections
        self.openExternalURL = openExternalURL
        _showBoxes = State(initialValue: initialShowBoxes)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if showBoxes, !detections.isEmpty, imageSize.width > 0 {
                        DetectionBoxOverlay(
                            detections: detections,
                            imageSize: imageSize,
                            fill: false
                        )
                        .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.92))
        }
        .frame(minWidth: 640, minHeight: 480)
        .frame(idealWidth: 1040, idealHeight: 780)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !detections.isEmpty {
                Toggle(isOn: $showBoxes) {
                    Label("\(detections.count) objects", systemImage: "viewfinder")
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            Spacer()
            if let url = openExternalURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
