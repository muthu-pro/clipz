// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import AppKit
import ClipzCore
import ClipzML

/// Dependency-injection root for the ClipzApp target. Owns the on-disk
/// database, every service actor, and both watchers. SwiftUI views read
/// it via `@Environment(AppContainer.self)`.
///
/// The class is `@MainActor` because SwiftUI observation requires it;
/// the underlying services stay as plain actors and we `await` into
/// them whenever we pull state.
/// Biometric gate state for viewing clipboard data.
public enum AppLockState: Sendable {
    case locked
    case unlocked
}

@Observable @MainActor
public final class AppContainer {
    // MARK: - Shared infrastructure

    public let database: AppDatabase
    public let fileStore: FileStore
    public let broadcaster: EventBroadcaster
    public let settings: SettingsStore

    // MARK: - Feature services

    public let clipboard: ClipboardService
    public let searchEngine: SearchEngine
    public let analysis: AnalysisService

    // MARK: - Capture path

    public let clipboardWatcher: ClipboardWatcher
    public let screenshotWatcher: ScreenshotWatcher

    // MARK: - Outgoing paste

    public let pasteEngine: PasteEngine = PasteEngine()

    // MARK: - Observable state for SwiftUI

    /// Biometric-lock gate for viewing clipboard data. `.unlocked` unless
    /// the user enabled `requireBiometricUnlock`, in which case the app
    /// boots `.locked` and each data surface (window, tray, quick-paste)
    /// checks this before revealing anything. The `WindowRouter` observes it.
    public var lockState: AppLockState = .unlocked

    /// Wall-clock of the last successful unlock, for the idle-timeout mode.
    @ObservationIgnored
    private var lastUnlockDate: Date?

    /// Cached capture policy for password/key clips, so cards can decide
    /// synchronously whether to blur + gate. Loaded in `start()` and kept in
    /// sync by the Settings picker.
    public var sensitiveContentPolicy: SensitiveContentPolicy = .protect

    // MARK: - Menu bar

    /// Installed on `start()`. Kept as a strong reference so the status
    /// item survives for the lifetime of the app.
    private var trayController: TrayController?

    /// System-wide shortcut that opens the quick-paste panel. Strong
    /// reference so the Carbon registration outlives `start()`.
    @ObservationIgnored
    private var globalHotkey: GlobalHotkey?

    /// Spotlight-style panel summoned by the global hotkey (near the cursor,
    /// searchable, keyboard-navigable).
    @ObservationIgnored
    private var quickPaste: QuickPasteController?

    /// True while a timeline card is being dragged. The drop handler uses
    /// this to refuse re-importing a clip dragged within the app (the OS
    /// hands the drop a temp copy, so neither a path check nor the drag's
    /// custom marker is reliable through SwiftUI's drop bridge).
    @ObservationIgnored
    public var internalDragInProgress = false

    /// Bridge to SwiftUI's `openWindow` action, installed by the app
    /// scene once its environment is available. As an `LSUIElement` agent
    /// app the main window is *destroyed* when the user closes it, so it
    /// can't be revived by walking `NSApp.windows` — only SwiftUI can
    /// re-instantiate the scene. `TrayController` calls this on left-click.
    @ObservationIgnored
    public var showMainWindow: (() -> Void)?

    // MARK: - Construction

    public init(
        database: AppDatabase,
        fileStore: FileStore,
        settings: SettingsStore? = nil
    ) {
        self.database = database
        self.fileStore = fileStore

        let resolvedSettings = settings ?? SettingsStore(database: database)
        self.settings = resolvedSettings

        let resolvedBroadcaster = EventBroadcaster()
        self.broadcaster = resolvedBroadcaster

        let resolvedAnalysis = AnalysisService(
            database: database,
            fileStore: fileStore,
            broadcaster: resolvedBroadcaster
        )
        self.analysis = resolvedAnalysis

        self.clipboard = ClipboardService(
            database: database,
            fileStore: fileStore,
            broadcaster: resolvedBroadcaster,
            settings: resolvedSettings,
            analysisEnqueuer: resolvedAnalysis
        )
        self.searchEngine = SearchEngine(database: database)

        self.clipboardWatcher = ClipboardWatcher(
            service: clipboard,
            settings: resolvedSettings
        )
        self.screenshotWatcher = ScreenshotWatcher(
            service: clipboard,
            settings: resolvedSettings
        )
    }

    // MARK: - Lifecycle

    /// Produce a ready-to-use container. Called exactly once at app
    /// launch from `ClipzAppApp.body`'s `.task`. Opens the DB in
    /// `Application Support/clipz/`, resolves licensing, and starts the
    /// clipboard + screenshot watchers.
    public static func bootstrap() async throws -> AppContainer {
        let rootDir = try FileStore.defaultApplicationSupport()
        // Apply a staged restore (if any) *before* opening the database.
        BackupService.applyPendingRestoreIfNeeded(rootDir: rootDir)
        let fileStore = try FileStore(rootDir: rootDir)
        let dbURL = rootDir.appendingPathComponent("clipz.db")
        let database = try AppDatabase.make(at: dbURL)

        let container = AppContainer(database: database, fileStore: fileStore)
        await container.start()
        return container
    }

    /// Starts all the background tasks.
    public func start() async {
        await clipboardWatcher.startIfEnabled()
        // Screenshot watcher only starts if the user has granted a
        // bookmark (handled inside startIfEnabled).
        try? await screenshotWatcher.startIfEnabled()

        await analysis.start()

        // Install the menu-bar tray last so the first popover open
        // sees services already running.
        if trayController == nil {
            trayController = TrayController(container: self)
        }
        if quickPaste == nil {
            quickPaste = QuickPasteController(container: self)
        }

        await reloadGlobalHotkey()

        // Arm the biometric lock from settings (opens `.locked` if the user
        // enabled it) before any surface can render clipboard data.
        await startBiometricLock()

        sensitiveContentPolicy = await settings.get(SettingsKeys.sensitiveContentPolicy)
    }

