# swift_11 — Window Management

## Purpose

Define every window and popover the app puts on screen: main window, tray (menu bar) popover, settings, and optional debug window. Covers lifecycle, materials (vibrancy), positioning, state persistence, and multi-display behavior.

Replaces: Electron's single `BrowserWindow` + `Tray` + `popup.html` trio, plus the debug monitor window.

## Current Electron behavior

- **Main window** — `BrowserWindow({ width: 50% screenW, height: 80% screenH, x: screen.width - width, ... })` at `main.js:237-244`. `vibrancy: 'under-window'`, `transparent: true`, `backgroundColor: '#00000000'`. Hidden at startup (`show: false`).
- **Tray** — `Tray(iconPath)`. Left-click shows/hides the popup window; right-click shows a Chromium-rendered menu. Icon chosen via `getTrayIconPath(themeKey)` — light/dark variants.
- **Popup** — a separate `BrowserWindow` loading `popup.html`. Positioned near the tray icon; dismissed on blur.
- **Debug monitor** — an optional inline-HTML `BrowserWindow` (`electron/debugWindow.js`). Off by default.

## Swift design

Each window has its own controller in `Packages/ClipzUI/Sources/ClipzUI/Windows/`.

### Main window

Handled by SwiftUI `WindowGroup`:

```swift
// ClipzApp/App.swift
WindowGroup(id: "main") {
    ClipboardRootView()
        .frame(minWidth: 600, minHeight: 480)
        .background(VibrancyView(material: .underWindowBackground, blendingMode: .behindWindow))
}
.windowResizability(.contentSize)
.defaultSize(width: 900, height: 700)
.defaultPosition(.topTrailing)
```

The `VibrancyView` is a tiny `NSViewRepresentable`:

```swift
// Packages/ClipzUI/Sources/ClipzUI/Windows/VibrancyView.swift
import SwiftUI
import AppKit

public struct VibrancyView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .underWindowBackground,
                blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    public func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
```

### Transparent window chrome

To get the full "under-window" vibrancy look matching the current Electron app, configure the `NSWindow` at app launch:

```swift
// In AppDelegate applicationDidFinishLaunching, after first window is visible:
if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
}
```

SwiftUI's `.windowStyle(.hiddenTitleBar)` is a more declarative alternative but limits title-bar customization; we take the imperative path because Clipz needs standard traffic lights + vibrancy + transparent chrome.

### Close-to-tray

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false` (swift_02). Closing the main window hides it; NSApp lives on thanks to the tray.

Explicit "Quit Clipz" from the tray menu calls `NSApp.terminate(nil)`.

### Tray (NSStatusItem) + Popover

```swift
// Packages/ClipzUI/Sources/ClipzUI/Tray/TrayController.swift
import AppKit
import SwiftUI

