# swift_12 — UI: Clipboard View

## Purpose

The main clipboard browser: list (or grid) of items, search, filters, per-item rendering, selection, keyboard shortcuts, context menus, OCR match highlighting on images. This view replaces `src/pages/ClipboardPage.tsx` (~5,500 lines) — **the monolith** — broken into focused SwiftUI components.

## Current Electron behavior — features to preserve

From WARP.md and exploration of `ClipboardPage.tsx`:

- Infinite scroll (50 items/page) via IntersectionObserver on sentinel.
- Live search with trigram/porter routing, highlight markup via `innerHTML <mark>`.
- Search triggers a different fetch mode (all results returned at once, no pagination).
- Filters: type (11 kinds), date range, source app multi-select.
- Keyboard shortcuts:
  - **Cmd+F** — focus search, pulse animation.
  - **Cmd+Shift+D** — copy hovered item to Desktop.
  - **Esc** — close preview/context menu.
  - **Double-Backspace** when search is empty — reset everything.
- Context menu: Copy / Copy to Desktop / Reanalyze / Delete.
- Per-type rendering: text, image, screenshot, html, video (with AVPlayer), pdf (with PDFView), doc/docx/xls/xlsx/numbers (icon + name).
- OCR match bounding boxes overlaid on images when search has a hit inside.
- Lazy media loading via `file://` URLs through `getFileUrl` IPC.
- Selection state: expanded item details, preview modal.

## Swift design

### Decomposition

Break into focused files — no one file over 500 lines:

```
Packages/ClipzUI/Sources/ClipzUI/Clipboard/
├── ClipboardRootView.swift          # top-level scene, owns view model
├── ClipboardViewModel.swift         # @Observable state holder
├── ClipboardListView.swift          # List (sections by date)
├── ClipboardItemCell.swift          # dispatches to type-specific renderer
├── Renderers/
│   ├── TextItemRenderer.swift
│   ├── HTMLItemRenderer.swift
│   ├── ImageItemRenderer.swift       # handles image + screenshot
│   ├── VideoItemRenderer.swift       # AVKit
│   ├── PDFItemRenderer.swift         # PDFKit
│   └── DocumentItemRenderer.swift    # generic doc icon + name
├── Search/
│   ├── SearchBar.swift
│   ├── SearchHighlight.swift         # HighlightedString → Text converter
│   └── OCRBoxOverlay.swift
├── Filters/
│   ├── FilterPanel.swift
│   ├── KindFilterChip.swift
│   ├── AppFilterMenu.swift
│   └── DateRangePicker.swift
├── ContextMenu/
│   └── ClipboardContextMenu.swift
└── Preview/
    └── ItemPreviewSheet.swift
```

### View model

```swift
// Packages/ClipzUI/Sources/ClipzUI/Clipboard/ClipboardViewModel.swift
import Observation
import ClipzCore

@MainActor
@Observable
public final class ClipboardViewModel {
    // Data
    public private(set) var items: [ClipboardItem] = []
    public private(set) var searchResults: [SearchResult]?
    public private(set) var sourceApps: [SourceAppSummary] = []
    public private(set) var hasMore: Bool = true
    public private(set) var isLoading: Bool = false
    public private(set) var isSearching: Bool = false

    // Filters / search
    public var searchText: String = ""
    public var selectedKinds: Set<ClipboardKind> = []
    public var selectedApps: Set<String> = []
    public var dateRange: ClosedRange<Date>? = nil

    // Selection / UI state
    public var focusedItemID: String? = nil
    public var expandedItemID: String? = nil
    public var contextMenuItemID: String? = nil

    private let service: ClipboardService
    private let pageSize = 50
    private var searchDebouncer: Task<Void, Never>?

    public init(service: ClipboardService) {
        self.service = service
        Task { await initialLoad() }
    }

    public func initialLoad() async {
        sourceApps = (try? await service.fetchUniqueSourceApps()) ?? []
        await loadNextPage()
        Task { await observeBroadcaster() }
    }

    public func loadNextPage() async {
        guard !isLoading, hasMore, searchResults == nil else { return }
        isLoading = true
        defer { isLoading = false }
        let next = (try? await service.fetchPage(
            limit: pageSize,
            offset: items.count,
            kindFilter: selectedKinds.isEmpty ? nil : selectedKinds,
            dateRange: dateRange,
            sourceAppFilter: selectedApps.isEmpty ? nil : selectedApps
        )) ?? []
        hasMore = next.count == pageSize
        items.append(contentsOf: next)
    }

    public func resetAndReload() async {
        items = []
        hasMore = true
        searchResults = nil
        await loadNextPage()
    }

    // MARK: - Search

    public func onSearchTextChanged() {
        searchDebouncer?.cancel()
        searchDebouncer = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        let page = try? await service.search(
            query: q, limit: 200, offset: 0,
            kindFilter: selectedKinds.isEmpty ? nil : selectedKinds,
            dateRange: dateRange
        )
        searchResults = page?.results
    }

    // MARK: - Broadcaster

    private func observeBroadcaster() async {
        for await event in await service.broadcaster.events() {
            switch event {
            case .captured(let item):
                if searchResults == nil {
                    items.insert(item, at: 0)
                }
            case .deleted(let id):
                items.removeAll { $0.id == id }
                searchResults?.removeAll { $0.id == id }
            case .manyDeleted(let ids):
                let set = Set(ids)
                items.removeAll { set.contains($0.id) }
                searchResults?.removeAll { set.contains($0.id) }
            case .updated, .analysisUpdated:
                // For updated: fetch the new version. For analysis: re-render.
                break
            }
        }
    }
}
```

