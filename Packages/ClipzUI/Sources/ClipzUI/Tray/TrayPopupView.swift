// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ClipzCore

/// SwiftUI content hosted inside the tray NSPopover. Shows the most
/// recent 20 captures; clicking a row writes it back to the pasteboard
/// and dismisses the popover.
struct TrayPopupView: View {
    @Environment(AppContainer.self) private var container

    /// Closure fired when the user selects a clip. `TrayController`
    /// supplies one that writes to the pasteboard + dismisses the popover.
    let onSelect: (ClipboardItem) -> Void

    @State private var items: [ClipboardItem] = []
    @State private var totalCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            if items.isEmpty {
                empty
            } else {
                list
            }

            Divider()
            footer
        }
        .background(.regularMaterial)
        .task { await reload() }
        .task { await subscribeToEvents() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            ClipzWordmark(size: 14)
            Text("\(totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                openMainWindow()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Clipz main window")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Clipz")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    TrayRow(item: item) {
                        onSelect(item)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            if let logo = NSImage(named: "ClipzLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .opacity(0.55)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            }
            Text("Nothing captured yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Copy anything and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            legend("↵", "Paste")
            Divider().frame(height: 10)
            legend("esc", "Dismiss")
            Spacer()
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
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                )
            Text(label)
        }
    }

    // MARK: - Data

    private func reload() async {
        let list = (try? await container.clipboard.fetchPage(limit: 20)) ?? []
        let total = (try? await container.clipboard.countItems()) ?? 0
        await MainActor.run {
            self.items = list
            self.totalCount = total
        }
    }

    private func subscribeToEvents() async {
        let stream = await container.broadcaster.events()
        for await _ in stream {
            await reload()
        }
    }

    // MARK: - Helpers

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// One row in the tray popover — tighter than `ClipboardRow` so more
/// fits on screen.
private struct TrayRow: View {
    @Environment(AppContainer.self) private var container
    let item: ClipboardItem
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var showCopied = false

    /// A password/key the policy says to blur behind Touch ID.
    private var isMasked: Bool {
        item.isSensitive && container.sensitiveContentPolicy == .protect
    }

    var body: some View {
        Button(action: {
            // Visual confirmation that the row's contents landed on the
            // clipboard. `TrayController.handleSelect` keeps the popover
            // open for ~700 ms in the manual-paste path so this badge
            // has time to register before the popover tears down.
            showCopied = true
            onTap()
        }) {
            HStack(spacing: 10) {
                leadingBadge

                VStack(alignment: .leading, spacing: 2) {
                    Text(isMasked ? maskedPreview : previewText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .blur(radius: isMasked ? 6 : 0)

                    HStack(spacing: 5) {
                        if item.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text("Sensitive")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        if let name = item.sourceApp?.name {
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(relativeDate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if showCopied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Copied")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
            .animation(.easeOut(duration: 0.12), value: showCopied)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if showCopied { return Color.green.opacity(0.18) }
        if isHovered  { return Color.accentColor.opacity(0.20) }
        return .clear
    }

    private var previewText: String {
        if let preview = item.searchPreview, !preview.isEmpty {
            return preview
        }
        if item.kind.isFilesystemBacked, let name = item.originalName {
            return name
        }
        return item.content
    }

    /// Never renders the full secret: only the first 3 chars, then bullets
    /// (blur is applied on top for the "sensitive" feel).
    private var maskedPreview: String {
        let shown = String(previewText.prefix(3))
        let remaining = max(0, previewText.count - 3)
        return shown + String(repeating: "•", count: max(3, remaining))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var relativeDate: String {
        Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: .now)
    }

    /// Real thumbnail when the clip has a usable image source, falling
    /// back to the kind glyph otherwise. Picture-backed clips show their
    /// pixels; documents show their analyzer-cached preview; text /
    /// HTML / video show the generic badge.
    @ViewBuilder
    private var leadingBadge: some View {
        if let thumb = thumbnailFilename {
            MediaThumbnail(
                filename: thumb,
                size: 26,
                fallbackSymbol: kindSymbol,
                fallbackTint: kindColor
            )
        } else {
            kindBadge
        }
    }

    /// Where to source the leading thumbnail from. Returns nil for kinds
    /// without a meaningful preview (text/HTML) or where rendering would
    /// be too lossy at popup size (video). PDFs render their first page
    /// on-demand inside `MediaThumbnail`; other documents need the
    /// analyzer to have cached a PNG (`mediaInfo?.thumbnailFilename`).
    private var thumbnailFilename: String? {
        switch item.kind {
        case .image, .screenshot, .pdf:
            return item.content
        case .doc, .docx, .xls, .xlsx, .numbers:
            return item.mediaInfo?.thumbnailFilename
        case .text, .html, .video:
            return nil
        }
    }

    private var kindBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(kindColor.opacity(0.20))
                .frame(width: 26, height: 26)
            Image(systemName: kindSymbol)
                .foregroundStyle(kindColor)
                .font(.system(size: 12, weight: .medium))
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
}
