# swift_02 — App Lifecycle

## Purpose

Defines the macOS process lifecycle: `@main` entry, AppDelegate bridge, window visibility policy, tray-first startup, dock icon policy, login-item handling, and graceful shutdown. Mirrors the behavior in `electron/main.js` without bringing over the Electron-isms.

## Current Electron behavior

From `electron/main.js`:

- Single main window (`mainWindow`), created hidden (`show: false`) at `electron/main.js:251`.
- Window close button **hides** instead of quitting (`:386–391`), so closing from the dock doesn't quit.
- System tray (`Tray` from Electron) is the primary entry — app runs even when the main window is closed.
- `app.whenReady()` bootstraps: DB open, native clipboard monitor start, IPC handler registration, tray creation, retention cleanup.
- `app.on('window-all-closed', …)` explicitly does **not** quit on macOS — standard macOS behavior.
- Dock icon toggling via `setDockIcon(themeKey)` uses `app.dock.show()/hide()` based on theme, effectively conflating theming and LSUIElement behavior.
- Login-item via `app.setLoginItemSettings({ openAtLogin })` — toggled by `get/set-start-at-login` IPC handlers.
- Uncaught exception + unhandledRejection listeners log to stderr and a file; no crash reporting service.
- App version is hardcoded at `electron/main.js:12` and must be kept in sync with `package.json` (currently drifted to `1.1.6-N-PRO` per WARP.md vs `1.0.0-beta.13` in package.json).

## Swift design

### Entry point

```swift
// ClipzApp/App.swift
import SwiftUI
import ClipzCore
import ClipzUI

@main
struct ClipzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Main window is a WindowGroup with a single instance (id: "main").
        WindowGroup(id: "main") {
            ClipboardRootView()
                .environment(appDelegate.container)
                .frame(minWidth: 600, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 700)
        .defaultPosition(.topTrailing)
        .commands {
            ClipzCommands(container: appDelegate.container)
        }

        Settings {
            SettingsRootView()
                .environment(appDelegate.container)
                .frame(width: 640, height: 520)
        }
    }
}
```

Key points:

- `.defaultPosition(.topTrailing)` reflects the current Electron placement (right-aligned, 50% × 80% of screen). On macOS 14+, SwiftUI remembers position automatically via `WindowGroup` identity.
- `ClipzCommands` adds keyboard shortcuts at the menu level (Cmd+F, Cmd+Shift+D, Cmd+N for new note, etc.) — these show up in the menu bar and are discoverable, replacing the ad-hoc `keydown` listeners in `ClipboardPage.tsx`.
- `Settings { … }` generates the standard `Preferences…` scene (Cmd+,).

### AppDelegate

`@NSApplicationDelegateAdaptor` gives us the classic NSApplicationDelegate lifecycle needed for things SwiftUI doesn't cover yet (tray, auto-termination, close-hides-window).

```swift
// ClipzApp/AppDelegate.swift
import AppKit
import ClipzCore
import ClipzUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let container: AppContainer = AppContainer.shared
    private var trayController: TrayController?
    private var clipboardWatcher: ClipboardWatcher?
    private var screenshotWatcher: ScreenshotWatcher?

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register URL scheme handler (for clipz:// deep links, if ever introduced)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Bootstrap core services
        Task {
            await container.bootstrap()
        }

        // 2. Build tray (non-optional: the app is tray-first)
        trayController = TrayController(container: container)

        // 3. Start clipboard watcher (respects settings toggle)
        clipboardWatcher = ClipboardWatcher(service: container.clipboardService,
                                            settings: container.settings)
        Task { await clipboardWatcher?.startIfEnabled() }

        // 4. Start screenshot watcher (respects settings toggle + bookmark availability)
        screenshotWatcher = ScreenshotWatcher(service: container.clipboardService,
                                              settings: container.settings)
        Task { await screenshotWatcher?.startIfEnabled() }

        // 5. Apply dock-icon policy from settings
        applyDockIconPolicy()

        // 6. Migration from Electron app on first launch (see swift_25)
        Task { await ElectronMigrator(container: container).runIfNeeded() }

        // 7. First-run welcome note (matches current app behavior)
        Task { await container.notesService.seedWelcomeNoteIfFirstLaunch() }
    }

    // MARK: - Close-to-tray behavior

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Tray-first app: closing the last window doesn't quit.
        // Matches electron/main.js:386–391 behavior.
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        TrayController.buildDockMenu(container: container)
    }

    // MARK: - Reopen

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowRouter.showMainWindow()
        }
        return true
    }

    // MARK: - Quit

    func applicationWillTerminate(_ notification: Notification) {
        // Flush pending writes, close DB cleanly.
        // GRDB's DatabasePool handles concurrent closes, but we give it a chance.
        Task {
            await clipboardWatcher?.stop()
            await screenshotWatcher?.stop()
            await container.flushAndClose()
        }
    }

    // MARK: - Private

    private func applyDockIconPolicy() {
        let showDock = container.settings.showDockIcon
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    @objc private func handleURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        // Placeholder: process clipz:// URLs if deep-linking is added.
    }
}
```

