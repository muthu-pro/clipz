# swift_14 — UI: Settings

## Purpose

The Preferences (Cmd+,) window. Maps 1:1 to every IPC setting handler in the current Electron app, plus a Pro tab that replaces the hash-based license UI.

Replaces: `src/components/Layout.tsx` (1,187 lines — settings modal, theme picker, retention period UI, danger zone with CAPTCHA), `src/components/settings/*`, and the Trial/License modals (`LicenseModal.tsx`, `TrialExpiredModal.tsx`).

## Current Electron settings surface (from IPC handlers)

Collated by domain:

- **Theme**: `get-theme`, `set-theme` + auto/light/dark mode in `ThemeContext`.
- **Dock icon**: `set-dock-icon`.
- **Clipboard monitoring**: `get/set-monitor-clipboard`, `get/set-monitor-clipboard-text-only`.
- **Sound**: `get/set-mute-copy-sound`.
- **Thumbnails**: `get/set-hide-media-thumbnail`.
- **Retention**: `get/set-retention-period` (days).
- **Screenshot monitoring**: `get/set-screenshot-monitoring`, `get/set-screenshot-file-types`, `get/set-screenshot-after-import`.
- **Analysis**: `get/set-analysis-enabled`.
- **Login item**: `get/set-start-at-login`.
- **Backup**: `create-backup`, `restore-backup`, `validate-backup`, `get-backup-info`, `check-backup-password`.
- **License/trial**: `validate-license-key`, `get-license-info`, `remove-license`, `get-first-run`, `set-first-run`, `get-trial-status`, `set-trial-start-date`.
- **Storage**: `get-storage-usage` + `cleanup-old-items` + `count-expired-items`.
- **Danger**: `danger-delete` (captcha-gated full wipe).

All exposed in `Layout.tsx` across tabs `[cmdc, backup, danger, about]` plus popups.

## Swift design

### Top-level Settings scene

```swift
// ClipzApp/App.swift
Settings {
    SettingsRootView()
        .environment(appDelegate.container)
        .frame(width: 640, height: 560)
}
```

### Root with TabView

```swift
public struct SettingsRootView: View {
    public var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            ClipboardSettingsTab()
                .tabItem { Label("Clipboard", systemImage: "list.clipboard") }
            ScreenshotsSettingsTab()
                .tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }
            AnalysisSettingsTab()
                .tabItem { Label("Analysis", systemImage: "sparkles.square.filled.on.square") }
            BackupSettingsTab()
                .tabItem { Label("Backup", systemImage: "externaldrive") }
            ProSettingsTab()
                .tabItem { Label("Pro", systemImage: "star") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
            DangerSettingsTab()
                .tabItem { Label("Danger", systemImage: "exclamationmark.triangle") }
        }
        .padding(20)
    }
}
```

### General

```swift
struct GeneralSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var startAtLogin = false
    @State private var showDockIcon = true
    @State private var muteCopySound = false

    var body: some View {
        Form {
            Toggle("Show in Dock", isOn: $showDockIcon)
                .onChange(of: showDockIcon) { _, new in
                    Task { await container.settings.set(.showDockIcon, new) }
                    NSApp.setActivationPolicy(new ? .regular : .accessory)
                }
            Toggle("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, new in
                    try? LoginItemManager.setEnabled(new)
                }
            Toggle("Mute copy sound", isOn: $muteCopySound)
                .onChange(of: muteCopySound) { _, new in
                    Task { await container.settings.set(.muteCopySound, new) }
                }
        }
        .task {
            startAtLogin = LoginItemManager.isEnabled()
            showDockIcon = await container.settings.get(.showDockIcon)
            muteCopySound = await container.settings.get(.muteCopySound)
        }
    }
}
```

### Clipboard

