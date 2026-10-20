# swift_20 — Mac App Store Constraints

## Purpose

Consolidate every place where MAS's sandbox + App Review rules reshape the app vs the current Electron version. This is the single reference for "why doesn't X work like the old app?" questions and the checklist against which every shipped feature is audited.

## ⚠️ App Review hard rules — STRICTLY ENFORCED

**These rules are not suggestions. They are the minimum bar for any 1.0 submission and any subsequent update.** App Review is a **hard gate with no workaround** — we chose MAS-only distribution, so there is no fallback channel. A rejection on launch day means zero users can install, full stop.

Any PR that violates one of these rules MUST be blocked from merge. Any submission attempt that skips a pre-submission check MUST be aborted.

### HR-1. Submission timing buffer

- **MUST** submit to App Review **no less than 4 weeks** before any announced public launch date.
- **MUST** budget for **at least 3 rejection–fix–resubmit cycles** (each ~24–48 h review turnaround, plus engineering time).
- **MUST NOT** rely on expedited review. Apple caps this at roughly two per developer per year and declines routine requests.

### HR-2. Guideline 4.2 "Minimum Functionality" — differentiation

Clipboard managers are a crowded App Store category; Apple periodically rejects entries as "not sufficiently differentiated."

- **MUST** lead the App Store description with three concrete differentiators, all of which must actually function in the shipped binary:
    1. On-device Vision-powered image search (OCR text + scene/object tags + animal/human bboxes + barcodes — all searchable).
    2. Full-text search across clipboard content, OCR-extracted text in images, and PDF/document body text, unified into one result list.
    3. Integrated notes + todos with FTS, not a standalone clipboard history viewer.
- **MUST NOT** ship the app with any of those three features disabled, stubbed, or behind a feature flag off by default. During the 30-day trial the entire feature set is active (no partial access, no teasers); that is what the reviewer evaluates against 4.2.
- **MUST** provide at least 5 App Store screenshots, each showing real (non-placeholder, non-Lorem-Ipsum) content exercising one of these features.

### HR-3. Accessibility permission — reviewer friction

`CGEvent.post` for Cmd+V synthesis (swift_10) triggers App Review scrutiny; reviewers treat Accessibility as a potential keylogger vector.

- **MUST** use Accessibility **only** for user-initiated paste from the tray popover or the clipboard list context menu. Never for background automation, never for non-paste key events.
- **MUST** ship a graceful fallback: when `AXIsProcessTrusted()` returns false, show a non-modal toast "Copied — press Cmd+V to paste" and continue without synthesizing. The paste feature must be **optional**; core functionality (capture, browse, search, copy-to-clipboard) must work with Accessibility denied.
- **MUST** write a Review Notes paragraph explaining: *when* we prompt for Accessibility (first user-initiated paste), *what action* it enables (synthesize Cmd+V into previously-focused app), *why it is necessary* (auto-paste is a primary UX), and *what happens if denied* (fallback toast, no feature loss beyond auto-paste).
- **MUST NOT** call any AX API (`AXUIElementCreateSystemWide`, etc.) beyond `AXIsProcessTrusted` and `CGEvent.post`. Any deeper AX usage triggers a much stricter review bar.

### HR-4. Privacy nutrition label — zero margin for error

One wrong declaration on the App Privacy page is an automatic rejection that costs a cycle.

- **MUST** declare **Data Collection: None** and **Tracking: No** in App Store Connect.
- **MUST NOT** add any third-party SDK that collects, transmits, or persists data off-device. This explicitly excludes: analytics SDKs (Firebase, Mixpanel, Amplitude), crash-reporting SDKs (Sentry, Bugsnag, Crashlytics), attribution SDKs (Adjust, AppsFlyer), advertising SDKs, any SDK whose privacy manifest declares data collection.
- **MUST** ship a `PrivacyInfo.xcprivacy` privacy manifest declaring each Required Reason API we use (see swift_19) with the correct reason code.
- **MAY** use **MetricKit** and **StoreKit** (both first-party, privacy-safe) and nothing else that touches network.
- **MUST NOT** declare analytics "because maybe we'll add it later." The label we ship must be true for the binary we ship.

