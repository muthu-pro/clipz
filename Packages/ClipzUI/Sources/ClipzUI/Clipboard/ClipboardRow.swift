// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipzCore

/// The card portion of one timeline row. Kind-aware layout: text lays
/// out as prominent multi-line body text, image/screenshot/pdf render
/// a full-width hero preview. Every card has a colored 3 pt accent bar
/// on its leading edge so the kind reads at a glance, plus a soft
/// drop shadow to lift it off the window background.
/// Pasteboard type stamped on drags that originate from a Clipz card, so
/// the timeline's own drop handler can ignore them (a card nudged a few
/// points must not re-import itself). Shared by `ClipboardRow` (writer)
/// and `ClipboardContent` (reader).
enum InternalClipDrag {
    static let typeIdentifier = "tech.clipz.app.internalClip"
}

struct ClipboardRow: View {
    @Environment(AppContainer.self) private var container
    let item: ClipboardItem
    var matches: [SearchResult.Match] = []
    var highlighted: Bool = false

    /// True when this row is a search hit that matched a *detected object*
    /// (e.g. searching "person"). Drives the image preview to reveal the
    /// detection boxes so the user sees what matched.
    private var matchedDetectedObject: Bool {
        matches.contains { $0.source == .detectedObject }
    }

    @State private var isHovered = false
    @State private var isExpanded = false
    /// Set after a successful Touch ID reveal of a sensitive clip. Ephemeral —
    /// resets when the row is recycled, so the secret re-blurs.
    @State private var revealed = false
    @State private var copiedFlashDeadline: Date?

    /// A password/key the current policy says to blur behind Touch ID.
    private var isProtectedSensitive: Bool {
        item.isSensitive && container.sensitiveContentPolicy == .protect
    }

    /// True while the secret should be hidden (protected and not yet revealed).
    private var isMasked: Bool {
        isProtectedSensitive && !revealed
    }
    /// Active seek request for the video player, bumped each time the user
    /// clicks a matched OCR snippet.
    @State private var videoSeek: VideoSeek?
    @State private var seekToken = 0

    /// OCR matches on a video that carry a frame timestamp — the ones we
    /// can seek to. Empty for non-video items.
    private var seekableMatches: [SearchResult.Match] {
        guard item.kind == .video else { return [] }
        return matches.filter { $0.source == .ocrText && $0.time != nil }
    }

    var body: some View {
        // The visually-clipped card body. Everything that draws the
        // card's shape / fill / border / shadow lives inside `card`.
        let card = VStack(alignment: .leading, spacing: 10) {
            header
            bodyView
            if !nonContentMatches.isEmpty {
                matchesStrip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            .spring(response: 0.38, dampingFraction: 0.85),
            value: isExpanded
        )
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    item.isSensitive
                        ? AnyShapeStyle(sensitiveTint.opacity(0.55))
                        : (highlighted
                            ? AnyShapeStyle(Color.accentColor.opacity(0.45))
                            : AnyShapeStyle(.separator)),
                    lineWidth: (item.isSensitive || highlighted) ? 1.5 : 1
                )
        )
        .shadow(
            color: Color.black.opacity(highlighted ? 0.08 : 0.04),
            radius: highlighted ? 8 : 4,
            x: 0,
            y: 2
        )