```swift
struct ClipboardSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var monitorEnabled = true
    @State private var textOnly = false
    @State private var hideMediaThumbnails = false
    @State private var retentionDays: Int = 90

    var body: some View {
        Form {
            Toggle("Monitor clipboard", isOn: $monitorEnabled)
                .onChange(of: monitorEnabled) { _, new in
                    Task { await container.settings.set(.monitorClipboard, new) }
                    Task { if new { await container.clipboardWatcher.startIfEnabled() }
                           else { await container.clipboardWatcher.stop() } }
                }

            Toggle("Only capture text", isOn: $textOnly)
                .disabled(!monitorEnabled)
                .onChange(of: textOnly) { _, new in
                    Task { await container.settings.set(.monitorClipboardTextOnly, new) }
                }

            Toggle("Hide media thumbnails in list", isOn: $hideMediaThumbnails)
                .onChange(of: hideMediaThumbnails) { _, new in
                    Task { await container.settings.set(.hideMediaThumbnail, new) }
                }

            Picker("Keep clips for", selection: $retentionDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(Int.max)
            }
            .onChange(of: retentionDays) { _, new in
                confirmRetentionIfShrinking(to: new)
            }
        }
        .task { await load() }
    }

    private func confirmRetentionIfShrinking(to newDays: Int) {
        Task {
            let expired = (try? await container.clipboardService
                .countExpired(olderThanDays: newDays)) ?? 0
            if expired > 0 {
                let ok = await ConfirmDialog.present(
                    title: "Shorten retention period?",
                    message: "This will delete \(expired) clips immediately.",
                    confirm: "Delete and Save")
                if ok {
                    try? await container.clipboardService.deleteExpired(olderThanDays: newDays)
                    await container.settings.set(.retentionDays, newDays)
                } else {
                    retentionDays = await container.settings.get(.retentionDays)  // revert
                }
            } else {
                await container.settings.set(.retentionDays, newDays)
            }
        }
    }
}
```

### Screenshots

```swift
struct ScreenshotsSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var enabled = false
    @State private var folderBookmark: Data?
    @State private var folderPath: String = "(not set)"
    @State private var types: Set<String> = ["png", "jpg", "mov"]
    @State private var afterImport: ScreenshotAfterImportAction = .keep

    var body: some View {
        Form {
            Toggle("Monitor screenshot folder", isOn: $enabled)
                .onChange(of: enabled) { _, new in
                    Task { await applyEnabled(new) }
                }

            HStack {
                Text("Folder:").foregroundStyle(.secondary)
                Text(folderPath).textSelection(.enabled)
                Spacer()
                Button("Choose…") { Task { await chooseFolder() } }
            }

            GroupBox("Detect file types") {
                VStack(alignment: .leading) {
                    toggleType("png")
                    toggleType("jpg")
                    toggleType("mov")
                    toggleType("gif")
                }
            }

            Picker("After import", selection: $afterImport) {
                Text("Keep file").tag(ScreenshotAfterImportAction.keep)
                Text("Move to Trash").tag(ScreenshotAfterImportAction.delete)
            }
        }
        .task { await load() }
    }

    private func chooseFolder() async {
        guard let data = try? await container
            .screenshotWatcher.requestScreenshotFolderAccess() else { return }
        folderBookmark = data
        await container.settings.set(.screenshotFolderBookmark, data)
        await refreshFolderPath()
    }

    private func applyEnabled(_ new: Bool) async {
        await container.settings.set(.screenshotMonitoring, new)
        if new { await container.screenshotWatcher.startIfEnabled() }
        else   { await container.screenshotWatcher.stop() }
    }

    private func toggleType(_ ext: String) -> some View {
        Toggle(".\(ext)", isOn: Binding(
            get: { types.contains(ext) },
            set: { selected in
                if selected { types.insert(ext) } else { types.remove(ext) }
                Task { await container.settings.set(.screenshotFileTypes, types) }
            })
        )
    }
}
```

### Analysis