    /// (Re)register the global hotkey from the persisted settings. Called on
    /// `start()` and by the Settings recorder after a rebind.
    public func reloadGlobalHotkey() async {
        let enabled = await settings.get(SettingsKeys.globalHotkeyEnabled)
        let keyCode = await settings.get(SettingsKeys.globalHotkeyKeyCode)
        let modsRaw = await settings.get(SettingsKeys.globalHotkeyModifiers)

        if globalHotkey == nil {
            globalHotkey = GlobalHotkey { [weak self] in
                // Open the Spotlight-style quick-paste panel near the cursor.
                self?.quickPaste?.toggle()
            }
        }
        globalHotkey?.update(
            enabled: enabled,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modsRaw))
        )
    }

    // MARK: - Biometric lock

    @ObservationIgnored
    private var relockObservers: [any NSObjectProtocol] = []

    @ObservationIgnored
    private var idleLockTask: Task<Void, Never>?

    /// Boot the lock gate from settings and wire the re-lock triggers.
    /// Called once from `start()`. When the feature is on the app opens
    /// `.locked`; each surface unlocks on demand.
    private func startBiometricLock() async {
        let required = await settings.get(SettingsKeys.requireBiometricUnlock)
        lockState = required ? .locked : .unlocked
        guard required else { return }
        installRelockObservers()
    }

    /// Sleep / screen-lock re-lock the app (per-session + idle modes).
    /// Fresh launches already boot locked, so quitting is covered for free.
    private func installRelockObservers() {
        guard relockObservers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        for name in sleepNames {
            relockObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.lock()
                }
            )
        }
        // Best-effort: the screen-lock distributed notification can be
        // unreliable under the App Sandbox, so it supplements (never
        // replaces) the workspace sleep signals above.
        relockObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.lock() }
        )
    }

    /// True while the biometric gate should block clipboard data.
    public var isLocked: Bool { lockState == .locked }

    public func lock() {
        lockState = .locked
        idleLockTask?.cancel()
        idleLockTask = nil
    }

    /// Present the system auth sheet and, on success, open the gate.
    @discardableResult
    public func unlock() async -> Bool {
        let ok = await BiometricAuthenticator.authenticate(
            reason: "unlock Clipz to view your clipboard"
        )
        if ok {
            lockState = .unlocked
            lastUnlockDate = Date()
            await armIdleTimerIfNeeded()
        }
        return ok
    }

    /// The guard every data surface calls before revealing clips. A single
    /// unlock is **shared**: once any surface authenticates, the others
    /// inherit the unlocked state and don't ask again. The re-lock *mode*
    /// only governs when that shared unlock ends — on idle lapse
    /// (`idleTimeout`), on leaving the app (`everyTime`), or on quit / Mac
    /// lock (`perSession`).
    public func ensureUnlocked() async -> Bool {
        guard await settings.get(SettingsKeys.requireBiometricUnlock) else { return true }

        // Idle mode: expire a stale shared unlock before honoring it.
        if lockState == .unlocked,
           await settings.get(SettingsKeys.biometricLockMode) == .idleTimeout,
           let last = lastUnlockDate {
            let minutes = await settings.get(SettingsKeys.biometricIdleTimeoutMinutes)
            if Date().timeIntervalSince(last) > Double(minutes) * 60 { lock() }
        }

        return lockState == .unlocked ? true : await unlock()
    }

    /// (Re)start the idle re-lock timer for the idle-timeout mode.
    private func armIdleTimerIfNeeded() async {
        idleLockTask?.cancel()
        guard await settings.get(SettingsKeys.biometricLockMode) == .idleTimeout else { return }
        let minutes = await settings.get(SettingsKeys.biometricIdleTimeoutMinutes)
        idleLockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(max(1, minutes)) * 60))
            if Task.isCancelled { return }
            self?.lock()
        }
    }

    /// Re-read the lock configuration after the user toggles the setting or
    /// changes the mode. Turning it on installs the re-lock observers and
    /// engages the lock immediately so the setting takes visible effect;
    /// turning it off opens the gate.
    public func refreshBiometricLock() async {
        let required = await settings.get(SettingsKeys.requireBiometricUnlock)
        if required {
            installRelockObservers()
            lock()
        } else {
            lockState = .unlocked
            idleLockTask?.cancel()
            idleLockTask = nil
        }
    }

    // MARK: - Sensitive content

    /// The gate every reveal/copy path calls for a clip. Returns `true`
    /// immediately unless the clip is a protected password/key, in which case
    /// it prompts Touch ID (with the account-password fallback) and returns
    /// whether the user authenticated.
    public func ensureSensitiveAccess(to item: ClipboardItem) async -> Bool {
        guard item.isSensitive, sensitiveContentPolicy == .protect else { return true }
        return await BiometricAuthenticator.authenticate(
            reason: "reveal this sensitive clip"
        )
    }

    /// Re-read the capture policy after the Settings picker changes it.
    public func refreshSensitiveContentPolicy() async {
        sensitiveContentPolicy = await settings.get(SettingsKeys.sensitiveContentPolicy)
    }

    deinit {
        // `AppContainer` is an app-lifetime singleton torn down with the
        // process; stop the idle re-lock task so it doesn't keep waking.
        idleLockTask?.cancel()
    }

    // MARK: - Derived

    /// Backup / restore for the Settings → Backup tab. A lightweight value
    /// type, so a fresh one per access is fine.
    public var backups: BackupService {
        BackupService(database: database, fileStore: fileStore)
    }
}