### Root view

```swift
public struct ClipboardRootView: View {
    @Environment(AppContainer.self) private var container
    @State private var vm: ClipboardViewModel?

    public var body: some View {
        Group {
            if let vm {
                VStack(spacing: 0) {
                    SearchBar(text: Binding(get: { vm.searchText },
                                            set: { vm.searchText = $0; vm.onSearchTextChanged() }),
                              isSearching: vm.isSearching)
                    FilterPanel(vm: vm)
                    Divider()
                    ClipboardListView(vm: vm)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            vm = ClipboardViewModel(service: container.clipboardService)
        }
        .sheet(item: Binding(get: {
            vm?.expandedItemID.map { IdentifiedString(id: $0) }
        }, set: { _ in vm?.expandedItemID = nil })) { id in
            ItemPreviewSheet(itemID: id.id)
        }
    }
}
```

### List view with sections

```swift
struct ClipboardListView: View {
    @Bindable var vm: ClipboardViewModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { vm.focusedItemID },
                                    set: { vm.focusedItemID = $0 })) {
                if let results = vm.searchResults {
                    ForEach(results) { result in
                        ClipboardItemCell(item: result.item, match: result.matches.first)
                            .id(result.id)
                    }
                } else {
                    ForEach(Self.grouped(vm.items), id: \.key) { section in
                        Section(header: DateSectionHeader(label: section.key)) {
                            ForEach(section.value) { item in
                                ClipboardItemCell(item: item, match: nil)
                                    .id(item.id)
                                    .task {
                                        // Load more when the near-bottom cell appears
                                        if item.id == vm.items.last?.id {
                                            await vm.loadNextPage()
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .highlightItem)) { note in
                guard let id = note.object as? String else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                vm.focusedItemID = id
            }
        }
    }

    static func grouped(_ items: [ClipboardItem]) -> [(key: String, value: [ClipboardItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item in
            DateSectionHeader.label(for: item.createdAt, calendar: calendar)
        }
        // Preserve display order: Today, Yesterday, This Week, Earlier
        let order = ["Today", "Yesterday", "This Week", "Earlier"]
        return order.compactMap { key in
            guard let v = grouped[key] else { return nil }
            return (key, v.sorted { $0.createdAt > $1.createdAt })
        }
    }
}
```

**Infinite scroll** replaces IntersectionObserver with `.task { await vm.loadNextPage() }` on the last item. SwiftUI calls this only once as the row first appears; when the user scrolls back up and down, additional calls don't re-fetch because `hasMore` + offset tracking prevent duplicates.

### Item cell

```swift
struct ClipboardItemCell: View {
    let item: ClipboardItem
    let match: SearchResult.Match?

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: item.sourceApp?.bundleID)
                .frame(width: 18, height: 18)
            renderer
            Spacer()
            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contextMenu { ClipboardContextMenu(item: item) }
        .onTapGesture(count: 2) { expand() }
        .onDrag { DragProviderBuilder.provider(for: item) }
    }

    @ViewBuilder private var renderer: some View {
        switch item.kind {
        case .text:                  TextItemRenderer(item: item, match: match)
        case .html:                  HTMLItemRenderer(item: item, match: match)
        case .image, .screenshot:    ImageItemRenderer(item: item, match: match)
        case .video:                 VideoItemRenderer(item: item)
        case .pdf:                   PDFItemRenderer(item: item)
        case .doc, .docx,
             .xls, .xlsx, .numbers:  DocumentItemRenderer(item: item)
        }
    }

    private func expand() {
        NotificationCenter.default.post(name: .expandItem, object: item.id)
    }
}
```

### Type-specific renderers

#### Text