```swift
struct AnalysisSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var enabled = true
    @State private var thermalWarning: String? = nil

    var body: some View {
        Form {
            Toggle("Analyze images and documents", isOn: $enabled)
                .onChange(of: enabled) { _, new in
                    Task { await container.settings.set(.analysisEnabled, new) }
                }

            Section("Per-kind analysis") {
                Text("Images: Apple Vision OCR + object detection + barcode scan")
                    .foregroundStyle(.secondary).font(.caption)
                Text("PDFs: PDFKit text extraction with per-page index")
                    .foregroundStyle(.secondary).font(.caption)
                Text("Word/RTF: plain text extraction via NSAttributedString")
                    .foregroundStyle(.secondary).font(.caption)
            }

            Button("Re-analyze all items") {
                Task { await container.analysisService.reanalyzeAll() }
            }
            .buttonStyle(.bordered)

            if let thermalWarning {
                Label(thermalWarning, systemImage: "thermometer.high")
                    .foregroundStyle(.orange)
            }
        }
        .task { await load() }
    }
}
```

### Appearance

**Removed in favour of system default.** Clipz follows the macOS system appearance (System Settings → Appearance). There is no in-app theme picker, no light/dark override, no palette customisation. See swift_15 for the minimal implementation stance (tray icon template image + semantic SwiftUI colors).

### Backup

```swift
struct BackupSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var backupPath: URL?
    @State private var progress: BackupProgress?
    @State private var includePassword = false
    @State private var password: String = ""

    var body: some View {
        Form {
            Section("Create Backup") {
                Toggle("Protect with password", isOn: $includePassword)
                if includePassword {
                    SecureField("Password", text: $password)
                }
                Button("Create Backup…") { Task { await createBackup() } }
                    .disabled(progress != nil)
                if let progress {
                    ProgressView(value: progress.fraction) {
                        Text(progress.stageDescription)
                    }
                }
            }

            Divider()

            Section("Restore Backup") {
                Button("Restore From File…") { Task { await restoreBackup() } }
                    .foregroundStyle(.orange)
                Text("Restoring replaces all current data. The app will restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func createBackup() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipz-backup-\(Date().ISO8601Format()).clipzbackup"
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return }

        do {
            for try await step in container.backupService.create(
                to: url, password: includePassword ? password : nil) {
                progress = step
            }
            progress = nil
            await AlertDialog.present(title: "Backup complete")
        } catch {
            progress = nil
            await AlertDialog.present(title: "Backup failed", message: error.localizedDescription)
        }
    }

    private func restoreBackup() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipzbackup")!, .zip]
        panel.canChooseFiles = true
        guard await panel.begin() == .OK, let url = panel.url else { return }

        // Password prompt if needed
        let manifest = try? await container.backupService.getInfo(from: url)
        var pw: String? = nil
        if manifest?.encryption != nil {
            pw = await PasswordPrompt.present(title: "Backup is password-protected")
            guard pw != nil else { return }
        }

        let ok = await ConfirmDialog.present(
            title: "Restore this backup?",
            message: "This replaces all clips, notes, and tasks. The app will restart.",
            confirm: "Restore", destructive: true)
        guard ok else { return }

        do {
            try await container.backupService.restore(from: url, password: pw)
            // On success: quit and relaunch so schema migrations settle cleanly.
            NSApp.relaunch()
        } catch {
            await AlertDialog.present(title: "Restore failed", message: error.localizedDescription)
        }
    }
}
```

### Pro (the purchase surface)

The Pro tab is the in-Settings purchase and status view. Under the hard-lockout model (swift_18):

- `.trialing(daysRemaining:)` — app is fully functional; a persistent trial banner at the top of the main window links here.
- `.expired` — the main window is replaced by `PaywallWindow`. If the user still opens Settings, every non-Pro tab shows `LockedTabPlaceholder` (see below); the Pro tab stays the primary purchase surface.
- `.licensed` — confirmation state.
- `.unknown` — transient launch state; render a `ProgressView`.

