# swift_19 — Permissions & Entitlements

## Purpose

Complete map of every permission the app needs, how each is declared (entitlement vs Info.plist usage string vs runtime TCC prompt), and the user-facing flow for requesting it. Nothing should slip through — missing a usage string causes App Review rejection or a silent runtime crash.

## Current Electron entitlements (legacy)

`electron/entitlements.mac.plist`:

```xml
<key>com.apple.security.app-sandbox</key>                           <false/>
<key>com.apple.security.cs.allow-jit</key>                          <true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>   <true/>
<key>com.apple.security.cs.disable-library-validation</key>         <true/>
<key>com.apple.security.files.user-selected.read-write</key>        <true/>
```

Analysis:
- `app-sandbox=false` — ✗ must flip to `true` for MAS.
- JIT / unsigned memory / disabled library validation — ✗ all Electron runtime accommodations; none apply to native Swift.
- `files.user-selected.read-write` — ✓ keep.

**Everything else must be redesigned for MAS.**

## Target Swift entitlements

`ClipzApp/Clipz.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Sandbox (mandatory for MAS) -->
  <key>com.apple.security.app-sandbox</key>                        <true/>

  <!-- File system (user-granted via NSOpenPanel/NSSavePanel) -->
  <key>com.apple.security.files.user-selected.read-write</key>     <true/>
  <key>com.apple.security.files.bookmarks.app-scope</key>          <true/>

  <!-- StoreKit 2 purchase flow -->
  <key>com.apple.security.network.client</key>                     <true/>

  <!-- Reserved for future Share Extension / Services -->
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.tech.clipz.shared</string>
  </array>
</dict>
</plist>
```

### What's intentionally NOT declared

| Not declared | Why |
|---|---|
| `files.downloads.read-write` | Copy-to-Desktop uses NSSavePanel (implicit grant); no blanket access needed. |
| `files.pictures.read-write` | Same — user picks the screenshot folder explicitly. |
| `device.camera` | No camera access. |
| `device.microphone` | No microphone access. |
| `personal-information.addressbook` | No contacts access. |
| `personal-information.calendars` | No calendar access. |
| `personal-information.location` | No location. |
| `network.server` | No incoming connections. |
| `print` | No printing in v1. |
| `device.audio-input/output` | No audio capture. |
| `automation.apple-events` | Not needed; we don't drive other apps via AppleScript/OSA. |

Minimum entitlements = smoother App Review, better user trust, simpler privacy disclosures.

## Info.plist usage strings (privacy descriptions)

Strings appear in TCC prompts when permissions are requested. If any requested permission lacks a usage string, macOS crashes the process (with a helpful console log, but still a hard crash).

```xml
<!-- Desktop/Documents/Downloads: shown when user grants folder access via NSOpenPanel -->
<key>NSDesktopFolderUsageDescription</key>
<string>Clipz uses the Desktop folder you select to watch for new screenshots.</string>
<key>NSDocumentsFolderUsageDescription</key>
<string>Clipz uses Documents you drop into the app to add them to your clipboard history.</string>
<key>NSDownloadsFolderUsageDescription</key>
<string>Clipz uses Downloads you drop or select to add them to your clipboard history.</string>

<!-- Accessibility: shown by the system dialog when we first call AXIsProcessTrustedWithOptions -->
<!-- No Info.plist string needed; Apple supplies a generic message. -->

<!-- Apple Events: only if we ever script other apps. Not in v1. -->
<!-- <key>NSAppleEventsUsageDescription</key>
       <string>Clipz uses Apple Events to restore focus after a paste.</string> -->
```

Note: activating another app via `NSRunningApplication.activate()` to restore paste focus does **not** require the Apple Events entitlement — that's only for scripting (e.g., `osascript tell application "X"…`).

## Runtime TCC (Transparency, Consent, Control) grants

Beyond entitlements, macOS gates several capabilities at runtime via TCC — the user toggles these in **System Settings → Privacy & Security**.

### 1. Accessibility

- **When**: the first time the app tries to synthesize a Cmd+V keystroke (swift_10).
- **How**: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- **User flow**: OS shows system dialog → user must manually check the box in System Settings → app re-check.
- **MAS-compatible**: yes. TCC grants work in sandboxed apps.
- **If denied**: fall back to "item copied; press Cmd+V" toast. Paste button in UI shows a small banner "Grant Accessibility access to auto-paste" with an "Open Settings" link.
- **Documentation**: `AccessibilityPermission` enum (swift_10) encapsulates the flow.