```swift
struct TextItemRenderer: View {
    let item: ClipboardItem
    let match: SearchResult.Match?

    var body: some View {
        if let match {
            Text(HighlightedString.parse(match.snippet).attributed)
                .lineLimit(3)
        } else {
            Text(item.searchPreview ?? item.content)
                .lineLimit(3)
        }
    }
}
```

#### Image

```swift
struct ImageItemRenderer: View {
    @Environment(AppContainer.self) private var container
    let item: ClipboardItem
    let match: SearchResult.Match?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let bbox = match?.bbox {
                        OCRBoxOverlay(bbox: bbox)
                    }
                }
            if let match, case .ocrText = match.source {
                Text(HighlightedString.parse(match.snippet).attributed)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        let url = FileStore.shared.mediaURL(for: item.content)
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure:          Image(systemName: "photo").foregroundStyle(.secondary)
            default:                Color.gray.opacity(0.2)
            }
        }
    }
}
```

#### PDF

```swift
struct PDFItemRenderer: View {
    let item: ClipboardItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 48, height: 64)
                .overlay(Image(systemName: "doc.richtext").font(.title2), alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalName ?? "PDF").bold()
                if let pages = item.mediaInfo?.pageCount {
                    Text("\(pages) pages").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let thumbName = item.mediaInfo?.thumbnailFilename {
            let url = FileStore.shared.mediaURL(for: thumbName)
            AsyncImage(url: url) { $0.resizable().scaledToFit() }
            placeholder: { Color.gray.opacity(0.2) }
        } else {
            Color.gray.opacity(0.2)
        }
    }
}
```

#### Video

```swift
import AVKit

struct VideoItemRenderer: View {
    let item: ClipboardItem
    @State private var player: AVPlayer?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let p = player {
                    VideoPlayer(player: p)
                        .onDisappear { player?.pause() }
                } else {
                    Color.black
                }
            }
            .frame(width: 80, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(item.originalName ?? "Video")
        }
        .task {
            let url = FileStore.shared.mediaURL(for: item.content)
            player = AVPlayer(url: url)
        }
    }
}
```

**Note**: video playback inline is heavy. Consider only rendering a still-frame thumbnail in the list and loading AVPlayer in the detail/preview sheet.

### Search bar

```swift
struct SearchBar: View {
    @Binding var text: String
    var isSearching: Bool
    @FocusState private var focused: Bool
    @State private var glow = false

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clips, text in images, documents…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(glow ? Color.accentColor : .clear, lineWidth: 2))
        .animation(.easeOut(duration: 0.25), value: glow)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            focused = true
            glow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { glow = false }
        }
    }
}
```

### Filter panel

```swift
struct FilterPanel: View {
    @Bindable var vm: ClipboardViewModel

    var body: some View {
        HStack(spacing: 8) {
            KindFilterChip(selected: Binding(get: { vm.selectedKinds },
                                             set: { vm.selectedKinds = $0
                                                    Task { await vm.resetAndReload() } }))
            AppFilterMenu(options: vm.sourceApps,
                          selected: Binding(get: { vm.selectedApps },
                                            set: { vm.selectedApps = $0
                                                    Task { await vm.resetAndReload() } }))
            DateRangePicker(range: Binding(get: { vm.dateRange },
                                            set: { vm.dateRange = $0
                                                    Task { await vm.resetAndReload() } }))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
```

### Context menu

```swift
struct ClipboardContextMenu: View {
    @Environment(AppContainer.self) private var container
    let item: ClipboardItem

    var body: some View {
        Button("Copy") {
            Task { await container.pasteEngine.writeItemToPasteboard(item, forcePlainText: false) }
        }
        Button("Copy as Plain Text") {
            Task { await container.pasteEngine.writeItemToPasteboard(item, forcePlainText: true) }
        }
        Button("Paste into Previous App") {
            Task { try? await container.pasteEngine.paste(item) }
        }
        Divider()
        Button("Copy to Desktop…") {
            Task { await container.pasteEngine.copyToDesktop(item: item) }
        }
        if item.kind.isMedia {
            Button("Reveal in Finder") {
                let url = FileStore.shared.mediaURL(for: item.content)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        if item.kind == .image || item.kind == .screenshot || item.kind == .pdf {
            Button("Reanalyze") {
                Task { await container.analysisService.reanalyze(itemID: item.id) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { try? await container.clipboardService.delete(id: item.id) }
        }
    }
}
```

### Keyboard shortcuts (app-level)

Registered in `ClipzCommands` (swift_02); each broadcasts a `NotificationCenter` event that views observe:

```swift
extension Notification.Name {
    static let focusSearch        = Notification.Name("focusSearch")
    static let copyHoveredToDesktop = Notification.Name("copyHoveredToDesktop")
    static let highlightItem      = Notification.Name("highlightItem")
    static let expandItem         = Notification.Name("expandItem")
    static let openNote           = Notification.Name("openNote")
}
```