```swift
struct ProSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var state: LicenseState = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .licensed(_, let purchasedAt):
                VStack(alignment: .leading) {
                    Label("Clipz unlocked", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.title3)
                    Text("Thanks for supporting Clipz!")
                    Text("Purchased \(purchasedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .trialing(let days):
                VStack(alignment: .leading) {
                    Text("Free trial: \(days) of 30 days remaining").font(.title3)
                    Text("When the trial ends, Clipz will be locked until you purchase.")
                        .font(.callout).foregroundStyle(.secondary)
                    featureList
                    purchaseButton
                }
            case .expired:
                VStack(alignment: .leading) {
                    Label("Trial ended", systemImage: "lock.fill")
                        .foregroundStyle(.red).font(.title3)
                    Text("Purchase Clipz to continue using clipboard history, notes, tasks, and AI-powered search.")
                        .font(.callout).foregroundStyle(.secondary)
                    featureList
                    purchaseButton
                }
            case .unknown:
                ProgressView()
            }

            Divider()
            Button("Restore Purchase") {
                Task { await container.licenseService.restorePurchases() }
            }
        }
        .task { await refresh() }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Unlimited clipboard history", systemImage: "infinity")
            Label("Full-text + AI search across images and documents", systemImage: "sparkles")
            Label("Password-protected backups", systemImage: "lock.shield")
            Label("Screenshot folder monitoring", systemImage: "camera.viewfinder")
            Label("One-time purchase, no subscription", systemImage: "checkmark.seal")
        }.padding(.vertical, 4)
    }

    private var purchaseButton: some View {
        Group {
            if let product = container.licenseService.product {
                Button {
                    Task { try? await container.licenseService.purchase() }
                } label: {
                    HStack {
                        Text("Unlock Clipz — \(product.displayPrice)")
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
```

### Locked tab placeholder (shown on non-Pro tabs when `state == .expired`)

```swift
struct LockedTabPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Purchase required", systemImage: "lock.fill")
        } description: {
            Text("Your 30-day trial has ended. Unlock Clipz to use this feature.")
        } actions: {
            Button("Go to Pro") {
                NotificationCenter.default.post(name: .selectProSettingsTab, object: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

Every settings tab except `ProSettingsTab` and `AboutTab` conditionally renders `LockedTabPlaceholder` when the license state is `.expired`. About remains visible so users can find support links.

Implementation details for `LicenseService`, `PaywallWindow`, trial tracking, and gating in swift_18.

### About

```swift
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 128, height: 128)
            Text("Clipz").font(.largeTitle.bold())
            Text("Version \(appVersion) (\(buildNumber))")
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link("Website", destination: URL(string: "https://clipz.tech")!)
                Link("Privacy Policy", destination: URL(string: "https://clipz.tech/privacy")!)
                Link("Support", destination: URL(string: "mailto:support@clipz.tech")!)
            }
            Text("© 2026 Clipz. All rights reserved.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
```

### Danger

```swift
struct DangerSettingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Form {
            Section("Storage") {
                StorageUsageView()
                Button("Vacuum database") {
                    Task { try? await container.database.vacuum() }
                }
            }

            Section("Erase all data") {
                Text("This permanently deletes all clipboard items, notes, tasks, and media. This cannot be undone.")
                    .foregroundStyle(.secondary)
                Button("Erase Everything…", role: .destructive) {
                    Task { await confirmAndErase() }
                }
            }
        }
    }

    private func confirmAndErase() async {
        // Match current app's captcha behavior: user must type a specific phrase.
        let captcha = await CaptchaPrompt.present(
            title: "Type DELETE EVERYTHING to confirm",
            expectedText: "DELETE EVERYTHING")
        guard captcha else { return }

        do {
            try await container.clipboardService.deleteEverything()
            try await container.notesService.deleteEverything()
            try await container.tasksService.deleteEverything()
            await AlertDialog.present(title: "Everything erased")
        } catch {
            await AlertDialog.present(title: "Error", message: error.localizedDescription)
        }
    }
}