### 2. Input Monitoring (optional — global hotkey)

- **When**: only if we register a global hotkey (e.g., Cmd+Shift+V) outside Accessibility's flows.
- **How**: `RegisterEventHotKey` (Carbon API) — works without Input Monitoring for standard modifier-based hotkeys. Only raw keyboard monitoring (`CGEvent.tapCreate`) needs Input Monitoring.
- **In v1**: skip Input Monitoring; use Carbon hotkey API for the global shortcut. No TCC prompt.

### 3. Full Disk Access (absolutely not)

- **When**: never. Full Disk Access is for apps that need to read arbitrary user data. Clipz does NOT qualify.
- **App Review stance**: requesting Full Disk Access on MAS is impossible via entitlement; the user must grant manually in Settings. Apps that depend on this are rejected from MAS.
- **Implication**: we never touch files outside the container except through user-selected/bookmarked URLs.

### 4. Screen Recording (not needed)

- Clipz does not capture screen content; only reads screenshot **files** the user's own screenshot hotkey produced. No screen recording permission.

### 5. Automation (not needed)

- Used only when one app sends Apple Events to another. Clipz doesn't scrip other apps. No automation permission.

## SMAppService (login item)

```swift
import ServiceManagement

extension AppDelegate {
    func installLoginItemIfRequested() {
        if LoginItemManager.isEnabled() {
            // Already enabled; nothing to do.
            return
        }
        // Do NOT auto-enable — user opts in via Settings toggle only.
    }
}

enum LoginItemManager {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func setEnabled(_ enabled: Bool) throws {
        let svc = SMAppService.mainApp
        if enabled {
            guard svc.status != .enabled else { return }
            try svc.register()
        } else {
            guard svc.status == .enabled else { return }
            try svc.unregister()
        }
    }
}
```

- **Entitlement**: none needed on macOS 13+ when using `SMAppService.mainApp`.
- **User flow**: when `register()` succeeds for the first time after an app move, macOS may report `.requiresApproval`. The Settings UI should check this status and direct the user to **System Settings → General → Login Items** if so.

## URL scheme registration (optional)

If we want `clipz://…` deep links:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>tech.clipz.app.url</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>clipz</string>
    </array>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
  </dict>
</array>
```

Not required for core functionality. Skip unless we add deep-linking features.

## Document types (optional)

If we want `.clipzbackup` files to open the app when double-clicked in Finder:

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Clipz Backup</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Owner</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>tech.clipz.backup</string>
    </array>
  </dict>
</array>

<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key>
    <string>tech.clipz.backup</string>
    <key>UTTypeDescription</key>
    <string>Clipz Backup</string>
    <key>UTTypeConformsTo</key>
    <array><string>public.zip-archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key>
      <array><string>clipzbackup</string></array>
      <key>public.mime-type</key>
      <array><string>application/x-clipz-backup</string></array>
    </dict>
  </dict>
</array>
```

Users double-click a backup → the app opens and offers to restore it. Implemented via `AppDelegate.application(_:open:)`.

## App Privacy (Apple's nutrition label)

For App Store Connect, declare:

- **Data Collection**: **None**. Clipz is local-first; no analytics, no telemetry, no third-party SDKs.
- **Tracking**: **No**. No cross-app tracking.
- **Privacy Manifest** (`PrivacyInfo.xcprivacy`): include with entries for:
  - `NSPrivacyAccessedAPITypes`:
    - `NSPrivacyAccessedAPICategoryUserDefaults` — reason `CA92.1` (legitimate use: app preferences).
    - `NSPrivacyAccessedAPICategoryFileTimestamp` — reason `C617.1` (displaying creation time).
    - `NSPrivacyAccessedAPICategorySystemBootTime` — only if we ever call `uptime()`. Probably skip.
    - `NSPrivacyAccessedAPICategoryDiskSpace` — reason `E174.1` (displaying storage usage).
  - `NSPrivacyCollectedDataTypes`: empty.
  - `NSPrivacyTracking`: false.

Privacy manifest template scaffolded in `Scripts/update-privacy-report.swift`.

## Code signing & runtime

**Automatic signing** via Xcode with your Apple Developer team handles:

- Code signing identity
- Provisioning profile (App Store distribution)
- Runtime hardened signing (required for MAS)