**Double-Backspace to reset** — add a handler on the SearchBar's TextField:

```swift
TextField("…", text: $text)
    .onKeyPress(.delete) { press in
        if text.isEmpty, backspaceTapTime.map({ Date().timeIntervalSince($0) < 0.3 }) ?? false {
            Task { await vm.resetAndReload() }
            backspaceTapTime = nil
            return .handled
        }
        backspaceTapTime = Date()
        return .ignored
    }
```

### OCR bounding-box overlay

```swift
struct OCRBoxOverlay: View {
    let bbox: BoundingBox

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 2)
                .background(Color.yellow.opacity(0.2))
                .frame(width: geo.size.width * bbox.width,
                       height: geo.size.height * bbox.height)
                .position(x: geo.size.width * (bbox.x + bbox.width / 2),
                          y: geo.size.height * (bbox.y + bbox.height / 2))
        }
    }
}
```

### Preview sheet

Full-resolution preview (image/video/PDF full render) triggered by double-click or context-menu → "Preview":

```swift
struct ItemPreviewSheet: View {
    let itemID: String
    @Environment(AppContainer.self) private var container
    @State private var item: ClipboardItem?

    var body: some View {
        Group {
            if let item {
                switch item.kind {
                case .image, .screenshot: ImagePreview(url: fileURL(item))
                case .pdf:                PDFPreview(url: fileURL(item))
                case .video:              VideoPreview(url: fileURL(item))
                default:                  TextPreview(item: item)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { item = try? await container.clipboardService.fetchItem(id: itemID) }
    }
}
```

## Edge cases & gotchas

1. **Large search result sets** — fetching 200 results isn't much memory, but rendering 200 SwiftUI cells is. Use `LazyVStack` or `List` (which is lazy on macOS 14); default `List` suffices.

2. **Jittery infinite scroll when a capture arrives** — appending a new item at offset 0 pushes the list down; if the user is mid-scroll this feels jarring. Mitigation: only insert new items at top when the list is scrolled to the top (detect via `ScrollViewReader`). Otherwise queue and show a "New items" floating button.

3. **Sort order with grouped sections** — sorted by `createdAt DESC` across sections; within a section by date. Grouping label assignment happens in `grouped(_:)`; if an item falls on a boundary (e.g., 23:59 yesterday), rounding is by `Calendar.startOfDay`.

4. **Deleting the focused item** — if `vm.focusedItemID == deletedID`, advance focus to the next item automatically.

5. **Same item displayed twice across search/list modes** — view model is careful: `searchResults != nil` → show only results; else → show `items`. Switching modes doesn't duplicate rendering.

6. **Relative time label freshness** — `Text(date, format: .relative)` does *not* auto-refresh. Attach a timer that invalidates the view state every 60 s, or use `.timerInterval` style when appropriate.

7. **Media load failures** — `AsyncImage` handles missing/corrupt gracefully. Logs the error for diagnostics.

8. **Drag from a search-result cell** — need the source `ClipboardItem`, not just the match. `ClipboardItemCell` carries both; `DragProviderBuilder.provider(for: item)` handles it.

9. **HTML item rendering** — in-list: render the `searchPreview` (plain). In preview: render via `WKWebView` in a `NSViewRepresentable`, OR `NSAttributedString(data:options:documentAttributes:)` if you don't need live JS. Prefer AttributedString for performance and sandbox safety.

10. **Playback of video items** — lazy via AVKit; ensure `AVPlayer` is paused when the cell scrolls out (`.onDisappear`).

11. **List selection vs item focus** — SwiftUI `List(selection:)` binds selected rows. We use it as the UI focus indicator.

12. **Accessibility** — each cell needs an `.accessibilityLabel` describing the item ("Image copied from Safari 5 minutes ago, 4 objects detected"). Implemented per renderer.

## MAS notes

- `AsyncImage` with a `file://` URL inside our container: sandbox-compatible.
- `AVPlayer` with container URLs: sandbox-compatible.
- `NSWorkspace.shared.activateFileViewerSelecting`: sandbox-compatible.
- `PDFView` (PDFKit): sandbox-compatible.
- All pasteboard writes/reads: sandbox-compatible (same as swift_10).

## Open questions

- **Grid vs list layout** — current Electron app uses a list. Users with lots of screenshots may prefer a grid. Add a layout toggle in v1.1.
- **Item pinning** — "favorite" items that never age out. Out of v1 scope.
- **Bulk select + actions** — Cmd-click to multi-select, then delete / copy all. Part of v1? Useful but scope. Flag for v1.1.
- **Keyboard navigation within the list** — arrow keys to move focus, Enter to paste, Delete to delete. Wire up via `onKeyPress` on the list.