        // The overlay controls (action strip + expand toggle) live
        // OUTSIDE the card's shape so the 11 pt expand-button offset
        // isn't clipped by the rounded rect. The card above already
        // clips its own content against RoundedRectangle via the
        // background/overlay pair, so we don't need another clipShape.
        return card
            .overlay(alignment: .topTrailing) {
                actionStrip
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .animation(.easeInOut(duration: 0.14), value: isHovered)
            }
            .overlay(alignment: .bottom) {
                if canExpand {
                    expandToggleButton
                        .offset(y: 11)
                }
            }
            .padding(.bottom, canExpand ? 12 : 0)
            .onHover { hovering in isHovered = hovering }
            .onDrag { makeDragProvider() }
            // VoiceOver: present each card as one element with a spoken
            // description and the copy / delete actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityValue(item.pinned ? "Pinned" : "")
            .accessibilityHint("Return to copy. Delete to remove.")
            .accessibilityAction(named: "Copy") {
                Task {
                    if !revealed {
                        guard await container.ensureSensitiveAccess(to: item) else { return }
                    }
                    await PasteboardWriter.write(
                        item,
                        fileStore: container.fileStore,
                        watcher: container.clipboardWatcher
                    )
                }
            }
            .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") {
                Task {
                    try? await container.clipboard.setPinned(id: item.id, pinned: !item.pinned)
                }
            }
            .accessibilityAction(named: "Delete") {
                Task { try? await container.clipboard.delete(id: item.id) }
            }
    }

    /// Spoken description, e.g. "Image, invoice.png, from Safari, 2h ago".
    private var accessibilityDescription: String {
        var parts: [String] = [kindLabel.capitalized]
        let preview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty { parts.append(String(preview.prefix(120))) }
        if let app = item.sourceApp?.name, !app.isEmpty { parts.append("from \(app)") }
        parts.append(Self.accessibilityRelativeFormatter.localizedString(
            for: item.createdAt, relativeTo: .now
        ))
        return parts.joined(separator: ", ")
    }

    private static let accessibilityRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Header (kind pill · app · extras)

    private var header: some View {
        HStack(spacing: 8) {
            kindPill

            if item.isSensitive {
                sensitiveBadge
            }

            if item.pinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }

            if let pages = item.mediaInfo?.pageCount, pages > 0 {
                metaChip(systemImage: "doc.text", text: "\(pages) page\(pages == 1 ? "" : "s")")
            }

            if let source = item.sourceApp {
                sourceAppChip(source)
            }

            Spacer(minLength: 0)
        }
    }

    private var kindPill: some View {
        Image(systemName: kindSymbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(kindColor)
            .frame(width: 22, height: 20)
            .background(
                Capsule().fill(kindColor.opacity(0.15))
            )
            .help(kindLabel)
    }

    /// Marks a clip the source app flagged as a password/key.
    private var sensitiveBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Sensitive")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(sensitiveTint)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(sensitiveTint.opacity(0.15)))
        .help("Marked private by the source app. Manage in Settings → Clipboard.")
    }

    private var sensitiveTint: Color { .orange }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    /// App-source chip that swaps the generic "app" glyph for the real
    /// bundle icon resolved via NSWorkspace. Falls back to the generic
    /// glyph when the bundle isn't installed or the capture didn't
    /// carry a bundle id.
    private func sourceAppChip(_ source: ClipboardItem.SourceApp) -> some View {
        HStack(spacing: 5) {
            AppIconView(bundleID: source.bundleID, size: 14)
            Text(source.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hover action strip (copy · download)

    private var actionStrip: some View {
        HStack(spacing: 6) {
            actionButton(
                systemImage: showCopiedFlash ? "checkmark" : "doc.on.doc.fill",
                tooltip: showCopiedFlash ? "Copied" : "Copy to clipboard",
                tint: showCopiedFlash ? Color.green : Color.accentColor
            ) {
                Task {
                    // Sensitive clips require Touch ID before hitting the
                    // pasteboard (skipped if already revealed this session).
                    if !revealed {
                        guard await container.ensureSensitiveAccess(to: item) else { return }
                    }
                    await ClipboardItemActions.copy(
                        item,
                        fileStore: container.fileStore,
                        watcher: container.clipboardWatcher
                    )
                    await MainActor.run {
                        copiedFlashDeadline = Date().addingTimeInterval(1.2)
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    await MainActor.run {
                        if let deadline = copiedFlashDeadline, Date() >= deadline {
                            copiedFlashDeadline = nil
                        }
                    }
                }
            }
            if shouldShowDownload {
                actionButton(
                    systemImage: "arrow.down.to.line",
                    tooltip: "Save to…",
                    tint: .primary
                ) {
                    Task {
                        if !revealed {
                            guard await container.ensureSensitiveAccess(to: item) else { return }
                        }
                        ClipboardItemActions.save(item, fileStore: container.fileStore)
                    }
                }
            }
            actionButton(
                systemImage: "trash",
                tooltip: "Delete",
                tint: .red
            ) {
                Task { try? await container.clipboard.delete(id: item.id) }
            }
        }
    }

    /// Download makes sense for every file-backed kind (they *are*
    /// files already) and for code-ish text that someone would plausibly
    /// want to save as a source file. Plain-prose clips can just be
    /// copied, so we hide the save affordance there to reduce noise.
    private var shouldShowDownload: Bool {
        switch item.kind {
        case .text:
            return ClipboardRow.looksLikeCode(item.content)
        case .html:
            return true
        case .image, .screenshot, .video,
             .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            return true
        }
    }

    /// Heuristic classifier: does this text look like source code? We
    /// don't need to be right 100 % of the time — a false positive just
    /// surfaces a Save button the user can ignore; a false negative
    /// hides it for a prose clip, which is the better direction to err.
    /// Covers the languages most commonly copied into a clipboard
    /// manager: Python, JS / TS, Swift, Go, Rust, Java, Kotlin, C / C++,
    /// Ruby, PHP, HTML, shell, SQL, and JSON-shaped payloads.
    private static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }

        // A leading interpreter hint or markup doctype is a dead give-away.
        let prefixes = ["#!/", "<!doctype", "<?xml", "<?php", "<html", "<svg", "<script"]
        let lower = trimmed.lowercased()
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }

        // JSON-shaped payloads read as structured data — surfacing Save
        // lets the user drop them into a .json file.
        if (trimmed.first == "{" && trimmed.last == "}") ||
            (trimmed.first == "[" && trimmed.last == "]") {
            return true
        }

        // Language keywords that almost never show up in prose (except
        // as a discussion of the keyword itself, which is rare enough
        // to accept as a false positive).
        let keywords: [String] = [
            "def ", "function ", "class ", "impl ", "trait ",
            "import ", "from ", "#include", "package ",
            "public class ", "public func ", "func ", "fn ",
            "const ", "let ", "var ",
            "if __name__", "=> {", "public static void",
            "select ", "insert ", "update ", "delete from ",
            "struct ", "enum ", "protocol ", "interface "
        ]
        if keywords.contains(where: { lower.contains($0) }) { return true }

        // Heavy, consistent indentation is another strong signal for
        // code — a prose block rarely has multiple lines starting with
        // tab or two-plus spaces.
        let lines = trimmed.split(separator: "\n")
        if lines.count >= 4 {
            let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
            if indented >= lines.count / 3 { return true }
        }

        // Lots of non-prose punctuation — curly braces, semicolons,
        // arrow operators — in a short sample.
        let codePunct: Set<Character> = ["{", "}", ";", "<", ">", "/", "="]
        let punctCount = trimmed.prefix(300).reduce(0) { $0 + (codePunct.contains($1) ? 1 : 0) }
        if punctCount >= 8 { return true }

        return false
    }

    private var showCopiedFlash: Bool {
        guard let d = copiedFlashDeadline else { return false }
        return Date() < d
    }

    private func actionButton(
        systemImage: String,
        tooltip: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 22, height: 22)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Body (kind-aware)

    @ViewBuilder
    private var bodyView: some View {
        switch item.kind {
        case .image, .screenshot:
            if !item.content.isEmpty {
                LargeMediaPreview(
                    filename: item.content,
                    maxHeight: 400,
                    fallbackSymbol: kindSymbol,
                    fallbackTint: kindColor,
                    openableURL: container.fileStore.mediaURL(filename: item.content),
                    detectionItemID: item.id,
                    forceShowBoxes: matchedDetectedObject
                )
            } else {
                textBody
            }

        case .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            VStack(alignment: .leading, spacing: 8) {
                if !titleText.isEmpty {
                    Text(titleText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                // PDFs render their first page on demand via PDFKit,
                // so we point the preview at the original file and skip
                // the cached-thumbnail dependency. The other doc kinds
                // (DOC / XLS / Numbers) still need the analyzer to write
                // a PNG thumbnail — QuickLook is the only viable path.
                if item.kind == .pdf {
                    LargeMediaPreview(
                        filename: item.content,
                        maxHeight: 220,
                        fallbackSymbol: kindSymbol,
                        fallbackTint: kindColor,
                        openableURL: container.fileStore.mediaURL(filename: item.content)
                    )
                } else if let thumb = item.mediaInfo?.thumbnailFilename, !thumb.isEmpty {
                    LargeMediaPreview(
                        filename: thumb,
                        maxHeight: 220,
                        fallbackSymbol: kindSymbol,
                        fallbackTint: kindColor,
                        // Click opens the actual document, not the cached
                        // thumbnail image — NSWorkspace hands it to the
                        // registered default viewer for the file type.
                        openableURL: container.fileStore.mediaURL(filename: item.content)
                    )
                } else {
                    documentFallback
                }
            }

        case .video:
            VStack(alignment: .leading, spacing: 8) {
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !item.content.isEmpty {
                    VideoPreview(
                        url: container.fileStore.mediaURL(filename: item.content),
                        maxHeight: 400,
                        fallbackTint: kindColor,
                        // Single match → jump straight to that frame on load.
                        initialSeek: seekableMatches.count == 1
                            ? seekableMatches.first?.time
                            : nil,
                        seek: videoSeek
                    )
                } else {
                    videoFallback
                }
            }

        case .text, .html:
            textBody
        }
    }

    /// True when this clip should render with a monospaced body. We judge
    /// it on the *displayed* text (plain for HTML), so web prose reads as
    /// prose and only genuine code/markup gets column alignment.
    private var shouldRenderAsCode: Bool {
        if item.kind == .text || item.kind == .html {
            return ClipboardRow.looksLikeCode(plainContent)
        }
        return false
    }

    private var bodyFont: Font {
        shouldRenderAsCode
            ? .system(size: 12, design: .monospaced)
            : .system(size: 13)
    }

    @ViewBuilder
    private var textBody: some View {
        if isMasked {
            sensitiveMaskedBody
        } else {
            revealedTextBody
        }
    }

    /// A password/key shown with the trailing ~half blurred, plus a Reveal
    /// button that requires Touch ID. No text selection, so the plaintext
    /// can't be dragged/copied out around the gate.
    private var sensitiveMaskedBody: some View {
        // Reveal only the first 3 characters; everything after is heavily
        // blurred so the secret can't be read off the screen.
        let shown = String(plainContent.prefix(3))
        let hidden = String(plainContent.dropFirst(3))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(shown)
                Text(hidden).blur(radius: 9)
            }
            .font(bodyFont)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

            Button {
                Task {
                    if await container.ensureSensitiveAccess(to: item) { revealed = true }
                }
            } label: {
                Label("Reveal", systemImage: "lock.open.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(sensitiveTint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var revealedTextBody: some View {
        let body: AnyView = {
            if let contentMatch = matches.first(where: { $0.source == .content }) {
                return AnyView(
                    HighlightedText(snippet: contentMatch.snippet, font: bodyFont)
                        .lineLimit(isExpanded ? nil : 6)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                )
            } else {
                let text = Text(expandedBodyText)
                    .font(bodyFont)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 6)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                // A revealed sensitive clip still shouldn't be selectable —
                // reveal is meant for reading, copy goes through the gate.
                if item.isSensitive {
                    return AnyView(text.textSelection(.disabled))
                } else {
                    return AnyView(text.textSelection(.enabled))
                }
            }
        }()

        if shouldRenderAsCode {
            body
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(kindColor.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(kindColor.opacity(0.15), lineWidth: 1)
                )
        } else {
            body
        }
    }

    /// The text we actually show for a clip. HTML clips are stored as raw
    /// markup so we can still paste rich text, but on screen we only ever
    /// render the readable plain text — never the tags.
    private var plainContent: String {
        item.kind == .html ? HTMLText.plain(from: item.content) : item.content
    }

    /// When expanded, show the full clipboard content; when collapsed,
    /// use the condensed preview — which for long clips is already
    /// capped at ~500 chars by ClipboardService's `searchPreview`.
    private var expandedBodyText: String {
        guard item.kind == .text || item.kind == .html else {
            return previewText
        }
        return isExpanded ? plainContent : previewText
    }

    /// Only worth offering an expand toggle when the clip actually has
    /// more content than the 6-line preview can fit. Heuristics that
    /// don't require a GeometryReader measure pass: long content, or
    /// lots of newlines.
    private var canExpand: Bool {
        guard item.kind == .text || item.kind == .html else { return false }
        let text = plainContent
        let hasManyLines = text.filter(\.isNewline).count > 5
        return text.count > 260 || hasManyLines
    }

    /// Small pill that hangs off the bottom of the card at center. We
    /// draw it on the card's trailing edge via `.offset(y: 11)` so it
    /// overlaps the card border and reads as an integrated divider
    /// handle, not a floating control.
    private var expandToggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text(isExpanded ? "Show less" : "Show more")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Expand to read everything")
    }

    // MARK: - Match strip (non-content hits)

    /// Content-source matches are rendered inline (they replace the
    /// card body). Everything else — OCR, barcode payload, detected
    /// object, document text — shows as a separate strip under the
    /// body so the user sees *why* the clip was returned.
    private var nonContentMatches: [SearchResult.Match] {
        matches.filter { $0.source != .content }
    }

    private var matchesStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nonContentMatches.enumerated()), id: \.offset) { _, match in
                matchRow(match)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func matchRow(_ match: SearchResult.Match) -> some View {
        let seekable = item.kind == .video
            && match.source == .ocrText
            && match.time != nil

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: matchSymbol(for: match.source))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(matchLabel(for: match.source))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.accentColor)
                HighlightedText(
                    snippet: match.snippet,
                    font: .system(size: 12)
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            if seekable, let time = match.time {
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Image(systemName: "play.circle.fill")
                    Text(Self.timestamp(time))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(seekable ? "Jump to this frame in the video" : "")
        .onTapGesture {
            guard seekable, let time = match.time else { return }
            seekToken += 1
            videoSeek = VideoSeek(time: time, token: seekToken)
        }
    }

    /// `m:ss` timestamp for a seek badge.
    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func matchSymbol(for source: SearchResult.Match.Source) -> String {
        switch source {
        case .ocrText:         return "textformat.abc"
        case .barcodePayload:  return "barcode.viewfinder"
        case .detectedObject:  return "tag"
        case .documentText:    return "doc.text.magnifyingglass"
        case .content:         return "doc.on.doc"
        }
    }

    private func matchLabel(for source: SearchResult.Match.Source) -> String {
        switch source {
        case .ocrText:         return "OCR TEXT"
        case .barcodePayload:  return "BARCODE"
        case .detectedObject:  return "TAGGED"
        case .documentText:    return "IN DOCUMENT"
        case .content:         return "CLIP TEXT"
        }
    }

    private var documentFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(kindColor.opacity(0.10))
            VStack(spacing: 6) {
                Image(systemName: kindSymbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(kindColor)
                Text(item.originalName ?? "Document")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 140)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var videoFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [kindColor.opacity(0.22), kindColor.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(kindColor)
        }
        .frame(height: 160)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Derived

    private var titleText: String {
        if let title = item.metadata?.title, !title.isEmpty { return title }
        if let name = item.originalName, !name.isEmpty { return name }
        return item.content
    }

    private var previewText: String {
        if let preview = item.searchPreview, !preview.isEmpty {
            return preview
        }
        if item.kind.isFilesystemBacked, let name = item.originalName {
            return name
        }
        return plainContent
    }

    private var kindLabel: String {
        switch item.kind {
        case .text:       return "TEXT"
        case .html:       return "HTML"
        case .image:      return "IMAGE"
        case .screenshot: return "SCREENSHOT"
        case .video:      return "VIDEO"
        case .pdf:        return "PDF"
        case .doc:        return "DOC"
        case .docx:       return "DOCX"
        case .xls:        return "XLS"
        case .xlsx:       return "XLSX"
        case .numbers:    return "NUMBERS"
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .text, .html: return .accentColor
        case .image, .screenshot: return .blue
        case .video: return .purple
        case .pdf: return .red
        case .doc, .docx: return .indigo
        case .xls, .xlsx, .numbers: return .green
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: return "textformat"
        case .html: return "curlybraces"
        case .image: return "photo"
        case .screenshot: return "camera.viewfinder"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .doc, .docx: return "doc.text"
        case .xls, .xlsx, .numbers: return "tablecells"
        }
    }

    // MARK: - Drag-out

    /// Build an NSItemProvider appropriate for the clip's kind so the
    /// user can drag a card straight onto Finder, Mail, Slack, the
    /// desktop, wherever. Text clips register as plain text / HTML;
    /// media and document clips register a file representation that
    /// points at the copy FileStore already holds.
    ///
    /// `suggestedName` must NOT carry the file extension: the receiving
    /// side appends the registered type identifier's preferred extension
    /// itself, so a name like `"Screenshot….png"` plus `UTType.png`
    /// lands on disk as `Screenshot….png.png`.
    private func makeDragProvider() -> NSItemProvider {
        // Mark a drag as "from within Clipz" so our own drop handler won't
        // re-import it. The OS hands the drop a temp copy and SwiftUI's drop
        // bridge doesn't reliably surface the drag's custom type, so a
        // shared flag is the dependable signal. Auto-clears so an external
        // drag (out to Finder) doesn't leave it stuck on.
        container.internalDragInProgress = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            container.internalDragInProgress = false
        }

        let provider = NSItemProvider()
        // Secondary signal (best-effort) for the drop handler.
        provider.registerDataRepresentation(
            forTypeIdentifier: InternalClipDrag.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(item.id.utf8), nil)
            return nil
        }
        switch item.kind {
        case .text:
            provider.suggestedName = "clip"
            if let data = item.content.data(using: .utf8) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.plainText.identifier,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        case .html:
            provider.suggestedName = "clip"
            if let data = item.content.data(using: .utf8) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.html.identifier,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        case .image, .screenshot, .video,
             .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            let url = container.fileStore.mediaURL(filename: item.content)
            let rawName = item.originalName ?? item.content
            provider.suggestedName = (rawName as NSString).deletingPathExtension
            provider.registerFileRepresentation(
                forTypeIdentifier: dragTypeIdentifier.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(url, false, nil)
                return nil
            }
        }
        return provider
    }

    private var dragTypeIdentifier: UTType {
        switch item.kind {
        case .text:                return .plainText
        case .html:                return .html
        case .image, .screenshot:  return .png
        case .video:               return .movie
        case .pdf:                 return .pdf
        case .doc, .docx,
             .xls, .xlsx, .numbers: return .data
        }
    }
}
