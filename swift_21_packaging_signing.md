# swift_21 — Packaging, Signing, and App Store Submission

## Purpose

Define the end-to-end flow from `git push` to "ready in App Store Connect for review". Replaces the sprawling Electron packaging pipeline (build.py, build.sh, afterPack.cjs, sign-app.js, notarize.cjs, notarize-app.cjs, notarize-dmg.cjs, create-dmg.js, remove-asar-integrity.js, etc.) with Apple's standard Xcode + App Store Connect flow — which is so much simpler the diff is the point.

## What the Electron pipeline did (and we no longer need)

From the current repo:

1. `npm run build:native` — rebuild native addon with node-gyp
2. `tsc -b && webpack --mode production` — bundle React
3. `electron-builder` — package into `.app`
4. `afterPack.cjs` — strip ASAR integrity from Info.plist, codesign helper binaries
5. `sign-app.js` / `@electron/osx-sign` — sign the app with Developer ID
6. `notarize.cjs` / `@electron/notarize` — submit to Apple for notarization, wait for ticket, staple
7. `create-dmg.js` — build DMG installer
8. Distribute DMG via GitHub releases

**All of this goes away** on Mac App Store. The full flow becomes: Archive → Upload → Submit.

## Target Swift pipeline

```
┌──────────────────────┐
│  git push to main    │
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  CI: xcodebuild test │  ← swift-test + xcodebuild test on ubuntu/macOS
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  git tag v1.0.0      │
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  CI: Archive         │  ← xcodebuild archive -scheme ClipzApp
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  CI: Upload to       │  ← xcrun altool --upload-app (or fastlane pilot)
│  App Store Connect   │     with API key
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  App Store Connect:  │  ← Apple performs notarization + static analysis here
│  Processing (30 min) │
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  TestFlight + Submit │  ← Manual click in App Store Connect
│  for Review          │
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  Apple Review        │  ← Typically 24–48 h
│  (manual)            │
└─────────┬────────────┘
          ▼
┌──────────────────────┐
│  Released to MAS     │
└──────────────────────┘
```

## Xcode configuration

### Project-level build settings (via `Config/AppStore.xcconfig`)

```
// AppStore.xcconfig
PRODUCT_BUNDLE_IDENTIFIER  = tech.clipz.app
PRODUCT_NAME               = Clipz
DEVELOPMENT_TEAM           = YOUR_TEAM_ID
CODE_SIGN_STYLE            = Automatic
CODE_SIGN_IDENTITY         = Apple Distribution
ENABLE_HARDENED_RUNTIME    = YES
MACOSX_DEPLOYMENT_TARGET   = 14.0
SWIFT_VERSION              = 5.10
ENABLE_USER_SCRIPT_SANDBOXING = YES

MARKETING_VERSION          = 1.0.0
CURRENT_PROJECT_VERSION    = 1
```

`MARKETING_VERSION` is the human-visible `1.0.0`. `CURRENT_PROJECT_VERSION` is the build-number integer; every submission must increment.

### Schemes

- **ClipzApp** — Debug config, used for local dev + running in Xcode.
- **ClipzApp (Release)** — Release config, for manual release testing.
- **ClipzApp (App Store)** — AppStore config, the one that archives for submission.

### Build phases (minimal)

1. **Compile Sources** — auto
2. **Copy Bundle Resources** — auto (Assets.xcassets, Clipz.storekit exempted from Release)
3. **Embed Frameworks** (if any SPM binary deps) — auto
4. **Run Script: Privacy Manifest Lint** — optional, runs `Scripts/update-privacy-report.swift` to validate `PrivacyInfo.xcprivacy`

No "copy helper binaries" phase — we don't ship helpers.
No "strip ASAR integrity" phase — no ASAR.
No "run notarize.cjs" phase — handled by App Store Connect after upload.

## Certificates

Xcode automatic signing pulls these from your Apple Developer account:

1. **Apple Distribution** certificate (for App Store submissions)
2. **Mac App Store Distribution** provisioning profile (for `tech.clipz.app`)
3. **Developer ID Application** (only if also shipping outside MAS — skip for v1)

Certificates live in your Keychain. **Nothing in git.** The old Electron repo's checked-in `cert.pem`, `developerID_application.cer`, etc. have no counterpart here.

### Cert rotation for the old exposed key

Before shipping:

1. In Apple Developer → Certificates, identify the Developer ID Application cert that matches the public `developerID_application.cer`.
2. **Revoke** it. Any DMG signed with that cert is invalidated; it's already released under GitHub so damage is limited.
3. Reissue a new Developer ID cert if needed. For MAS-only shipping, only **Apple Distribution** matters.
4. `git filter-repo --path cert.pem --invert-paths` to strip from history.
5. Force-push **only after coordinating with any collaborators** — rewriting history is disruptive.