### AppContainer (composition root)

```swift
// ClipzApp/AppContainer.swift
import ClipzCore
import ClipzUI
import ClipzML
import Observation

@MainActor
@Observable
final class AppContainer {
    static let shared = AppContainer()

    // Persistence
    let database: AppDatabase

    // Services
    let clipboardService: ClipboardService
    let notesService: NotesService
    let tasksService: TasksService
    let backupService: BackupService
    let licenseService: LicenseService
    let analysisService: AnalysisService

    // Cross-cutting
    let settings: SettingsStore
    let fileStore: FileStore

    private init() {
        let fileStore = FileStore.applicationSupport
        self.fileStore = fileStore
        self.database = try! AppDatabase.make(at: fileStore.databaseURL)
        self.settings = SettingsStore(database: database)
        self.clipboardService = ClipboardService(database: database, fileStore: fileStore)
        self.notesService = NotesService(database: database)
        self.tasksService = TasksService(database: database)
        self.analysisService = AnalysisService(database: database,
                                               fileStore: fileStore,
                                               ml: MLPipeline())
        self.backupService = BackupService(database: database, fileStore: fileStore)
        self.licenseService = LicenseService()
    }

    func bootstrap() async {
        await settings.load()
        await clipboardService.warmCaches()
        await licenseService.refreshEntitlements()
    }

    func flushAndClose() async {
        await clipboardService.stop()
        await analysisService.stop()
        await database.close()
    }
}
```

This structure lets any service be swapped for a mock in tests without a DI framework.

### Window router

Because SwiftUI windows are identified by scene IDs, we wrap "show main window" in a helper so AppKit callers (tray, dock menu) can trigger it:

```swift
// Packages/ClipzUI/Sources/ClipzUI/Windows/WindowRouter.swift
@MainActor
enum WindowRouter {
    static func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // WindowGroup re-materializes the scene
            NSWorkspace.shared.open(URL(string: "clipz://main")!)
        }
    }

    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
```

