// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzCore

/// Content of the quick-paste panel: a focused search field over a live,
/// keyboard-navigable list of clips. Navigation keys are handled by
/// `QuickPasteController`'s event monitor; this view just renders state
/// from `QuickPasteModel` and reports taps.
struct QuickPasteView: View {
    @Bindable var model: QuickPasteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if model.results.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .task {
            await model.load()
            searchFocused = true
        }
        // Re-assert focus if the panel is re-shown or the field ever
        // yields first responder — typing should always reach search.
        .onChange(of: model.results.count) { _, _ in
            if !searchFocused { searchFocused = true }
        }
    }

    // MARK: - Sections

    private var searchBar: some View {
        HStack(spacing: 9) {
            clipzLogo
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search your clips…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onChange(of: model.query) { _, _ in model.queryChanged() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.queryChanged()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
    }

    /// Clipz branding in the panel's search bar. Falls back to a glyph if
    /// the bundled logo asset isn't available.
    @ViewBuilder
    private var clipzLogo: some View {
        if let ns = NSImage(named: "ClipzLogo") {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        QuickPasteRow(result: result, selected: index == model.selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(index)
                                model.activateSelection()
                            }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selected) { _, newValue in
                withAnimation(.easeOut(duration: 0.10)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "Nothing captured yet" : "No matches for “\(model.query)”")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            legend("↑↓", "Navigate")
            legend("↩", "Paste")
            legend("esc", "Close")
            Spacer()
            if !model.results.isEmpty {
                Text("\(model.results.count)")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legend(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            Text(label)
        }
    }
}

/// One compact, optionally-highlighted row in the quick-paste list.
private struct QuickPasteRow: View {
    @Environment(AppContainer.self) private var container
    let result: QuickPasteResult
    let selected: Bool

    private var item: ClipboardItem { result.item }

    private var isMasked: Bool {
        item.isSensitive && container.sensitiveContentPolicy == .protect
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingBadge
            VStack(alignment: .leading, spacing: 2) {
                previewLine
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if item.isSensitive {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text("Sensitive").foregroundStyle(.orange)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let name = item.sourceApp?.name {
                        Text(name)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(relativeDate)
                }
                .font(.caption2)
                .foregroundStyle(selected ? .secondary : .tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.20) : .clear)
        )
        .overlay(alignment: .leading) {
            // A slim accent bar makes the selected row unmistakable at a glance.
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
    }

    /// Prefer the search snippet (shows the matched term, highlighted) so
    /// the user sees why this clip surfaced; otherwise a plain preview.
    @ViewBuilder
    private var previewLine: some View {
        if isMasked {
            Text(maskedPreview)
                .font(.system(size: 13, weight: .medium))
                .blur(radius: 6)
        } else if let snippet = result.snippet, !snippet.isEmpty {
            Text(highlighted(snippet))
                .font(.system(size: 13, weight: .medium))
        } else {
            Text(previewText)
                .font(.system(size: 13, weight: .medium))
        }
    }

    /// Never renders the full secret: only the first 3 chars, then bullets.
    private var maskedPreview: String {
        let shown = String(previewText.prefix(3))
        let remaining = max(0, previewText.count - 3)
        return shown + String(repeating: "•", count: max(3, remaining))
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        let parsed = HighlightedString.parse(snippet)
        var attr = AttributedString(parsed.plain)
        for range in parsed.highlightedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attr),
                  let upper = AttributedString.Index(range.upperBound, within: attr)
            else { continue }
            attr[lower..<upper].backgroundColor = Color.accentColor.opacity(0.28)
            attr[lower..<upper].foregroundColor = .primary
            attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }

    private var previewText: String {
        if let preview = item.searchPreview, !preview.isEmpty { return preview }
        if item.kind.isFilesystemBacked, let name = item.originalName { return name }
        return item.content
    }

    @ViewBuilder
    private var leadingBadge: some View {
        if let thumb = thumbnailFilename {
            MediaThumbnail(
                filename: thumb,
                size: 28,
                fallbackSymbol: kindSymbol,
                fallbackTint: kindColor
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(kindColor.opacity(0.20))
                    .frame(width: 28, height: 28)
                Image(systemName: kindSymbol)
                    .foregroundStyle(kindColor)
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }

    private var thumbnailFilename: String? {
        switch item.kind {
        case .image, .screenshot, .pdf: return item.content
        case .doc, .docx, .xls, .xlsx, .numbers: return item.mediaInfo?.thumbnailFilename
        case .text, .html, .video: return nil
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var relativeDate: String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: .now)
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
}
