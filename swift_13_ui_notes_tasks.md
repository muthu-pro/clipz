# swift_13 — UI: Notes and Tasks

## Purpose

Two small but distinct UI modules: **Notes** (rich-text note taking) and **Tasks** (simple todo list). They live alongside the clipboard view but are entirely independent in data and UI. Replaces `src/pages/NotesListPage.tsx`, `src/pages/NoteEditorPage.tsx`, `src/pages/TodoPage.tsx`, `src/components/NoteEditorPlain.tsx`, `src/components/NotesSidebar.tsx`, and the todo components.

## Current Electron behavior

### Notes
- List sidebar + editor detail (react-router nested `/notes/:id`).
- Editor is a custom "plain" rich text surface (`NoteEditorPlain.tsx`) — blocks: heading/paragraph/list/quote/code.
- Storage: `content_json` (block structure) + `content_text` (for FTS search).
- Create/read/update/delete/search via IPC (7 handlers).
- Welcome note seeded on first launch.
- Search via `notes_fts` with porter tokenizer.

### Tasks
- Single `/todo` page, very simple.
- Add/toggle/delete; no due dates, no projects.
- localStorage → DB one-time migration (legacy tasks pre-DB).
- 4 IPC handlers.

## Swift design

### Notes — data model recap

(from swift_06)

```swift
public struct Note: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var title: String?
    public var contentJSON: NoteContent     // structured blocks
    public var contentText: String          // searchable plain text
    public let createdAt: Date
    public var updatedAt: Date
}
```

### Notes service

```swift
public actor NotesService {
    private let database: AppDatabase
    private let broadcaster = EventBroadcaster()

    public func fetchAll() async throws -> [Note] {
        try await database.read { db in
            try Note.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> Note? {
        try await database.read { db in try Note.fetchOne(db, key: id) }
    }

    public func create(title: String?, contentJSON: NoteContent, contentText: String) async throws -> Note {
        let now = Date()
        let note = Note(id: UUID().uuidString, title: title,
                        contentJSON: contentJSON, contentText: contentText,
                        createdAt: now, updatedAt: now)
        try await database.write { db in try note.toRow().insert(db) }
        await broadcaster.emit(.noteCreated(note))
        return note
    }

    public func update(_ note: Note) async throws {
        var copy = note
        copy.updatedAt = Date()
        try await database.write { db in try copy.toRow().update(db) }
        await broadcaster.emit(.noteUpdated(copy))
    }

    public func delete(id: String) async throws {
        _ = try await database.write { db in try NoteRow.deleteOne(db, key: id) }
        await broadcaster.emit(.noteDeleted(id: id))
    }

    public func search(query: String) async throws -> [Note] {
        try await NotesSearchEngine(database: database).search(query: query, limit: 100)
    }

    public func seedWelcomeNoteIfFirstLaunch() async { … }
}
```

### Notes view hierarchy

```
NotesRootView                 (NavigationSplitView)
├── NotesSidebarView          (list + search + "New")
│     └── NoteSummaryRow      (title + excerpt + timestamp)
└── NoteEditorView            (title field + NSTextView-backed editor)
      ├── NoteEditorToolbar   (bold/italic/list/heading)
      └── NoteTextEditor      (NSViewRepresentable → NSTextView)
```

### NotesRootView

```swift
public struct NotesRootView: View {
    @Environment(AppContainer.self) private var container
    @State private var notes: [Note] = []
    @State private var selectedID: String?
    @State private var searchText: String = ""

    public var body: some View {
        NavigationSplitView {
            NotesSidebarView(
                notes: filteredNotes,
                selectedID: $selectedID,
                searchText: $searchText,
                onNew: createNew
            )
            .frame(minWidth: 220)
        } detail: {
            if let id = selectedID,
               let note = notes.first(where: { $0.id == id }) {
                NoteEditorView(initial: note, onSave: save)
                    .id(id)
            } else {
                ContentUnavailableView("Select a note", systemImage: "note.text")
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .openNote)) { n in
            if let id = n.object as? String { selectedID = id }
        }
    }

    private var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? notes : notes.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(q) ||
            $0.contentText.localizedCaseInsensitiveContains(q)
        }
    }

    private func load() async {
        notes = (try? await container.notesService.fetchAll()) ?? []
    }

    private func createNew() {
        Task {
            let new = try? await container.notesService.create(
                title: nil, contentJSON: .document(blocks: []), contentText: "")
            if let new {
                notes.insert(new, at: 0)
                selectedID = new.id
            }
        }
    }

    private func save(_ note: Note) {
        Task {
            try? await container.notesService.update(note)
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        }
    }
}
```

**Search strategy**: for in-memory lists ≤ 1,000 notes, client-side `contains` is faster than a DB FTS round-trip. For larger collections, switch to `container.notesService.search(query:)`. The split point is in the view model — easy to tune later.