## ⚠️ Pre-archive gate — non-negotiable

**Before running Product → Archive, every requirement in `swift_20` "App Review hard rules HR-1 through HR-10" MUST be satisfied.** Specifically:

- HR-1 submission timing buffer met (≥ 4 weeks before any announced launch)
- HR-7 private-API symbol scan clean
- HR-8 no placeholder features, no broken swift_26 parity claims
- HR-9 Review Notes draft ready
- HR-10 go/no-go checklist fully ticked against the exact archive being submitted

Skipping the gate to "save time" is a net loss: one rejection cycle is 2–7 days and eats into the 4-week buffer.

## Archive flow (local)

Manually:

```
Product → Archive (with scheme "ClipzApp (App Store)")
```

Xcode:

1. Builds with AppStore config
2. Codesigns with Apple Distribution cert
3. Embeds provisioning profile
4. Produces `.xcarchive` in `~/Library/Developer/Xcode/Archives/`

Open Organizer (`Window → Organizer`):

1. Select archive
2. "Distribute App" → "App Store Connect" → "Upload"
3. Xcode uploads via altool over the API

Alternatively, from CLI:

```bash
xcodebuild archive \
    -scheme "ClipzApp (App Store)" \
    -archivePath build/Clipz.xcarchive \
    -destination "generic/platform=macOS"

xcodebuild -exportArchive \
    -archivePath build/Clipz.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist Config/ExportOptions.plist
```

`ExportOptions.plist`:

```xml
<plist>
<dict>
  <key>method</key> <string>app-store</string>
  <key>teamID</key> <string>YOUR_TEAM_ID</string>
  <key>uploadBitcode</key> <false/>
  <key>compileBitcode</key> <false/>
  <key>uploadSymbols</key> <true/>
</dict>
</plist>
```

Then upload:

```bash
xcrun altool --upload-app -f build/export/ClipzApp.pkg \
    --type macos \
    --apiKey "$APP_STORE_CONNECT_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
```

## CI via GitHub Actions

`.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  archive:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Install cert + profile
        uses: apple-actions/import-codesign-certs@v2
        with:
          p12-file-base64: ${{ secrets.APP_STORE_CERT_P12 }}
          p12-password: ${{ secrets.APP_STORE_CERT_PASSWORD }}

      - name: Install provisioning profile
        uses: apple-actions/download-provisioning-profiles@v2
        with:
          bundle-id: tech.clipz.app
          issuer-id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
          api-key-id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          api-private-key: ${{ secrets.APP_STORE_CONNECT_KEY }}

      - name: Bump build number
        run: Scripts/bump-build.sh

      - name: Archive
        run: |
          xcodebuild archive \
            -scheme "ClipzApp (App Store)" \
            -archivePath build/Clipz.xcarchive \
            -destination "generic/platform=macOS"

      - name: Export
        run: |
          xcodebuild -exportArchive \
            -archivePath build/Clipz.xcarchive \
            -exportPath build/export \
            -exportOptionsPlist Config/ExportOptions.plist

      - name: Upload to App Store Connect
        uses: apple-actions/upload-testflight-build@v1
        with:
          app-path: build/export/ClipzApp.pkg
          issuer-id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
          api-key-id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          api-private-key: ${{ secrets.APP_STORE_CONNECT_KEY }}
```

Secrets to configure in GitHub Actions:

- `APP_STORE_CERT_P12` — Apple Distribution cert exported as `.p12`, base64-encoded
- `APP_STORE_CERT_PASSWORD` — the `.p12` password
- `APP_STORE_CONNECT_KEY_ID` — from App Store Connect → Users and Access → Keys
- `APP_STORE_CONNECT_ISSUER_ID` — same
- `APP_STORE_CONNECT_KEY` — the private `.p8` file contents

## Scripts/bump-build.sh

```bash
#!/usr/bin/env bash
set -e
CONFIG=Config/AppStore.xcconfig
CURRENT=$(grep CURRENT_PROJECT_VERSION $CONFIG | awk '{print $3}')
NEXT=$((CURRENT + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT/CURRENT_PROJECT_VERSION = $NEXT/" $CONFIG
echo "Build bumped: $CURRENT → $NEXT"
```

Run before every archive. CI commits the bump back to `main` via a separate step.

## Testing releases

### TestFlight

Once an archive is uploaded and processed, App Store Connect shows it in the TestFlight tab.

- **Internal testers** (up to 100) — your team. No review needed.
- **External testers** (up to 10,000) — requires a one-time TestFlight review by Apple (much lighter than App Review).

Create test groups in App Store Connect; testers install via the TestFlight Mac app.

### App Review