(`showSettingsWindow:` is the private SwiftUI selector that opens the Settings scene. It's stable enough to rely on, but the alternative is `NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)` wired through the AppDelegate.)

### Dock icon policy

`set-dock-icon` IPC today toggles both `app.dock.show()` and some theme behavior. Swift version:

- Setting name: `showDockIcon` (Bool, stored in settings table, default `true`).
- Effect: `NSApp.setActivationPolicy(.regular)` when `true`, `.accessory` when `false`.
- When `.accessory`, the tray remains the only entry point.
- UI: toggle is in `SettingsRootView` → General tab.

**Edge case**: switching to `.accessory` while a window is open doesn't hide the window; the Dock just goes away. The user can reopen via tray menu. Matches current Electron UX.

### Login item

Replaces `app.setLoginItemSettings({ openAtLogin })`. Use `SMAppService` (macOS 13+, recommended):

```swift
import ServiceManagement

struct LoginItemManager {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled, service.status != .enabled {
            try service.register()
        } else if !enabled, service.status == .enabled {
            try service.unregister()
        }
    }
}
```

- No entitlement required in macOS 13+ when using `SMAppService.mainApp`.
- If the user enables then moves the app bundle, macOS flags the login item as "requires approval" — the user must re-authorize in **System Settings → General → Login Items**. Handle this by checking `.requiresApproval` status and surfacing a hint in the Settings UI.

### First-launch seeding

The current app seeds a welcome note on first launch (`electron/verify-welcome-note.js`). Port as:

```swift
extension NotesService {
    func seedWelcomeNoteIfFirstLaunch() async {
        let marker = "hasSeededWelcomeNote"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        await create(title: "Welcome to Clipz",
                     contentText: WelcomeNoteContent.plainText,
                     contentJSON: WelcomeNoteContent.attributed)
        UserDefaults.standard.set(true, forKey: marker)
    }
}
```

Keep the marker in `UserDefaults`, not the settings table — it's a single-use boolean and shouldn't travel with database backups/restores (otherwise restoring the DB would suppress future welcome notes on a fresh device).

### Crash handling

Replace Electron's global uncaught-exception listeners with:

1. **MetricKit** (`MXMetricManager`) for production crash + hang reports. Reports arrive at the next app launch and can be written to a local log and optionally uploaded with user consent.
2. **Debug-only** `signal(SIGABRT, …)` handler that dumps the backtrace to a file in Application Support (Release builds drop this).

No third-party crash SDK (Sentry, Bugsnag) to keep the dependency surface minimal and App Store privacy disclosures simple.

### `ClipzCommands` — menu bar structure

```swift
struct ClipzCommands: Commands {
    let container: AppContainer

    var body: some Commands {
        CommandMenu("Clipboard") {
            Button("New Note", action: { Task { await container.notesService.createBlank() } })
                .keyboardShortcut("n", modifiers: [.command])
            Divider()
            Button("Find…", action: { NotificationCenter.default.post(name: .focusSearch, object: nil) })
                .keyboardShortcut("f", modifiers: [.command])
            Button("Copy to Desktop", action: { NotificationCenter.default.post(name: .copyHoveredToDesktop, object: nil) })
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) { }  // suppress default "New" items
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                // App Store handles updates; this can link to the store listing
                NSWorkspace.shared.open(URL(string: "macappstore://itunes.apple.com/app/id\(StoreIDs.appID)")!)
            }
        }
    }
}
```

Notification-based glue is used here because CommandMenu buttons fire globally, while the *actual* behavior (focus the search field, highlight the hovered card) depends on what view is currently foregrounded. Each view opts in by listening for the notification.

### Menu bar (system-wide menus)

In addition to CommandMenu, customize the full NSApp menu via `NSApp.mainMenu` in AppDelegate if default SwiftUI menus are insufficient. Reserve this for the **File → Export Backup** entry and **Clipz → Manage Pro Subscription…** entry which are not trivially expressible as `CommandMenu`.

## Edge cases & gotchas

- **`applicationShouldTerminate:`** — if a long-running backup is in progress, return `.terminateLater` and finish the operation before calling `.reply(toApplicationShouldTerminate:)`. Without this, Cmd+Q or system logout corrupts backups.
- **Power events** — subscribe to `NSWorkspace.willSleepNotification` / `didWakeNotification` to pause the clipboard poll; restart on wake. The native Electron addon gets this for free via FSEvents/NSPasteboard; Swift's Timer-based poll needs explicit pause to avoid draining battery in sleep.
- **Multiple displays** — SwiftUI `defaultPosition(.topTrailing)` uses the main display. If the main window previously lived on a display that's now disconnected, SwiftUI auto-relocates, but *the user's frame save name* must be unique to avoid stale positions. `windowStyle(.titleBar)` + `windowResizability(.contentSize)` + scene identity is enough; no manual frame math.
- **Fast User Switching** — `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification`. Pause the watcher when the user switches away to avoid capturing the other user's clipboard.
- **Launching while the user pastes** — the first clipboard change after launch is currently saved even if identical to the last saved item. Add a first-change dedup window: ignore the first NSPasteboard event within 2 s of launch if `contentHash` matches the last stored item. See swift_03.

## MAS notes

- **`NSApp.setActivationPolicy(.accessory)`** is permitted under sandbox; no entitlement needed.
- **URL handler** (`clipz://…`) requires `CFBundleURLTypes` in Info.plist. Register only if we actually ship deep links.
- **`NSWorkspace.shared.open(…)` to a store URL** is allowed in sandbox — this is used for "Update via App Store" and "Manage Subscription" actions.
- **MetricKit** is sandbox-compatible; no entitlement needed.
- **SMAppService.mainApp** is sandbox-compatible since macOS 13.

## Open questions

- **Restore last open window on relaunch?** macOS default is "restore on relaunch" via `NSQuitAlwaysKeepsWindows`. If the user expects "always start minimized to tray", set this to `false`. Default: **keep on**, matching macOS conventions and letting the OS do its job.
- **Handle `Cmd+Option+click` on Dock icon** (Force Quit or Quick Look) — no special handling needed; system handles it.
- **Custom Dock menu entries** (recent items) — nice-to-have, not in v1; flagged in swift_26 as deferred.