### NotesSidebarView

```swift
struct NotesSidebarView: View {
    let notes: [Note]
    @Binding var selectedID: String?
    @Binding var searchText: String
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search notes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button(action: onNew) { Image(systemName: "square.and.pencil") }
            }
            .padding(8)
            List(selection: $selectedID) {
                ForEach(notes) { note in
                    NoteSummaryRow(note: note)
                        .tag(note.id)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct NoteSummaryRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title?.isEmpty == false ? note.title! : "Untitled").bold()
            Text(note.contentText.prefix(120))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
```

### NoteEditorView

```swift
struct NoteEditorView: View {
    let initial: Note
    let onSave: (Note) -> Void

    @State private var title: String
    @State private var attributed: AttributedString

    init(initial: Note, onSave: @escaping (Note) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _title = State(initialValue: initial.title ?? "")
        _attributed = State(initialValue:
            NoteAttributedStringConverter.from(content: initial.contentJSON))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16).padding(.top, 16)
                .onChange(of: title, debounce: .milliseconds(500)) { save() }
            NoteEditorToolbar(attributed: $attributed)
            Divider()
            NoteTextEditor(attributed: $attributed)
                .onChange(of: attributed, debounce: .milliseconds(500)) { save() }
        }
    }

    private func save() {
        let contentText = String(attributed.characters)
        let contentJSON = NoteAttributedStringConverter.to(attributed: attributed)
        var next = initial
        next.title = title.isEmpty ? nil : title
        next.contentJSON = contentJSON
        next.contentText = contentText
        onSave(next)
    }
}
```

*Pseudocode `onChange(of:debounce:)`* — Real implementation wraps a `Task`:

```swift
extension View {
    func onChange<V: Equatable>(of value: V, debounce: Duration, perform: @escaping () -> Void)
        -> some View {
        self.modifier(DebouncedChange(value: value, duration: debounce, action: perform))
    }
}
```

### NoteTextEditor — NSTextView bridge

SwiftUI's built-in `TextEditor` doesn't support rich attributes well on macOS 14. Bridge to `NSTextView`:

```swift
struct NoteTextEditor: NSViewRepresentable {
    @Binding var attributed: AttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textStorage?.setAttributedString(NSAttributedString(attributed))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        let current = AttributedString(tv.attributedString())
        if current != attributed {
            let ns = NSAttributedString(attributed)
            tv.textStorage?.setAttributedString(ns)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(attributed: $attributed) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let attributed: Binding<AttributedString>
        init(attributed: Binding<AttributedString>) { self.attributed = attributed }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            attributed.wrappedValue = AttributedString(tv.attributedString())
        }
    }
}
```

### Toolbar

```swift
struct NoteEditorToolbar: View {
    @Binding var attributed: AttributedString

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { toggle(.bold) }) { Image(systemName: "bold") }
            Button(action: { toggle(.italic) }) { Image(systemName: "italic") }
            Button(action: { toggle(.underlineStyle) }) { Image(systemName: "underline") }
            Divider().frame(height: 16)
            Button(action: { makeHeading(level: 1) }) { Image(systemName: "h.square") }
            Button(action: { makeList(ordered: false) }) { Image(systemName: "list.bullet") }
            Button(action: { makeList(ordered: true) }) { Image(systemName: "list.number") }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func toggle(_ attr: AttributeScopes.SwiftUIAttributes.InlinePresentationIntentAttribute) {
        // Implementation: modify attributed bindings at current selection
    }
    // Additional helpers for heading/list/code etc.
}
```

The toolbar is driven by `AttributedString`; on apply, it mutates the binding which the NSTextView bridge picks up. Selection state lives in the coordinator.

### Attributed string ⇄ NoteContent conversion

```swift
// Packages/ClipzUI/Sources/ClipzUI/Notes/NoteAttributedStringConverter.swift

enum NoteAttributedStringConverter {
    static func from(content: NoteContent) -> AttributedString { … }
    static func to(attributed: AttributedString) -> NoteContent { … }
}
```

Mapping rules:

- Heading level → `AttributedString` with font size delta (24pt for h1, 20pt for h2, 17pt for h3).
- Bold / italic / underline / strikethrough → `.inlinePresentationIntent`.
- Link → `.link` (URL).
- List → wrap inline runs with block-level paragraph-style attributes; on to-JSON we detect the paragraph style to reconstruct list blocks.
- Code block → monospaced font + background color + paragraph indent.

This gives round-trip fidelity for the common cases. Exotic formatting may lose on round-trip — acceptable.

## Tasks

### Data model

`TodoItem` (renamed from `Task` to avoid collision with `Swift.Task`):

