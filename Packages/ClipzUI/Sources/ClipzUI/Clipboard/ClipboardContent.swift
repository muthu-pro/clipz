// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import ClipzCore

/// One row in the timeline: an item plus any search matches for it.
/// When no search is active, `matches` is empty.
struct TimelineEntry {
    let item: ClipboardItem
    let matches: [SearchResult.Match]
}

/// What the filter bar's chips mean. Each group maps to a set of raw
/// `ClipboardKind`s so the UI can say "Text" without caring that Text
/// and HTML are separate storage kinds internally, and "Documents"
/// without enumerating six office formats at the call site.
enum KindFilterGroup: Hashable {
    case text       // Plain text + HTML
    case image      // Pasted images
    case screenshot // Screenshot-folder captures
    case document   // PDF / .doc(x) / .xls(x) / .numbers

    var kinds: Set<ClipboardKind> {
        switch self {
        case .text:       return [.text, .html]
        case .image:      return [.image]
        case .screenshot: return [.screenshot]
        case .document:   return [.pdf, .doc, .docx, .xls, .xlsx, .numbers]
        }
    }
}

/// Shared chrome for every chip in the filter bar — kind chips, the app
/// picker, anything we add later. Guarantees they all line up at the
/// same height, corner radius, and selected-state contrast.
private extension View {
    /// `selectedFill` / `selectedText` default to the neutral scheme used
    /// by the mutually-exclusive kind chips. The Pinned chip overrides them
    /// with the brand accent so its distinct (exclusive-override) behaviour
    /// reads at a glance.
    func filterChipBackground(
        selected: Bool,
        selectedFill: AnyShapeStyle = AnyShapeStyle(Color.primary),
        selectedText: AnyShapeStyle = AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
    ) -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(selected
                        ? selectedFill
                        : AnyShapeStyle(.background.secondary)
                    )
            )
            .foregroundStyle(selected ? selectedText : AnyShapeStyle(.primary))
            .overlay(
                Capsule()
                    .strokeBorder(selected
                        ? AnyShapeStyle(.clear)
                        : AnyShapeStyle(.separator),
                        lineWidth: 1
                    )
            )
    }
}

/// Right pane for the Clipboard tab. Implements the Pencil-spec'd
/// timeline: search bar, filter chips, and a date-bucketed list of
/// cards where each row is (time gutter · rail · card). The rail's
/// 2-pt line connects consecutive dots to make reading order explicit;
/// the top-most item gets an accent-tinted border to mark it as the
/// most recent clip.
struct ClipboardContent: View {
    @Environment(AppContainer.self) private var container