Manual xcconfig pins:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
ENABLE_HARDENED_RUNTIME = YES
CODE_SIGN_IDENTITY = Apple Distribution
```

No `CSC_NAME`, `SIGNING_IDENTITY`, `--no-verify`, `afterPack.cjs`, `remove-asar-integrity.js`, or any of the Electron-era signing hacks. MAS signing is fully automatic.

## App Sandbox — what *does* work

Common capabilities that require NO entitlement:

- NSPasteboard read/write (clipboard capture + paste) ✓
- NSVisualEffectView (vibrancy) ✓
- NSStatusItem (tray) ✓
- NSPopover ✓
- Core ML / Vision / PDFKit (inline ML) ✓
- SQLite (GRDB in container) ✓
- CryptoKit / Compression ✓
- StoreKit 2 (with `network.client`) ✓
- Accessibility API (with TCC grant) ✓
- Global hotkey via Carbon RegisterEventHotKey ✓
- SMAppService for login items ✓
- NSMetadataQuery on user-selected folders ✓
- DispatchSource file monitoring ✓ (on user-selected URLs)
- PDFKit / AVKit rendering ✓

## Test matrix

Before submission, verify every permission flow:

| Flow | Expected behavior |
|---|---|
| Fresh install → paste attempt | TCC prompt for Accessibility → user grants → paste works |
| TCC denied → paste attempt | Falls back to "copied; paste manually" toast |
| Screenshot monitoring enabled, no folder chosen | "Choose Folder" button prompts NSOpenPanel |
| Screenshot folder bookmark becomes stale | "Re-authorize" banner appears; re-opens NSOpenPanel |
| Copy to Desktop | NSSavePanel prompt → file saved to user-picked location |
| Backup create | NSSavePanel → file saved; no Desktop entitlement needed |
| Backup restore | NSOpenPanel → archive read; no Downloads entitlement needed |
| In-app purchase | StoreKit sheet → success → Pro unlocked |
| Restore purchases | StoreKit sync → entitlement refresh |
| Start at login | SMAppService register → login item added |
| App move after login-item enabled | Status becomes `.requiresApproval`; Settings UI surfaces re-auth hint |

## App Review notes (to include in submission)

Write a Review Notes section covering:

1. **Accessibility permission**: "Clipz needs Accessibility permission to auto-paste a selected clipboard item into the user's active app via a synthesized Cmd+V. Paste is only triggered when the user explicitly clicks an item in the tray popup. Auto-paste is optional — the app gracefully falls back to 'copied; paste manually' if permission is denied."
2. **Screenshot folder access**: "The user explicitly grants a folder via a standard NSOpenPanel. Monitoring is opt-in and shows the selected folder path in Settings."
3. **In-app purchase**: "The single non-consumable IAP 'Clipz Pro' ($14.99) unlocks Pro features: unlimited history, AI-powered search, encrypted backups."
4. **No tracking, no analytics, no cloud data transmission**: "Clipz is fully offline. No network calls beyond StoreKit purchase flow."
5. **No private APIs**: Vision/CoreML/PDFKit/StoreKit only.
6. **Test account** (if needed): not applicable — the Pro features are unlockable via sandbox IAP in StoreKit testing.

## Edge cases & gotchas

1. **First launch without internet** — StoreKit's `Product.products(for:)` fails. Pro tab shows error state with retry button. Trial state calculates fine from local `UserDefaults`.

2. **Accessibility grant revoked** — `AXIsProcessTrusted()` returns false on next paste attempt. Surface banner and fall back to toast.

3. **Sandbox container reset** (user deletes `~/Library/Containers/tech.clipz.app/`) — app behaves as fresh install: empty DB, fresh trial, no Pro entitlement until `AppStore.sync`.

4. **App move to another disk** — SMAppService login item may break. Detect `.requiresApproval` in Settings UI.

5. **macOS upgrades** — test on each major OS update; entitlement semantics occasionally change. Apple usually announces breaking changes one version ahead.

6. **Security-scoped bookmarks across system upgrades** — sometimes stale on major OS updates. Graceful re-auth flow handles it.

## Open questions

- **Declare `com.apple.security.network.client` only for licensed users?** — No; always needed. StoreKit refreshes entitlements at every launch regardless of state (trialing / expired / licensed), and the paywall's `Product.products(for:)` call also requires it.
- **Include `com.apple.security.files.user-selected.executable`?** — No; we never execute user-selected files.
- **Privacy manifest strictness** — Apple rolled this out in 2024. Audit carefully before submission; common omissions cause rejection.
- **Data-transmission declaration** — if a user opts into diagnostics emails or support, we might upload error logs. Not in v1; declare "data transmission: none" for launch.