struct StorageUsageView: View {
    @Environment(AppContainer.self) private var container
    @State private var usage: StorageUsage?

    var body: some View {
        Group {
            if let usage {
                VStack(alignment: .leading) {
                    Text("Database: \(ByteCountFormatter.string(fromByteCount: usage.dbBytes, countStyle: .binary))")
                    Text("Media files: \(ByteCountFormatter.string(fromByteCount: usage.mediaBytes, countStyle: .binary))")
                    Text("\(usage.itemCount) clips, \(usage.noteCount) notes, \(usage.taskCount) tasks")
                }
                .font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { usage = try? await container.clipboardService.storageUsage() }
    }
}
```

### Shared dialogs

Unified helpers for common prompts:

```swift
@MainActor
enum AlertDialog {
    static func present(title: String, message: String? = nil) async {
        let alert = NSAlert()
        alert.messageText = title
        if let m = message { alert.informativeText = m }
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

@MainActor
enum ConfirmDialog {
    static func present(title: String, message: String, confirm: String = "Confirm",
                        destructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let btn = alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        btn.hasDestructiveAction = destructive
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
enum CaptchaPrompt { … }
@MainActor
enum PasswordPrompt { … }
```

## Edge cases & gotchas

1. **Settings that need a restart** — e.g., changing SQLite pragmas. Surface with a "Restart to apply" banner inline. None of the current settings fall into this category.

2. **Toggle state drift** — if the user toggles a switch but the underlying action fails (e.g., denied permission), revert the toggle. All `.onChange` blocks save optimistically and roll back on error in a `Task`.

3. **Start-at-login status** — `SMAppService.mainApp.status` can be `.requiresApproval` after moving the app bundle. Surface a banner: "Approve Clipz in Login Items settings to enable auto-start."

4. **Retention shrink** — warn before deleting when the new period expires many items. Include an "undo" (via backup) suggestion in the dialog.

5. **Password entry for backup restore** — `SecureField` works; don't echo. Validate via `BackupService.checkPassword` before showing the confirm prompt.

6. **Danger-delete captcha** — plain type-the-phrase is fine; no image captcha needed.

7. **About links opening** — `NSWorkspace.shared.open` for `mailto:` works in sandbox; for `https:` the default browser opens.

8. **Resizing the settings window** — SwiftUI respects `.frame(width:, height:)`. If a tab's content overflows, wrap in `ScrollView`.

9. **Localization** — all strings hard-coded English in v1. Localize in v1.1 via standard `Localizable.strings`.

10. **Changes from outside Settings UI** — if the user toggles `monitorClipboard` from the tray menu, the Settings window's toggle doesn't update unless observed. Wire through `@Observable` on `SettingsStore` so changes propagate.

11. **Pro tab rendering before StoreKit is ready** — show a `ProgressView` until `Product.products(for:)` completes. Timeout after 5 s; show a "Retry" button.

12. **"Forever" retention option** — `Int.max` days. Surfaces as "Never delete" in the UI; countExpired always returns 0; cleanup is a no-op.

## MAS notes

- All settings storage is in-container (SQLite + UserDefaults). No entitlement concerns.
- StoreKit UI (Pro tab) is sandbox-standard; no extra setup.
- Dialogs are NSAlert / NSOpen(Save)Panel — all sandbox-compatible.
- Opening external links with `NSWorkspace.shared.open(URL(...))` — sandbox-compatible.

## Open questions

- **Custom themes** — dropped. Clipz follows the macOS system appearance only; no in-app picker or palette editor in v1 or beyond. If ever reconsidered, would require reintroducing swift_15's theme engine.
- **Import/export settings** — nice-to-have for moving between machines. Can be handled via backup restore in v1.
- **Keyboard shortcut customization** — deep pref-pane for rebinding all shortcuts. Out of v1.
- **Multiple user profiles** — one clipz per OS user account only. No in-app profiles.