### HR-5. StoreKit IAP flow — reviewer executes every path

The reviewer will purchase `tech.clipz.app.pro`, then separately restore it on a fresh install. Both must work without any edge case crashing or silently no-op'ing.

- **MUST** test the purchase flow against a **clean Sandbox Apple ID** before every submission — not just StoreKit local testing in Xcode.
- **MUST** test Restore Purchases on a fresh install of the same build.
- **MUST** handle offline gracefully: if `Product.products(for:)` fails, the Pro tab and `PaywallWindow` show an explicit "Store unavailable — check your internet connection" state with a Retry button, not a blank/stuck spinner.
- **MUST** implement receipt refresh and entitlement observation so that refunds and family-sharing transfers demote access within one app session — including immediately swapping back to `PaywallWindow` if a refund lands while the app is running.
- **MUST NOT** surface any "buy on our website" or external-payment UI. Not even a mention. Guideline 3.1.1 violations are auto-rejections.
- **MUST** gate app usability exclusively via `LicenseService.isUsable` at the `WindowRouter`. Services (`ClipboardService`, `AnalysisService`, `BackupService`, etc.) do **not** contain per-feature license checks. No ad-hoc "trial check" scattered through call sites.

### HR-6. Trial disclosure — exact language required

Apple rejects vague or missing trial terms, and rejects harder when "free" appears without context.

- **MUST** state the trial duration and post-trial behavior in **three places**, identically:
    1. The in-app Pro tab (`ProSettingsTab` in swift_14): *"30-day free trial. After the trial, Clipz is locked until you complete a one-time purchase of $XX.XX. No subscription, no auto-renewal. Family Sharing enabled."*
    2. The `PaywallWindow` content (swift_18) and the menu-bar `TrayPaywallCard`.
    3. App Store Connect "Promotional Text", "Description", and "What's New" fields.
- **MUST** include the sentence *"After 30 days, the app requires a one-time in-app purchase to continue."* in the App Store description — reviewers scan for this.
- **MUST NOT** describe the app as "free" in the App Store listing without the trial/IAP clarification, per 3.1.2 and 5.1.1 guidance.
- **MUST NOT** bury the trial-ends-in-lockout behavior. If a reviewer can't find it in 10 seconds of reading the listing, it's not disclosed.

### HR-7. Private API hygiene

- **MUST NOT** use any underscore-prefixed Objective-C selector, private CoreGraphics/CoreAnimation symbol, or undocumented private framework.
- **MUST** run `nm -gU $BUILT_PRODUCTS_DIR/ClipzApp.app/Contents/MacOS/ClipzApp | grep -E '_[A-Z]{2,}_' | sort -u` as a build-phase check before archiving; flag any suspicious symbols for human review.
- **MUST NOT** rely on the `showSettingsWindow:` / `showPreferencesWindow:` selectors being public — they've been stable across macOS 13/14/15 but are technically undocumented. Wrap in `@objc` + `respondsToSelector` checks and keep a fallback path (direct window-open via AppDelegate routing).

### HR-8. App completeness at submission

- **MUST NOT** ship with any "Coming soon", placeholder screens, stub IAP products, broken links, or features advertised in App Store metadata that aren't functional in the binary.
- **MUST NOT** submit a build where any feature listed in swift_26 as ✅ Parity is actually ❌ or 🟡 in the shipped code. Either the code catches up or the checklist is updated *before* submission.
- **MUST** ensure the app launches to a usable state on a brand-new macOS 14 VM with no internet connection.

### HR-9. Review Notes template — mandatory submission artifact

Every App Store Connect submission MUST include a Review Notes section with at least these sections, filled in with specific detail:

```
## Permissions
### Accessibility (TCC)
When: First time the user taps an item in the tray popup to auto-paste.
Why: CGEvent.post Cmd+V into the previously-focused application.
Scope: Single Cmd+V keystroke per user click. No background monitoring,
       no arbitrary key synthesis.
Fallback: If denied, app shows "Copied — press Cmd+V to paste" toast
          and does not call any AX API again until the user manually
          grants in System Settings.

### Screenshot folder access (security-scoped bookmark)
When: User opts into screenshot monitoring in Settings and picks a folder
      via NSOpenPanel.
Scope: User-selected folder only. Nothing under ~/Desktop is read without
       explicit user grant via NSOpenPanel.

## In-App Purchase
Product ID: tech.clipz.app.pro (non-consumable, $XX.XX, Family Sharing on)
Trial: 30-day free trial on first launch. After trial, the app is locked
       and only the PaywallWindow + Settings > Pro + Settings > About are
       reachable. There is no free tier.
Unlocks: the entire app (clipboard history, notes, tasks, screenshot
         monitoring, AI search, encrypted backups).
Restore: via Restore Purchase button in Settings > Pro and on PaywallWindow.
Testable without credentials: yes, via StoreKit sandbox. Trial clock is
         stored in the Keychain; reviewers completing review within the
         trial window see the full app. For post-trial verification,
         reviewers can delete the Keychain entry or use a sandbox Apple ID
         with a test-purchased entitlement.

## Data Collection
None. App is fully offline except for StoreKit purchase flow.
No analytics, no telemetry, no third-party SDKs.

## ML / AI Features
On-device only via Apple Vision (VNRecognizeTextRequest,
VNClassifyImageRequest, VNRecognizeAnimalsRequest,
VNDetectHumanRectanglesRequest, VNDetectBarcodesRequest) and PDFKit.
No models bundled, no network calls for inference.
```

### HR-11. Hard-lockout trial specifically disclosed to reviewers

The 30-day trial + mandatory IAP model is legal under current Apple guidelines but requires explicit reviewer communication. Reviewers who encounter a locked app without clear trial disclosure file a 3.1.1 / 2.1 rejection.

- **MUST** include the App Review Notes block from swift_18 (the "Trial model" / "Purchase surface" / "Review account" / "No data collection" sections) verbatim in the submission's Review Notes field.
- **MUST** ensure the App Store listing's Description contains a standalone sentence describing the post-trial lockout (see HR-6).
- **MUST** ensure the app is fully functional on first launch so reviewers can evaluate the product within the trial window. Do not ship with an immediately-locked state, even as a stress test.
- **MUST** confirm before submitting that the bundled `tech.clipz.app.pro` IAP is in "Ready to Submit" state in App Store Connect and attached to the submission. Submitting the app binary without the attached IAP triggers an automatic rejection.
- **MUST NOT** describe the purchase with words like "upgrade" or "premium" that imply the free version continues. Use "Unlock Clipz" consistently in both the app and listing copy.
- **Contingency:** if App Review rejects the hard-lockout model, the documented fallback is an auto-renewable subscription with a 30-day intro free trial. This is a spec-level change — do not attempt a quick flip; revisit swift_18's IAP model section.

### HR-10. Go / no-go gate before every submission

Before hitting "Submit for Review" in App Store Connect, **every one** of the following MUST be verified on the exact archive being submitted:

- [ ] Build installs on a clean macOS 14 VM and launches without internet.
- [ ] Accessibility prompt appears on first paste attempt; denial fallback works.
- [ ] Screenshot folder picker produces a working bookmark; stale-bookmark re-prompt works.
- [ ] In-app purchase succeeds with a sandbox Apple ID.
- [ ] Restore Purchases succeeds on a fresh install with the same Apple ID.
- [ ] Trial countdown decrements correctly; `PaywallWindow` replaces the main window after 30 days. Verify by deleting the Keychain entry (`security delete-generic-password -s tech.clipz.app -a firstLaunchDate`) and back-dating via a clock-advance test, or by using the Debug-build-only `Reset Trial` menu item.
- [ ] `PaywallWindow` has no close button and `Cmd+W` quits the app (no way to bypass the lockout).
- [ ] Post-trial: Settings tabs other than Pro and About show `LockedTabPlaceholder`; no feature can be exercised until purchase.
- [ ] Clock ratchet works: setting the system clock backward does not restore trial days (Keychain `maxElapsedDays` counter holds).
- [ ] Swift_26 parity checklist has no false ✅ entries for shipped features.
- [ ] Privacy manifest `PrivacyInfo.xcprivacy` is present and covers every Required Reason API actually called.
- [ ] Review Notes section (HR-9) is filled in with specifics, not placeholders.
- [ ] Build number incremented (Scripts/bump-build.sh).
- [ ] No unexpected symbols in the binary (HR-7 nm check).