After TestFlight validation, **Submit for Review** in the app's version tab. Apple reviews typically within 24–48 hours. Items to include:

- **Review Notes** — the essay we drafted in swift_20.
- **Demo account** — not needed for a local-only app; state explicitly.
- **IAP config** — ensure `tech.clipz.app.pro` is in "Ready to Submit" state.

Rejections happen — the common ones for clipboard managers are:

- **Accessibility permission request without clear justification** — mitigation: review notes.
- **App not functional on first launch** — mitigation: ensure trial starts immediately, items list shows the welcome item.
- **App collects data without privacy disclosure** — mitigation: we don't collect.

## Phased release

Once approved, enable phased release in App Store Connect:

- Day 1: 1% of users get the update
- Day 2: 2%
- Day 3: 5%
- Day 4: 10%
- Day 5: 20%
- Day 6: 50%
- Day 7: 100%

Provides time to notice crash reports from MetricKit before the whole userbase updates.

## Crash reports

Via **MetricKit**:

```swift
import MetricKit

final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            // Write to file; optionally upload with user consent
            try? data.write(to: crashLogURL())
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let hang = payload.hangDiagnostics?.first {
                // Log hang
            }
            if let crash = payload.crashDiagnostics?.first {
                // Log crash
            }
        }
    }
}
```

In v1, crash logs stay local. In v1.1, add an optional "Email crash report to support" button in Settings → About → Diagnostics.

## Version bump discipline

After every successful release:

1. Tag: `git tag v1.0.X`
2. Increment `MARKETING_VERSION` in `Config/AppStore.xcconfig` to prep next dev cycle (`1.0.X+1-dev`)
3. Write changelog entry (even informally)
4. Merge to main

No version drift between files — single source of truth is `Config/AppStore.xcconfig` (the old repo had 3+ sources of truth, a lesson learned).

## App Store listing

One-time setup in App Store Connect:

- **Name**: Clipz
- **Subtitle**: 30-char marketing tagline (e.g., "AI clipboard manager")
- **Primary Category**: Productivity
- **Secondary Category**: Utilities
- **Description**: long-form feature list (limit 4000 chars)
- **Keywords**: 100-char comma-separated (e.g., "clipboard, snippet, history, paste, ocr, search, productivity")
- **Support URL**: https://clipz.tech/support
- **Marketing URL**: https://clipz.tech
- **Privacy Policy URL**: https://clipz.tech/privacy
- **Price**: Free (IAP to unlock Pro — see swift_18)
- **Age Rating**: 4+ (no objectionable content)
- **Copyright**: "© 2026 Clipz"

## Rollback plan

If a bad build reaches production:

1. In App Store Connect → Version tab → "Remove from Sale" (pauses new downloads).
2. Submit hotfix: bump build, archive, upload, expedited review request.
3. Use Apple's "Expedited Review" sparingly — Apple limits to 1–2 per year and requires justification.

Users who already downloaded the bad version can't auto-downgrade; need to wait for the fix.

## Edge cases & gotchas

1. **Archive with wrong scheme** — accidentally archiving "ClipzApp (Release)" (Developer ID signing) upload to App Store Connect fails. Always use the "App Store" scheme for submissions.

2. **Forgetting to bump build number** — upload rejected with "build number must be greater than previous". CI script prevents this.

3. **Provisioning profile mismatch** — Xcode automatic signing usually handles this. For CI, the `apple-actions/download-provisioning-profiles` step keeps it synced.

4. **Keychain access during CI** — importing the `.p12` cert locks if no password is provided; CI step uses `security unlock-keychain` after import.

5. **Flaky StoreKit in Xcode** — if the `.storekit` config file becomes corrupt, StoreKit testing in Xcode silently returns empty product list. Re-sync via Products menu.

6. **App size** — no bundled ML model (Apple Vision is a shared system framework), so bundle stays ≤ 30 MB comfortably. MAS's 200 MB Wi-Fi-only-download threshold isn't a concern unless we add heavy assets in a future release.

7. **Localization files** — v1 is English only. App Store Connect requires at least English metadata. Add more localizations in v1.1 with `.lproj` directories.

## MAS notes

Already covered in swift_19 and swift_20. This file is the mechanics; those files are the rationale.

## Open questions

- **Fastlane vs raw xcodebuild** — fastlane's `pilot`, `match`, `deliver` simplify CI significantly. Worth the dependency for a solo dev? Probably yes. Decide before CI setup.
- **Beta channel outside TestFlight** — not easy on MAS (can't distribute out-of-store without splitting signing strategies). Use TestFlight's external tester flow for beta.
- **Localizing the App Store listing** — defer until non-English support is added to the app itself.
- **App Store analytics** — Apple provides impression/download/conversion stats. Use those; no third-party analytics.
