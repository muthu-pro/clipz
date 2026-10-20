// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import ClipzCore

/// A Spotlight-style quick-paste panel summoned by the global hotkey. It
/// appears near the mouse, focuses a search field, lists recent clips
/// (filtered live), and supports ↑/↓ selection + ↩ to paste into the app
/// the hotkey was pressed in. Distinct from the menu-bar `TrayController`
/// popover (which stays anchored to the status item).
@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate {
    private weak var container: AppContainer?
    private var panel: NSPanel?
    private var model: QuickPasteModel?
    private var keyMonitor: Any?

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        guard let container else { return }
        // Capture the target app *before* we activate ourselves so the
        // eventual auto-paste lands where the hotkey was pressed.
        container.pasteEngine.captureFrontmostApp()

        // Gate on the biometric lock before building the panel. When the
        // lock is off this resolves immediately; when on, the system auth
        // sheet runs first and the panel appears only on success.
        Task { @MainActor in
            guard await container.ensureUnlocked() else { return }
            self.present(container: container)
        }
    }

    private func present(container: AppContainer) {
        let model = QuickPasteModel(container: container)
        model.onActivate = { [weak self] item in self?.paste(item) }
        model.onClose = { [weak self] in self?.close() }
        self.model = model

        let panel = makePanel(model: model, container: container)
        self.panel = panel
        positionNearCursor(panel)

        // A non-activating panel takes key focus for typing *without*
        // activating Clipz — so pressing the hotkey doesn't drag the main
        // window forward alongside the popup, and the app you were in stays
        // frontmost underneath (which is exactly where auto-paste lands).
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    // MARK: - Paste

    private func paste(_ item: ClipboardItem) {
        guard let container else { return }
        Task { @MainActor in
            // Sensitive clips require Touch ID before reaching the pasteboard.
            guard await container.ensureSensitiveAccess(to: item) else {
                self.close()
                return
            }
            await PasteboardWriter.write(
                item,
                fileStore: container.fileStore,
                watcher: container.clipboardWatcher
            )
            self.close()
            let autoPaste = await container.settings.get(SettingsKeys.autoPaste)
            if autoPaste, AccessibilityPermission.isGranted() {
                _ = await container.pasteEngine.paste()
            }
        }
    }

    // MARK: - Panel

    private func makePanel(model: QuickPasteModel, container: AppContainer) -> NSPanel {
        let panel = QuickPastePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Let the user grow it, but never collapse below a usable size.
        panel.minSize = NSSize(width: 460, height: 320)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // We never activate Clipz, so lean on `windowDidResignKey`
        // (click-away) to dismiss rather than `hidesOnDeactivate`.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: QuickPasteView(model: model).environment(container)
        )
        return panel
    }

    /// Drop the panel just below-right of the cursor, clamped to the
    /// screen the cursor is on.
    private func positionNearCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - size.height + 24)

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Keyboard

    /// Intercept navigation keys app-wide so they drive the list instead of
    /// the focused search field (which would otherwise move its caret).
    /// Character keys fall through to the search field.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            switch Int(event.keyCode) {
            case 125: model.moveDown(); return nil      // ↓
            case 126: model.moveUp(); return nil        // ↑
            case 36, 76: model.activateSelection(); return nil  // ↩ / enter
            case 53: model.onClose(); return nil        // esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Click-away / app deactivation dismisses the panel.
        close()
    }
}

/// NSPanel that can take key focus so the search field accepts typing.
final class QuickPastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Stay a key-only panel: becoming main would activate the app and pull
    // its other windows forward, which is exactly what we're avoiding.
    override var canBecomeMain: Bool { false }
}

/// One row in the quick-paste list: the clip and, when it came from a
/// search, the matched snippet (with `⟪⟫` markers) so the panel can show
/// *why* it matched instead of a generic preview.
struct QuickPasteResult: Identifiable {
    let item: ClipboardItem
    let snippet: String?
    var id: String { item.id }
}

/// Observable state for the quick-paste panel: the query, the (live)
/// results, and the highlighted row.
@MainActor
@Observable
final class QuickPasteModel {
    var query = ""
    var results: [QuickPasteResult] = []
    var selected = 0

    @ObservationIgnored private let container: AppContainer
    @ObservationIgnored var onActivate: (ClipboardItem) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// How many clips to surface — generous so the panel is a real
    /// browser, not just a recents peek.
    private let pageLimit = 100

    init(container: AppContainer) {
        self.container = container
    }

    func load() async {
        await runSearch("")
    }

    /// Debounced re-search as the user types.
    func queryChanged() {
        searchTask?.cancel()
        let q = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            await self?.runSearch(q)
        }
    }

    private func runSearch(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let list: [QuickPasteResult]
        if q.isEmpty {
            let items = (try? await container.clipboard.fetchPage(limit: pageLimit)) ?? []
            list = items.map { QuickPasteResult(item: $0, snippet: nil) }
        } else {
            let page = try? await container.searchEngine.search(query: q, limit: pageLimit)
            list = (page?.results ?? []).map {
                QuickPasteResult(item: $0.item, snippet: $0.matches.first?.snippet)
            }
        }
        results = list
        selected = 0
    }

    func moveDown() {
        guard !results.isEmpty else { return }
        selected = min(selected + 1, results.count - 1)
    }

    func moveUp() {
        guard !results.isEmpty else { return }
        selected = max(selected - 1, 0)
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
    }

    func activateSelection() {
        guard results.indices.contains(selected) else { return }
        onActivate(results[selected].item)
    }
}