```swift
public struct TodoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var text: String
    public var completed: Bool
    public let createdAt: Date
}
```

### Tasks service

```swift
public actor TasksService {
    private let database: AppDatabase

    public func fetchAll() async throws -> [TodoItem] {
        try await database.read { db in
            try TodoRow.order(Column("createdAt").desc).fetchAll(db).map(TodoItem.init(row:))
        }
    }

    public func create(text: String) async throws -> TodoItem {
        let item = TodoItem(id: UUID().uuidString, text: text, completed: false, createdAt: .now)
        try await database.write { db in try item.toRow().insert(db) }
        return item
    }

    public func update(_ item: TodoItem) async throws {
        try await database.write { db in try item.toRow().update(db) }
    }

    public func delete(id: String) async throws {
        try await database.write { db in try TodoRow.deleteOne(db, key: id) }
    }
}
```

### Tasks view

```swift
public struct TasksRootView: View {
    @Environment(AppContainer.self) private var container
    @State private var items: [TodoItem] = []
    @State private var newText: String = ""

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Add a task and press Return", text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add", action: add)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            List {
                ForEach(items) { item in
                    TodoRow(item: item,
                            onToggle: { toggle(item) },
                            onDelete: { delete(item) })
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        items = (try? await container.tasksService.fetchAll()) ?? []
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            if let new = try? await container.tasksService.create(text: text) {
                items.insert(new, at: 0)
                newText = ""
            }
        }
    }

    private func toggle(_ item: TodoItem) {
        var next = item; next.completed.toggle()
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = next }
        Task { try? await container.tasksService.update(next) }
    }

    private func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
        Task { try? await container.tasksService.delete(id: item.id) }
    }
}

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: item.completed ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            Text(item.text)
                .strikethrough(item.completed, color: .secondary)
                .foregroundStyle(item.completed ? .secondary : .primary)
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}
```

### Navigation

Integrated into the main window as a tab/sidebar:

```swift
struct MainTabView: View {
    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Clipboard", value: Tab.clipboard)
                NavigationLink("Notes", value: Tab.notes)
                NavigationLink("Tasks", value: Tab.tasks)
            }
        } detail: {
            switch selected {
            case .clipboard: ClipboardRootView()
            case .notes:     NotesRootView()
            case .tasks:     TasksRootView()
            }
        }
    }
}
```

Matches the current Electron app's left-sidebar navigation.

## Edge cases & gotchas

### Notes

1. **Concurrent edits during save** — user typing while debounced save runs. The coordinator captures the latest `attributed` value each textDidChange; the save is already debounced at 500ms. Acceptable.

2. **Empty note cleanup** — if the user creates a new note and closes without typing anything, the note row lingers. On note list load, optionally filter out notes with `contentText.isEmpty && title?.isEmpty == true` and offer a "Clear empty notes" button.

3. **Undo across switch** — `NSTextView` has built-in undo stack per text storage. Switching notes replaces the text storage, discarding undo. Acceptable (matches typical note apps).

4. **Keyboard shortcuts in NSTextView** — `Cmd+B`, `Cmd+I`, `Cmd+U` work natively via NSResponder chain. Override only if we need to bypass them (e.g., Cmd+B does something else globally when a note isn't focused — don't).

5. **Content_text drift** — `contentText` is derived from `attributed`; if we forget to update it on save, FTS goes stale. Centralize derivation in the save function.

6. **Title from first heading** — if title is empty, fall back to the first line/heading of the content for display in the sidebar. Don't mutate the note.

7. **Welcome note content** — bundled as a markdown-like block tree constant; seeded once on first launch (swift_02).

8. **Large notes** — notes with 50k+ characters can make NSTextView laggy on typing. macOS `NSTextView` handles it; mitigated by its incremental layout.

### Tasks

1. **Duplicate adds** — rapid Enter presses can add twice. Debounce the add action; also clear `newText` synchronously on submit.

2. **Completed at top or bottom?** — sort by `createdAt DESC`. Completed items stay in place. Future enhancement: optional "move completed to bottom" setting.

3. **Task text edit** — v1 doesn't allow editing existing task text (add + delete + re-add workflow). v1.1 adds inline edit via double-tap.

4. **No bulk actions for now** — "delete all completed" button nice but defer.

## MAS notes

- `NSTextView` — sandbox-compatible.
- All services hit SQLite in-container; no sandbox concerns.
- No external services (Apple Notes import, iCloud sync) in v1.

## Open questions

- **Markdown export** — users often want "export note as .md". Easy to add via `NoteMarkdownConverter.toMarkdown(content:)`. Flag for v1.1.
- **Pinned tasks** — not in v1.
- **Task categories/tags** — not in v1.
- **Rich editor autosave conflict resolution** — with 500ms debounce, the last write wins per-field. Single-device app; no real conflict risk.