@MainActor
final class TrayController: NSObject {
    static var shared: TrayController?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        TrayController.shared = self
        configureButton()
        configurePopover()
    }

    private func configureButton() {
        let button = statusItem.button!
        button.image = NSImage(named: "TrayIconTemplate")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient     // auto-dismiss on outside click
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: TrayPopupView(container: container)
                .frame(width: 380, height: 540)
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Capture the frontmost app BEFORE the popover steals focus
            Task { await container.pasteEngine.captureFrontmostApp() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func dismissPopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Clipz", action: #selector(openMain), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipz", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil    // reset so left-click returns to toggle behavior
    }

    @objc private func openMain() { WindowRouter.showMainWindow() }
    @objc private func openSettings() { WindowRouter.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
```

### Tray popover content (SwiftUI)

```swift
struct TrayPopupView: View {
    let container: AppContainer
    @State private var items: [ClipboardItem] = []

    var body: some View {
        VStack(spacing: 0) {
            TrayHeaderView()
            Divider()
            TrayList(items: items, onSelect: handleSelect, onDrag: handleDrag)
            Divider()
            TrayFooterView()
        }
        .background(VibrancyView(material: .popover))
        .task { await refresh() }
    }

    private func handleSelect(_ item: ClipboardItem) async {
        await container.pasteEngine.paste(item)
    }

    private func refresh() async {
        items = (try? await container.clipboardService
            .fetchPage(limit: 30, offset: 0, kindFilter: nil,
                       dateRange: nil, sourceAppFilter: nil)) ?? []
    }
}
```

### Popover dismissal behavior

`NSPopover.behavior = .transient` auto-closes when the user clicks outside. For keyboard users, Esc closes it via `onKeyboardShortcut(.escape) { dismissPopover() }` on the hosted view.

**Don't use `.semitransient`** — it stays open even when focus leaves, which is wrong for a clipboard picker.

### Settings window

```swift
// App.swift scene
Settings {
    SettingsRootView()
        .environment(appDelegate.container)
        .frame(width: 640, height: 520)
}
```

This yields the stock "Preferences" window that opens on Cmd+, with Apple's tab-style chrome. Details of tab contents in swift_14.

### Debug window (optional)

The Electron app has an inline-HTML debug monitor (`debugWindow.js`, 494 lines) that can be toggled from `main.js:~790`. Swift equivalent:

```swift
struct DebugWindow: View {
    @State private var metrics = PerformanceMetrics()

    var body: some View {
        TabView {
            MetricsTab(metrics: metrics)
                .tabItem { Label("Metrics", systemImage: "gauge") }
            LogsTab()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
            SQLInspectorTab()
                .tabItem { Label("SQL", systemImage: "cylinder") }
        }
        .frame(width: 800, height: 520)
        .task { await metrics.startTracking() }
    }
}
```

Toggle via a hidden keyboard shortcut: **Cmd+Option+Shift+D** opens the debug window. Not exposed in the menu; exists for developers and bug reporters. Disabled in App Store release builds by default (`#if DEBUG || INTERNAL_BUILD`).

### Window routing (cross-component helper)

```swift
// Packages/ClipzUI/Sources/ClipzUI/Windows/WindowRouter.swift
@MainActor
public enum WindowRouter {
    public static func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if !w.isVisible { w.makeKeyAndOrderFront(nil) }
            else { w.orderFrontRegardless() }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            // Reopen by dispatching to the scene — re-materializes WindowGroup
            NSWorkspace.shared.open(URL(string: "clipz://main")!)
        }
    }

    public static func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    public static func openNote(id: String) {
        // Routes through the main window's nav state
        NotificationCenter.default.post(name: .openNote, object: id)
        showMainWindow()
    }

    public static func highlightItem(id: String) {
        NotificationCenter.default.post(name: .highlightItem, object: id)
        showMainWindow()
    }
}
```

Handles deep links from tray and notifications alike.

### Window state persistence

- SwiftUI auto-persists window size and position for scenes with stable identity.
- For the main window we rely on this default. If finer-grained control is needed (e.g., "restore maximized"), use `@SceneStorage` inside the scene.
- Tray popover doesn't persist state; it's re-created each show.

### Multi-display behavior

- Main window: remembers the display it was last on; macOS relocates gracefully if that display disconnects.
- Tray popover: always anchored to the status item, which lives on whichever screen the menu bar is on (configurable in System Settings → Displays → "Displays have separate Spaces").
- Settings: opens on the active screen.

No per-display logic in Swift code — the OS handles it.

### Global hotkey to toggle the popup

The Electron app doesn't implement a global hotkey today, but it's a common ask. Add a simple registration using Apple's `Carbon` hotkey API via a thin Swift wrapper:

```swift
public final class GlobalHotkey {
    public static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                                 handler: @escaping () -> Void) {
        // Using Carbon RegisterEventHotKey — sandbox-compatible, but the user
        // must grant "Input Monitoring" for hotkey to fire.
    }
}
```

Default binding: **Cmd+Shift+V** toggles the tray popup, matching popular clipboard managers. User-configurable in Settings. Defer to v1.1 if Accessibility/Input Monitoring grant flows prove annoying; can ship without a global hotkey in v1.

## Edge cases & gotchas

1. **Main window re-open via URL scheme** — depends on registering `clipz://` in Info.plist. If the scheme isn't registered, `NSWorkspace.shared.open` silently fails. As a fallback, use a custom `Notification.showMainWindow` that the `WindowGroup`'s root view observes.

2. **Popover positioning on first open** — `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`: if the status bar is at the top (default), `.minY` means popover appears below the bar. On systems with a bottom menubar (rare), flip to `.maxY`.

3. **Tray popover behind fullscreen app** — when the active app is in native macOS fullscreen, the menubar only appears on hover; popover appearing can feel jarring. No mitigation — macOS handles this gracefully (popover appears above the fullscreen app's space).

4. **Dark menubar icons on Big Sur+** — `image.isTemplate = true` makes the icon respect the menubar's appearance. Don't apply tinting manually.

5. **Vibrancy + dark transparent background** — if the user's wallpaper is bright, vibrancy under-window material tints light. This is by design; theme definitions should avoid assuming pure dark backgrounds.

6. **Tray popover content not keyable** — by default, `NSPopover` doesn't take keyboard focus if the status item button is clicked. Force it via `popover.contentViewController?.view.window?.makeKey()` (as in the controller).

7. **Closing the main window while the tray popover is open** — both are independent; closing one doesn't affect the other.

8. **App in `.accessory` mode (dock icon hidden)** — main window still opens via tray menu; the app just won't appear in the Dock. This is the intended "menubar-only" user experience.

9. **Window restoration on OS relaunch** — if the user has "Close windows when quitting app" off in macOS Settings, the main window reopens on relaunch. `WindowGroup` respects this preference.

10. **Multiple main windows** — SwiftUI `WindowGroup` allows multiple windows per group. Lock to single instance by checking in the `openWindow` action: `if NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" }) { /* just focus */ }`.

11. **Popover width on narrow displays** — 380 pt is safe on all modern Macs. If ever run on an older 11" MacBook Air, consider making width responsive. Low priority.

12. **Tray popover vs NSPanel** — considered using a custom `NSPanel` for finer control. Stuck with `NSPopover` for simplicity; move to panel only if we need features popover can't do (e.g., pinning open).

## MAS notes

- `NSStatusBar.system.statusItem` — sandbox-compatible.
- `NSPopover` — sandbox-compatible.
- `NSVisualEffectView` — sandbox-compatible.
- Transparent window backgrounds + full-size content — sandbox-compatible.
- Custom URL scheme (`clipz://`) — sandbox-compatible; requires `CFBundleURLTypes` Info.plist entry (swift_19).
- Global hotkey via Carbon `RegisterEventHotKey` — sandbox-compatible. Some hotkey combinations (e.g., pure function keys) may require Input Monitoring TCC grant; Cmd+Shift+V does not.

## Open questions

- **Detachable popover** — allow the user to "tear off" the popover into a floating window? Nice but out of v1 scope.
- **Spaces behavior** — should the tray popover follow the user across Spaces, or live only in the Space it was opened in? macOS default is the latter; no override needed.
- **Fullscreen behavior for main window** — macOS fullscreen (`NSWindow.toggleFullScreen`) is wired by default. Keep.
- **Tabbed windows** — disable (`NSWindow.allowsAutomaticWindowTabbing = false` in AppDelegate). Tabs don't make sense for a single-instance main window.