**If any box is unchecked, abort submission and fix first.** Cost of delay is one day. Cost of rejection is 2–7 days plus review fatigue.

## Why this matters

The Electron app runs **outside the sandbox** (verified in its `entitlements.mac.plist`, `app-sandbox=false`). That gives it the freedom to:

- Shell out to helper binaries
- Watch `~/Desktop` without user permission
- Synthesize keystrokes without TCC friction (user already had to grant Accessibility to robotjs once)
- Store license keys anywhere on disk
- Use disk-level hacks (e.g., `afterPack.cjs` stripping ASAR integrity)

**None of that works on MAS.** The Swift rewrite rebuilds every capability using only sandbox-legal patterns. This file enumerates each, what breaks, and what replaces it.

## The constraints, by capability

### 1. Clipboard capture

- **Works fine** under sandbox. NSPasteboard is not restricted.
- **No change from intuition**: the tray clipboard watcher in swift_03 works identically.
- **MAS advantage**: we get "Copied from Clipz" attribution free — the App Store-signed binary identity is visible to other apps via their own pasteboard-reader queries.

### 2. Screenshot folder monitoring

- **Breaks**: FSEvents on `~/Desktop` fails with permission error.
- **Replacement** (swift_04):
  1. User opts in via Settings toggle.
  2. NSOpenPanel prompts for the screenshot folder.
  3. Security-scoped bookmark stored.
  4. FSEvents/DispatchSource on the bookmarked URL.
- **User-facing change**: one additional click to grant the folder on first use. Explain clearly in Settings UI: "macOS requires us to ask for access to your screenshot folder."
- **MAS review angle**: explain in Review Notes that folder access is opt-in and user-selected.

### 3. Paste automation (Cmd+V synthesis)

- **Works** under sandbox **with Accessibility TCC grant** — same as every clipboard manager on MAS (Paste, Raycast-era, Maccy).
- **Replacement**: `CGEvent.post(…)` after `AXIsProcessTrustedWithOptions`.
- **First-run UX**: prompt for Accessibility the first time the user clicks an item in the tray popup. If declined, fall back to "Copied — press Cmd+V" toast.
- **MAS review angle**: list Accessibility usage in Review Notes with the specific user-initiated action it enables.

### 4. Helper binaries (live-text-extractor, obj-detection, pdf-extractor)

- **Breaks completely**. MAS forbids shipping standalone executables that run outside the app's own sandbox with their own entitlements.
- **Replacement** (swift_09): inline via Vision, Core ML, PDFKit in `ClipzML` package. Runs in the same sandbox as the main process.
- **Architectural win**: simpler deployment, one signing identity, no IPC, no process-spawning overhead, unified crash reporting.

### 5. On-device ML stack

- **All-Apple Vision APIs** — `VNClassifyImageRequest`, `VNRecognizeAnimalsRequest`, `VNDetectHumanRectanglesRequest`, `VNDetectBarcodesRequest`, `VNRecognizeTextRequest`, `PDFKit`. No bundled model weights; no third-party licensing concerns.
- **Works** under sandbox out of the box; no entitlement.
- **Bundle size**: near-zero ML contribution (Vision is a shared system framework).
- **MAS review angle**: Apple doesn't require ML-specific disclosures, but the App Privacy section must truthfully say "on-device processing only, no data collection."

### 6. robotjs for paste

- **Breaks**: robotjs is a native Node addon. We're not using Node at all. Replaced by `CGEvent.post` (swift_10).

### 7. AppleScript for file-path extraction

- **Not needed** in Swift. NSPasteboard's `readObjects(forClasses: [NSURL.self])` returns file URLs natively. We drop the AppleScript bridge entirely.
- **Bonus**: no more 2-second AppleScript timeout; file-URL reads are synchronous and instant.

### 8. Copy to Desktop (`copy-to-desktop`)