    @State private var items: [ClipboardItem] = []
    @State private var searchResults: [SearchResult] = []
    @State private var kindFilter: KindFilterGroup? = nil
    @State private var pinnedOnly = false
    @State private var appFilter: SourceAppSummary? = nil
    @State private var fromDate: Date? = nil
    @State private var toDate: Date? = nil
    @State private var showDatePopover = false
    @State private var knownApps: [SourceAppSummary] = []
    @State private var totalCount: Int = 0
    @State private var debouncer: SearchDebouncer?
    @State private var currentQuery: String = ""
    @State private var isDropTargeted = false
    @State private var focusedItemID: String? = nil
    @FocusState private var scrollFocus: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            filterBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            itemList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⌘F → focus the search field. A zero-size hidden button is the
        // shortest path to a window-scoped shortcut in SwiftUI; the
        // button never renders but its `keyboardShortcut` modifier is
        // honoured as long as the view is in the responder chain.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .overlay(dropOverlay)
        .onDrop(
            of: [.fileURL, .image, .plainText],
            isTargeted: $isDropTargeted
        ) { providers in
            for provider in providers {
                handleDrop(provider)
            }
            return true
        }
        .task {
            setupDebouncer()
            await reloadItems()
        }
        .task { await subscribeToEvents() }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Color.accentColor.opacity(0.06)
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Drop to add to Clipz")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6]))
                )
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ provider: NSItemProvider) {
        // A card dragged within the timeline must never be re-imported
        // (that's the "card copies itself" bug). Primary signal: the
        // app-wide drag flag; secondary: the drag's own marker type.
        if container.internalDragInProgress
            || provider.registeredTypeIdentifiers.contains(InternalClipDrag.typeIdentifier) {
            container.internalDragInProgress = false
            return
        }

        // File URLs win — they're both the most common drop payload
        // and the richest (we can classify by extension).
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { await captureDroppedFile(url) }
            }
            return
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { str, _ in
                guard let str = str as? String, !str.isEmpty else { return }
                Task { await captureDroppedText(str) }
            }
            return
        }
        // Image raw data (drag from Preview's selection, etc.).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                guard let data else { return }
                Task { await captureDroppedImage(data: data, ext: "png") }
            }
        }
    }

    private func captureDroppedFile(_ url: URL) async {
        // Ignore self-drags: dragging a card a few points hands the list
        // back the clip's *own* media file. Re-importing it would create a
        // duplicate (capture only dedups against the last few seconds, so
        // an existing clip isn't caught). Anything already inside our media
        // store is, by definition, not a new external file.
        if isOwnMediaFile(url) { return }

        let kind = Self.kind(forExtension: url.pathExtension)
        let payload = ClassifiedPayload(
            kind: kind,
            data: .fileURL(url),
            originalName: url.lastPathComponent
        )
        _ = await container.clipboard.capture(payload)
    }

    private func isOwnMediaFile(_ url: URL) -> Bool {
        let mediaPath = container.fileStore.mediaDir.standardizedFileURL.path
        let dropped = url.standardizedFileURL.path
        return dropped == mediaPath || dropped.hasPrefix(mediaPath + "/")
    }

    private func captureDroppedText(_ text: String) async {
        let payload = ClassifiedPayload(
            kind: .text,
            data: .inlineText(text),
            searchPreview: String(text.prefix(500))
        )
        _ = await container.clipboard.capture(payload)
    }

    private func captureDroppedImage(data: Data, ext: String) async {
        let payload = ClassifiedPayload(
            kind: .image,
            data: .imageData(data, ext: ext)
        )
        _ = await container.clipboard.capture(payload)
    }

    /// Map a filename extension to the matching `ClipboardKind`. We
    /// lowercase in-place so `.PDF` and `.pdf` both classify the same.
    private static func kind(forExtension rawExt: String) -> ClipboardKind {
        switch rawExt.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "bmp", "tiff":
            return .image
        case "mov", "mp4", "m4v", "webm", "avi":
            return .video
        case "pdf":      return .pdf
        case "doc":      return .doc
        case "docx":     return .docx
        case "xls":      return .xls
        case "xlsx":     return .xlsx
        case "numbers":  return .numbers
        default:         return .pdf  // fallback routes unknown binaries through the "document" rendering
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField(
                "Search clipboard, OCR text, docs…",
                text: Binding(
                    get: { debouncer?.query ?? "" },
                    set: { debouncer?.query = $0 }
                )
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)

            if !(debouncer?.query.isEmpty ?? true) {
                Button {
                    debouncer?.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: 6) {
            filterChip(label: "All", group: nil)
            filterChip(label: "Text", group: .text, symbol: "textformat")
            filterChip(label: "Images", group: .image, symbol: "photo")
            filterChip(label: "Screenshots", group: .screenshot, symbol: "camera.viewfinder")
            filterChip(label: "Documents", group: .document, symbol: "doc.richtext")

            // Separate the mutually-exclusive *type* chips from the two
            // filters that work differently: Pinned (an exclusive override
            // that ignores the other filters) and App (a combinable picker).
            Divider()
                .frame(height: 15)
                .padding(.horizontal, 1)

            pinnedChip
            appFilterMenu
            dateFilterChip

            Spacer()

            Text(countLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Date filter

    /// A calendar chip that opens a From/To date picker. Both bounds are
    /// independent — set one, the other, or both.
    private var dateFilterChip: some View {
        Button {
            showDatePopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                Text(dateChipLabel)
                    .font(.system(size: 11, weight: dateRange == nil ? .regular : .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .filterChipBackground(selected: dateRange != nil)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
            datePopover
        }
        .accessibilityLabel("Date filter")
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter by date")
                .font(.headline)

            Toggle("From", isOn: Binding(
                get: { fromDate != nil },
                set: { on in
                    fromDate = on ? (fromDate ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())) : nil
                    Task { await reloadItems() }
                }
            ))
            if fromDate != nil {
                DatePicker("", selection: dateBinding($fromDate), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: 260)
            }

            Divider()

            Toggle("To", isOn: Binding(
                get: { toDate != nil },
                set: { on in
                    toDate = on ? (toDate ?? Date()) : nil
                    Task { await reloadItems() }
                }
            ))
            if toDate != nil {
                DatePicker("", selection: dateBinding($toDate), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: 260)
            }

            HStack {
                Button("Clear") {
                    fromDate = nil
                    toDate = nil
                    Task { await reloadItems() }
                }
                .disabled(dateRange == nil)
                Spacer()
                Button("Done") { showDatePopover = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Bridges an optional `Date?` @State to the non-optional `Date` a
    /// `DatePicker` needs, reloading on every change.
    private func dateBinding(_ source: Binding<Date?>) -> Binding<Date> {
        Binding(
            get: { source.wrappedValue ?? Date() },
            set: { source.wrappedValue = $0; Task { await reloadItems() } }
        )
    }

    private var dateChipLabel: String {
        let fmt = Date.FormatStyle.dateTime.month(.abbreviated).day()
        switch (fromDate, toDate) {
        case let (f?, t?): return "\(f.formatted(fmt)) – \(t.formatted(fmt))"
        case let (f?, nil): return "From \(f.formatted(fmt))"
        case let (nil, t?): return "Until \(t.formatted(fmt))"
        case (nil, nil):   return "Date"
        }
    }

    /// Whole-day range from the selected bounds (start-of-`from` … end-of-`to`),
    /// with an open end substituted by `distantPast`/`distantFuture`.
    private var dateRange: ClosedRange<Date>? {
        let cal = Calendar.current
        let lower = fromDate.map { cal.startOfDay(for: $0) }
        let upper = toDate.map {
            (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) ?? $0)
                .addingTimeInterval(-1)
        }
        switch (lower, upper) {
        case let (l?, u?): return l <= u ? l...u : u...l
        case let (l?, nil): return l...Date.distantFuture
        case let (nil, u?): return Date.distantPast...u
        case (nil, nil):    return nil
        }
    }

    /// Menu picker listing every distinct source app that's shown up
    /// in the user's history. Uses the same chip shape as the other
    /// filter pills so it visually sits in the same row.
    private var appFilterMenu: some View {
        let selected = appFilter != nil
        return Menu {
            Button {
                appFilter = nil
                Task { await reloadItems() }
            } label: {
                Label("All apps", systemImage: appFilter == nil ? "checkmark" : "")
            }

            if !knownApps.isEmpty {
                Divider()
                ForEach(knownApps, id: \.name) { summary in
                    Button {
                        appFilter = summary
                        Task { await reloadItems() }
                    } label: {
                        // Hand the menu a pre-sized NSImage so it renders a
                        // small inline glyph; a raw resizable icon view comes
                        // out oversized in a native menu.
                        Label {
                            Text("\(summary.name)  (\(summary.count))")
                        } icon: {
                            if let icon = AppIconView.menuIcon(
                                for: summary.bundleID, points: 14
                            ) {
                                Image(nsImage: icon)
                            } else {
                                Image(systemName: "app")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let active = appFilter {
                    // Match the chip's text x-height so the icon reads
                    // as a small inline glyph, not a prominent badge.
                    AppIconView(bundleID: active.bundleID, size: 13)
                    Text(active.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 11))
                    Text("App")
                        .font(.system(size: 11))
                }
                // Chevron marks this as a dropdown picker (it combines with
                // the kind chips), distinct from the toggle chips.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .filterChipBackground(selected: selected)
        }
        // `.button` + `.plain` strips the native menu-button chrome so the
        // capsule reads as the same pill as the kind chips. (`.borderlessButton`
        // drew its own control background over the capsule.)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var countLabel: String {
        let shown = displayedEntries.count
        return shown == totalCount
            ? "\(totalCount) clip\(totalCount == 1 ? "" : "s")"
            : "\(shown) of \(totalCount)"
    }

    private func filterChip(label: String, group: KindFilterGroup?, symbol: String? = nil) -> some View {
        let selected = kindFilter == group
        return Button {
            kindFilter = group
            Task { await reloadItems() }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .filterChipBackground(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var pinnedChip: some View {
        Button {
            pinnedOnly.toggle()
            Task { await reloadItems() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pinnedOnly ? "star.fill" : "star")
                    .font(.system(size: 11))
                    // Gold star in both states so the chip always reads as
                    // the odd-one-out "pinned" control, not another kind chip.
                    .foregroundStyle(pinnedOnly
                        ? AnyShapeStyle(Color.black)
                        : AnyShapeStyle(Color.clipzAccent))
                Text("Pinned")
                    .font(.system(size: 11, weight: pinnedOnly ? .semibold : .regular))
            }
            .filterChipBackground(
                selected: pinnedOnly,
                selectedFill: AnyShapeStyle(Color.clipzAccent),
                selectedText: AnyShapeStyle(Color.black)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pinned filter")
        .accessibilityAddTraits(pinnedOnly ? [.isSelected] : [])
    }

    @ViewBuilder
    private func rowContextMenu(for item: ClipboardItem) -> some View {
        Button(item.pinned ? "Unpin" : "Pin") {
            Task {
                try? await container.clipboard.setPinned(id: item.id, pinned: !item.pinned)
            }
        }
        Button("Delete", role: .destructive) {
            Task { try? await container.clipboard.delete(id: item.id) }
        }
    }

    // MARK: - Timeline list

    private var itemList: some View {
        Group {
            if displayedEntries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(groupedEntries.enumerated()), id: \.element.bucket) { sectionIndex, section in
                                sectionHeader(section)
                                ForEach(Array(section.entries.enumerated()), id: \.element.item.id) { idx, entry in
                                    TimelineRowView(
                                        item: entry.item,
                                        matches: entry.matches,
                                        isHighlighted: isRowHighlighted(
                                            entry.item.id,
                                            isFirstOverall: sectionIndex == 0 && idx == 0
                                        ),
                                        isLast: idx == section.entries.count - 1
                                    )
                                    .id(entry.item.id)
                                    .contextMenu { rowContextMenu(for: entry.item) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .focusable()
                    .focused($scrollFocus)
                    .focusEffectDisabled()
                    .onAppear { scrollFocus = true }
                    .onKeyPress(.pageDown) {
                        jumpFocus(by: 10, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.pageUp) {
                        jumpFocus(by: -10, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.home) {
                        jumpFocusToStart(proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.end) {
                        jumpFocusToEnd(proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        jumpFocus(by: -1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        jumpFocus(by: 1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        copyFocusedItem()
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        deleteFocusedItem()
                        return .handled
                    }
                }
            }
        }
    }

    // MARK: - Keyboard navigation

    /// The flat list in display order. Used by PageUp/PageDown math so
    /// we can step by N regardless of date-bucket boundaries.
    private var flatDisplayedItems: [ClipboardItem] {
        displayedEntries.map(\.item)
    }

    /// The keyboard-focused row is highlighted; before the user touches the
    /// keyboard, the most-recent row carries the default highlight.
    private func isRowHighlighted(_ id: String, isFirstOverall: Bool) -> Bool {
        if let focusedItemID { return focusedItemID == id }
        return isFirstOverall
    }

    private func jumpFocus(by offset: Int, proxy: ScrollViewProxy) {
        let items = flatDisplayedItems
        guard !items.isEmpty else { return }
        let currentIdx: Int = {
            if let id = focusedItemID,
               let idx = items.firstIndex(where: { $0.id == id }) {
                return idx
            }
            return 0
        }()
        let target = max(0, min(items.count - 1, currentIdx + offset))
        let id = items[target].id
        focusedItemID = id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: offset < 0 ? .top : .center)
        }
    }

    private func jumpFocusToStart(proxy: ScrollViewProxy) {
        guard let first = flatDisplayedItems.first else { return }
        focusedItemID = first.id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(first.id, anchor: .top)
        }
    }

    private func jumpFocusToEnd(proxy: ScrollViewProxy) {
        guard let last = flatDisplayedItems.last else { return }
        focusedItemID = last.id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /// ↩ on the focused row — copy it to the system pasteboard.
    private func copyFocusedItem() {
        guard let id = focusedItemID,
              let item = flatDisplayedItems.first(where: { $0.id == id }) else { return }
        Task {
            guard await container.ensureSensitiveAccess(to: item) else { return }
            await PasteboardWriter.write(
                item,
                fileStore: container.fileStore,
                watcher: container.clipboardWatcher
            )
        }
    }

    /// Delete (or Backspace) on the focused row — remove it, moving focus
    /// to the next row (or the previous one at the end of the list).
    private func deleteFocusedItem() {
        guard let id = focusedItemID else { return }
        let items = flatDisplayedItems
        if let idx = items.firstIndex(where: { $0.id == id }) {
            focusedItemID = (idx + 1 < items.count)
                ? items[idx + 1].id
                : (idx > 0 ? items[idx - 1].id : nil)
        }
        Task { try? await container.clipboard.delete(id: id) }
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(section.bucket.headerTitle(for: section.entries.first?.item.createdAt ?? .now))
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: currentQuery.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(currentQuery.isEmpty ? "Nothing captured yet" : "No matches")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(
                currentQuery.isEmpty
                    ? "Copy anything and it will appear here."
                    : "Try a different search or clear filters."
            )
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived items

    private var displayedEntries: [TimelineEntry] {
        if !currentQuery.isEmpty {
            return searchResults.map { TimelineEntry(item: $0.item, matches: $0.matches) }
        }
        return items.map { TimelineEntry(item: $0, matches: []) }
    }

    private var groupedEntries: [TimelineSection] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [TimeBucket: [TimelineEntry]] = [:]
        for entry in displayedEntries {
            buckets[TimeBucket.bucket(for: entry.item.createdAt, now: now, calendar: cal), default: []]
                .append(entry)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let rows = buckets[bucket], !rows.isEmpty else { return nil }
            return TimelineSection(bucket: bucket, entries: rows)
        }
    }

    // MARK: - Data plumbing

    private func setupDebouncer() {
        let onFire: @MainActor (String) -> Void = { query in
            Task { @MainActor in
                currentQuery = query
                if query.isEmpty {
                    searchResults = []
                    await reloadItems()
                } else {
                    let page = try? await container.searchEngine.search(
                        query: query,
                        kindFilter: kindFilter?.kinds,
                        dateRange: dateRange,
                        sourceAppName: appFilter?.name
                    )
                    searchResults = page?.results ?? []
                }
            }
        }
        debouncer = SearchDebouncer(onFire: onFire)
    }

    private func reloadItems() async {
        let kinds: Set<ClipboardKind>? = kindFilter?.kinds
        // Pinned composes with the kind + app filters rather than replacing
        // them: when it's on, we still narrow the pinned set by whatever
        // type / app the user has selected.
        let list = (try? await container.clipboard.fetchPage(
            limit: 200,
            kindFilter: kinds,
            dateRange: dateRange,
            sourceAppName: appFilter?.name,
            pinnedOnly: pinnedOnly
        )) ?? []
        let total = (try? await container.clipboard.countItems()) ?? 0
        let apps = (try? await container.clipboard.fetchUniqueSourceApps()) ?? []
        await MainActor.run {
            self.items = list
            self.totalCount = total
            self.knownApps = apps
        }

        // If we're searching, rerun the search with the new filter, then
        // keep only pinned hits when the Pinned filter is active (the FTS
        // engine has no pinned predicate, so narrow it here).
        if !currentQuery.isEmpty {
            let page = try? await container.searchEngine.search(
                query: currentQuery,
                kindFilter: kinds,
                dateRange: dateRange,
                sourceAppName: appFilter?.name
            )
            var results = page?.results ?? []
            if pinnedOnly {
                results = results.filter { $0.item.pinned }
            }
            await MainActor.run {
                self.searchResults = results
            }
        }
    }

    private func subscribeToEvents() async {
        let stream = await container.broadcaster.events()
        for await _ in stream {
            await reloadItems()
        }
    }
}

// MARK: - Timeline row

/// One `(time gutter · rail · card)` row. The rail extends below the
/// dot so consecutive rows look connected; the last row in a section
/// gets a shorter tail.
private struct TimelineRowView: View {
    let item: ClipboardItem
    let matches: [SearchResult.Match]
    let isHighlighted: Bool
    let isLast: Bool

    private static let absoluteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            timeGutter
                .frame(width: 70, alignment: .trailing)

            rail
                .frame(width: 20)

            ClipboardRow(item: item, matches: matches, highlighted: isHighlighted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Self.absoluteTimeFormatter.string(from: item.createdAt))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: .now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            dot
                .padding(.top, 8)
            Rectangle()
                .fill(.separator)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .opacity(isLast ? 0 : 1)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var dot: some View {
        if isHighlighted {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2)
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 3)
        } else {
            Circle()
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .strokeBorder(.tertiary, lineWidth: 2)
                )
        }
    }
}

// MARK: - Timeline grouping

private struct TimelineSection {
    let bucket: TimeBucket
    let entries: [TimelineEntry]
}

private enum TimeBucket: Int, CaseIterable, Hashable {
    case today, yesterday, thisWeek, earlier

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    func headerTitle(for date: Date) -> String {
        let suffix = Self.dateFormatter.string(from: date)
        let label: String
        switch self {
        case .today:     label = "TODAY"
        case .yesterday: label = "YESTERDAY"
        case .thisWeek:  label = "THIS WEEK"
        case .earlier:   label = "EARLIER"
        }
        return "\(label)  ·  \(suffix)"
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar) -> TimeBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let sameWeek = calendar.component(.weekOfYear, from: date)
            == calendar.component(.weekOfYear, from: now)
            && calendar.component(.yearForWeekOfYear, from: date)
                == calendar.component(.yearForWeekOfYear, from: now)
        return sameWeek ? .thisWeek : .earlier
    }
}