- **Breaks**: sandbox forbids writing to `~/Desktop` silently.
- **Replacement**: NSSavePanel → user picks destination (swift_10). The user-granted URL is sandboxed for write.
- **UX change**: "Copy to Desktop" now always shows a save panel. Pre-fills the destination to `~/Desktop` and the filename to the original name for minimal friction.

### 9. Global hotkey

- **Works** under sandbox via Carbon `RegisterEventHotKey` (swift_11).
- **No entitlement needed** for modifier-based hotkeys like Cmd+Shift+V.
- **Risk**: if the chosen hotkey is already bound by another app, registration fails silently. UI surfaces the conflict and lets the user pick another binding.

### 10. Login item (start-at-login)

- **Works** via `SMAppService.mainApp` (swift_19).
- **No entitlement needed** on macOS 13+.

### 11. Media file storage

- **Works** under sandbox. Container-scoped `Application Support/clipz/media/` (swift_16).
- **Benefit**: automatically cleaned up when the user "removes" the app via standard uninstall tooling.

### 12. License / Pro unlock

- **Breaks**: the `sha256(email + seed)` scheme is moot on MAS.
- **Replacement**: StoreKit 2 non-consumable IAP (swift_18). Apple handles purchase, refund, family sharing.
- **Win**: no seed leakage concern; no email collection; no out-of-band key distribution.

### 13. ASAR integrity, notarize.cjs, afterPack.cjs, sign-app.js

- **All irrelevant** under Xcode + MAS. Xcode Archive + automatic signing + upload to App Store Connect replaces the entire Electron packaging pipeline. No ASAR, no DMG, no notarization step (Apple notarizes during App Store processing).

### 14. Certificates in git (`cert.pem`, `DeveloperID*.cer`, etc.)

- **Drops entirely**. Xcode-managed automatic signing uses your Apple Developer team's certificates from Keychain. Nothing checked into git.
- **Action**: rotate any exposed certs, purge from git history via `git filter-repo`.

### 15. Debug window / performance monitor

- **Works** but disabled in App Store Release builds by default. Ship it only behind `#if DEBUG || INTERNAL_BUILD`. Apple sometimes flags "hidden" debug UIs; keep the shortcut well-documented in commit history + review notes if kept.

### 16. WebSecurity disabled / custom URL schemes

- Electron's `webSecurity: false` (letting `file://` URLs cross-origin-load) has no Swift equivalent; we use native file URLs which don't have a same-origin model.
- Custom URL scheme `clipz://` can be registered (swift_11) without additional entitlement; used for deep-linking into specific items.

### 17. IndexedDB / QueryCache in renderer

- **Drops**. In-process SQLite is fast enough without the renderer cache. Fewer moving parts; eliminates the "stale cache across app updates" bug category entirely.

### 18. Google Drive types (`@types/gapi*`)

- **Drops**. No Drive integration in current app; types shipped but no implementation. Dropped from the Swift rewrite.
- If added later: would need `com.apple.security.network.client` (already declared) and a Google OAuth flow with `ASWebAuthenticationSession` for the sign-in pop-up. Non-trivial; defer.

### 19. Archiver / unzipper libs for backup

- Node's `archiver` + `unzipper` → Swift `ZIPFoundation` (swift_17). Pure-Swift, no native deps.

### 20. better-sqlite3

- → GRDB.swift. Full Swift ergonomics; better FTS5 support; built-in migration system.

### 21. WebPack / Vite

- **All dropped**. No JS build.

### 22. Electron-builder + notarize.cjs

- **All dropped**. Xcode handles everything.

## Known App Review pitfalls

### Accessibility justification

Apple's review team flags apps that ask for Accessibility without clear user-initiated action. Our paste flow is explicitly user-triggered (tap on item in popup). Clearly document this in Review Notes.

### Analytics / tracking

**Don't ship analytics in v1.** Even innocuous SDKs (Firebase, Sentry) trigger extensive privacy manifest review. Keep the app zero-tracking; add MetricKit (first-party, privacy-safe) only if needed.

### Private APIs

Apple scans binaries for private API symbols. Things to avoid:

- `_CGSSetAppLoggedInToiCloud` and similar underscore-prefixed Core Graphics symbols
- `-[NSApplication _appCanQuit]` and other underscore-prefixed Cocoa methods
- Direct use of `objc_msgSend` with private selectors

Our implementation uses only public APIs.

### JavaScript / WebViews

Not used. If we ever embed a WebView for a feature, use `WKWebView` with `allowsJavaScript: false` unless explicitly needed.

### In-app purchase vs external payment

All Pro unlocks go through StoreKit. Don't present any "buy on our website" UI; Apple rejects. Exception: a single link to a privacy policy is fine.

### App completeness

- No placeholder screens
- No "Coming soon" banners for features declared in App Store Connect description
- No beta features that aren't actually shippable

### Free trial disclosure

Ensure trial terms are clearly explained in the Pro Settings tab, the `PaywallWindow`, and the App Store listing: "30-day free trial. After the trial, the app is locked until you complete a one-time $14.99 purchase. No subscription."

### App Store screenshots

5–10 screenshots showing:

1. Main clipboard view with real (non-Lorem-Ipsum) content
2. Search with highlighted match
3. Image item with OCR result
4. Settings → Pro tab (showing the unlock flow)
5. Notes editor
6. Tray popover
7. Backup in progress

### App Store description

Highlight:

- 100% on-device (no cloud)
- AI-powered search (explain it's local Vision/Core ML, not "AI" in the hyped sense)
- Native — no Electron, small footprint
- 30-day free trial, one-time purchase to unlock (no subscription)

Avoid superlative claims ("best clipboard manager") that Apple flags.

## Checklist before submission

- [ ] Every entitlement in swift_19 is declared correctly
- [ ] Every privacy usage string is present
- [ ] Privacy Manifest `PrivacyInfo.xcprivacy` committed
- [ ] App Privacy details filled in App Store Connect: data collection = none, tracking = no
- [ ] StoreKit product `tech.clipz.app.pro` ready in App Store Connect
- [ ] Test Accessibility flow on a clean VM
- [ ] Test screenshot folder flow on a clean VM
- [ ] Verify app launches with zero Internet (trial mode works offline)
- [ ] Verify Purchase → Pro unlocks → Restart → still Pro
- [ ] Verify Restore Purchases with a fresh Apple ID
- [ ] Archive build signs automatically with distribution profile
- [ ] No private API symbols in binary (Xcode build phase with `nm` check)
- [ ] Review Notes drafted in App Store Connect explaining Accessibility + screenshot folder + IAP
- [ ] 5+ App Store screenshots prepared (all real data, no placeholders)
- [ ] Version number is `1.0.0`, build is incremented
- [ ] Deep link to website, privacy policy, and support email on About screen resolve correctly
- [ ] Cert rotation done on original `cert.pem` (swift_21)

## MAS-specific error handling

Several sandbox failures are silent — the call "succeeds" but the effect doesn't happen. Guard against these:

```swift
// Wrong: assume file was written
try data.write(to: url)

// Right: check the URL is within sandbox reach
guard FileStore.isContainerScoped(url) || BookmarkStore.hasActiveScope(url) else {
    throw SandboxError.notGranted(url)
}
try data.write(to: url)
```

Add `Log.error("Sandbox permission denied for: \(url)")` at every file-touching helper so debugging is easy when users report "it says it saved but the file isn't there."

## Open questions

- **Trial enforcement strength** — MAS apps can't really "enforce" a trial because the user can delete the UserDefaults key. Accept this; the honest user flow is what we design for.
- **Bug reports / diagnostics** — if we want remote diagnostics, MetricKit is the approved path. Its output is privacy-safe (aggregate metrics). Defer to v1.1.
- **Notifications** — the current app has no notifications. If added (e.g., "Backup complete"), use `UserNotifications` framework; needs `UNUserNotificationCenter.requestAuthorization`. Scope creep for v1.
- **Alternative to MAS?** — If any capability becomes impossible, the fallback is Developer ID + notarized DMG outside MAS. Last resort: splits the audience and doubles the support burden. Try hard to avoid.
