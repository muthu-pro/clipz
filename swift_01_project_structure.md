# swift_01 — Project Structure

## Purpose

Concrete Xcode project layout for the Swift rewrite: targets, schemes, Swift packages, build configurations, asset catalogs, and folder conventions.

## Current Electron layout (for reference)

The current app mixes `electron/`, `src/`, `website/`, a dozen root-level `.md` decision docs, native addon sources, checked-in certs, Python build scripts, and two bundler configs. **None of this carries over.** The Swift rewrite starts in a fresh repository with no build pipeline, no `dist/`, no `node_modules`, no Webpack/Vite duality.

## Swift project skeleton

```
clipz-mac/                              # new repo, git init from scratch
├── ClipzApp.xcodeproj                  # Xcode project
├── ClipzApp/                           # app target
│   ├── App.swift                       # @main struct
│   ├── AppDelegate.swift               # NSApplicationDelegate bridge
│   ├── AppContainer.swift              # composition root (DI)
│   ├── Info.plist
│   ├── Clipz.entitlements
│   ├── Assets.xcassets/
│   │   ├── AppIcon.appiconset/
│   │   ├── TrayIconLight.imageset/
│   │   ├── TrayIconDark.imageset/
│   │   ├── Theme-LightPlus/            # named colors per theme
│   │   │   ├── BackgroundColor.colorset
│   │   │   ├── TextColor.colorset
│   │   │   └── … (21 named colors)
│   │   └── Theme-GruvboxDark/
│   └── Preview Content/
│       └── Preview Assets.xcassets/
├── Packages/
│   ├── ClipzCore/
│   │   ├── Package.swift
│   │   ├── Sources/ClipzCore/
│   │   └── Tests/ClipzCoreTests/
│   ├── ClipzML/
│   │   ├── Package.swift
│   │   ├── Sources/ClipzML/
│   │   ├── Resources/
│   │   │   └── image_tag_synonyms.json
│   │   └── Tests/ClipzMLTests/
│   └── ClipzUI/
│       ├── Package.swift
│       ├── Sources/ClipzUI/
│       ├── Resources/
│       │   └── Media.xcassets/         # icon art, placeholder images
│       └── Tests/ClipzUITests/
├── Tests/
│   └── ClipzAppUITests/                # XCUITest for end-to-end flows
├── Scripts/
│   ├── bump-build.sh                   # CI build-number bumper
│   └── update-privacy-report.swift     # Apple privacy manifest helper
├── docs/                               # design/architecture notes
│   └── ADR/                            # architecture decision records
├── .gitignore
├── .swiftlint.yml
├── .swiftformat
└── README.md
```

## Xcode targets

1. **ClipzApp** — the shipped macOS app (target type: macOS App, product type: Application)
2. **ClipzAppUITests** — XCUITest target
3. **(Each SPM package contributes its own test target)**

No share-extensions, no widgets, no helper XPC services — the sandbox change means every capability must live in the main app. If the debug/performance window is kept, it's an in-app window, not a separate target.

## Swift Packages — `Package.swift` outlines

### `Packages/ClipzCore/Package.swift`

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipzCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzCore", targets: ["ClipzCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "ClipzCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ClipzCoreTests",
            dependencies: ["ClipzCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
```

### `Packages/ClipzML/Package.swift`

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipzML",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzML", targets: ["ClipzML"])
    ],
    dependencies: [
        .package(path: "../ClipzCore")
    ],
    targets: [
        .target(
            name: "ClipzML",
            dependencies: ["ClipzCore"],
            resources: [
                .process("Resources/image_tag_synonyms.json")
            ]
        ),
        .testTarget(
            name: "ClipzMLTests",
            dependencies: ["ClipzML"],
            resources: [.process("Fixtures")]
        )
    ]
)
```

Note: `.process` lets Xcode track the JSON for resource generation. `ClipzML` ships no binary ML model — all inference runs through Apple's built-in Vision framework, which is a shared system dylib and contributes nothing to bundle size.

### `Packages/ClipzUI/Package.swift`

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipzUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipzUI", targets: ["ClipzUI"])
    ],
    dependencies: [
        .package(path: "../ClipzCore"),
        .package(path: "../ClipzML")
    ],
    targets: [
        .target(
            name: "ClipzUI",
            dependencies: ["ClipzCore", "ClipzML"]
        ),
        .testTarget(
            name: "ClipzUITests",
            dependencies: ["ClipzUI"]
        )
    ]
)
```

## Build configurations

Three Xcode build configs on the app target:

1. **Debug** — `DEBUG` Swift flag, full logging, disabled code signing when possible, dev StoreKit configuration file so IAP flows test against sandbox
2. **Release** — optimization `-O`, assertions off, release StoreKit product identifiers, full signing
3. **AppStore** — same as Release but with bitcode stripping, full dSYM upload, and the distribution profile. Used only by the `Archive` scheme

Match with an `xcconfig` per config (`Config/Debug.xcconfig`, `Config/Release.xcconfig`, `Config/AppStore.xcconfig`) so version bumping, team ID, and bundle ID are version-controlled separately from the `.pbxproj`.

## Schemes

- **ClipzApp** — default, builds + runs app (Debug)
- **ClipzApp (App Store)** — archives against the AppStore config
- **ClipzCore-Package**, **ClipzML-Package**, **ClipzUI-Package** — auto-generated by Xcode for each SPM
- **AllTests** — aggregates all three package test targets + ClipzAppUITests

## Info.plist policy

Single `ClipzApp/Info.plist`, version pinned via xcconfig:

```xml
<key>CFBundleName</key>               <string>Clipz</string>
<key>CFBundleIdentifier</key>         <string>tech.clipz.app</string>
<key>CFBundleShortVersionString</key> <string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>            <string>$(CURRENT_PROJECT_VERSION)</string>
<key>LSMinimumSystemVersion</key>     <string>14.0</string>
<key>LSUIElement</key>                <false/>  <!-- shows in Dock; see note -->
<key>NSHumanReadableCopyright</key>   <string>© 2026 Clipz. All rights reserved.</string>

<!-- Privacy usage descriptions — required when entitlements reach these scopes -->
<key>NSDesktopFolderUsageDescription</key>
  <string>Clipz reads the Desktop folder to detect newly captured screenshots.</string>
<key>NSDocumentsFolderUsageDescription</key>
  <string>Clipz reads Documents to import files dragged into the tray.</string>
<key>NSAppleEventsUsageDescription</key>
  <string>Clipz restores focus to the previous app when pasting.</string>
```

Notes:

- `LSUIElement` is `false` (Dock icon shown). The user's `setDockIcon` preference toggles **at runtime** via `NSApp.setActivationPolicy(.accessory | .regular)` — this matches the current Electron behavior of a user-controllable dock/tray duality.
- All other privacy-sensitive usage descriptions are added only when the corresponding entitlement is enabled. See swift_19.

## Entitlements (`Clipz.entitlements`) — App Store config

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>                           <true/>
  <key>com.apple.security.files.user-selected.read-write</key>        <true/>
  <key>com.apple.security.files.bookmarks.app-scope</key>             <true/>
  <key>com.apple.security.network.client</key>                        <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.tech.clipz.shared</string>
  </array>
</dict>
</plist>
```

Full rationale + additions (Accessibility via TCC, SMAppService nuances) live in `swift_19`. Compare with the current Electron `electron/entitlements.mac.plist` — the Electron file has `app-sandbox=false`, `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation` — every one of these must go away for MAS.

## Asset catalogs

- **`Assets.xcassets`** at app level: `AppIcon`, tray icons, launch image (no longer needed on macOS but Xcode still scaffolds).
- **Per-theme color sets** as separate folder groups (e.g., `Theme-LightPlus/`). 21 named colors per theme, matching the fields in `src/themes.ts`. These are **universal** colors, not Light/Dark appearance pairs — each *theme* is its own full palette, and `NSAppearance` on a window chooses between the two themes rather than Apple's built-in light/dark. This is intentional: the current app's theming already decouples user-selected theme from system light/dark.
- **Tray icons** as template images (`Template` suffix in image set name) so macOS inverts them automatically based on menubar appearance. This replaces the current app's `getTrayIconPath(themeKey)` logic in `electron/main.js`.

## Folder conventions

Inside `Sources/ClipzCore/`, follow these rules:

- One public type per file, file name matches type name (e.g., `ClipboardItem.swift` contains `struct ClipboardItem`).
- Extensions for protocol conformance go in `FooName+ProtocolName.swift` (e.g., `ClipboardItem+FetchableRecord.swift` for GRDB).
- Internal helpers nested inside their parent type when they don't deserve their own file.
- No `Utilities.swift` catch-all; give utilities specific homes (`ContentHasher.swift`, `Debouncer.swift`).
- Tests mirror source layout (`Tests/ClipzCoreTests/Models/ClipboardItemTests.swift` for `Sources/ClipzCore/Models/ClipboardItem.swift`).

## Git hygiene

`.gitignore` is strict from the start:

```
# macOS
.DS_Store

# Xcode
build/
DerivedData/
*.xcuserstate
xcuserdata/
.swiftpm/

# Swift Package Manager
Package.resolved  # keep committed only at root; ignore in sub-packages

# Build products
*.ipa
*.xcarchive
*.dSYM.zip

# Secrets
*.p12
*.p8
*.cer
*.pem
*.mobileprovision
*.certSigningRequest
.env
.env.*

# StoreKit testing
*.storekit  # intentionally committed; keeping line to flag if this ever changes
```

**Key lessons from the Electron repo, hard-enforced here:**

- Never commit `cert.pem` or any `.cer` file (Electron repo currently has all of them checked in, including the developer ID cert).
- Never commit `.env` (Electron repo got this right).
- No `*.log` files committed (the Electron repo has `afterpack-debug.log` and `notarize-debug.log` committed — both contain build machine paths and credential checks).

## Lint + format

- **SwiftLint** (`.swiftlint.yml`) — strict-but-reasonable config; max line length 160, force_unwrapping error, trailing_whitespace warning.
- **SwiftFormat** (`.swiftformat`) — run on commit via a pre-commit hook; consistent style across PRs.
- Run both in CI; a PR that fails either blocks merge.

## Scripts

Only these shell scripts survive from the Electron repo concept:

- `Scripts/bump-build.sh` — increments `CURRENT_PROJECT_VERSION` in `Config/AppStore.xcconfig`. Called by CI before archive.
- `Scripts/update-privacy-report.swift` — generates/validates `PrivacyInfo.xcprivacy` bundle resource; Apple requires this for App Store submissions from 2024 onward.

Everything else from the Electron repo (build.py, build.sh, check-build-status.sh, verify-certificates.sh, sign-app.js, afterPack.cjs, notarize.cjs, etc.) is **retired** — Xcode + App Store Connect handle all of this.

## CI

Recommend GitHub Actions on macOS runners:

- **Build-test.yml** — on every PR: `xcodebuild -scheme ClipzApp -destination 'platform=macOS' test`. Also run package tests with `swift test` inside each `Packages/*`.
- **Archive.yml** — on push to `release/*` tag: archive against AppStore config, upload to App Store Connect via `xcrun altool` or `xcrun notarytool upload`. Requires `APP_STORE_CONNECT_API_KEY` secret.

No macOS signing runtime dance is needed — App Store distribution uses automatic signing tied to your Team ID.

## Minimum deliverables before any feature work

Implementation order within this file:

1. Create repo, `.gitignore`, lint configs, README stub.
2. Create Xcode project with the app target and empty `ClipzCore` package.
3. Wire GRDB dependency, verify `swift test` runs (empty test passes).
4. Add `ClipzML` and `ClipzUI` packages with minimal stubs.
5. Add Info.plist, entitlements, xcconfigs, three build configs.
6. Verify app launches to an empty window from Xcode in Debug.
7. Set up StoreKit configuration file for IAP testing (blank for now).
8. Commit; tag `scaffold-ready`.

Only after this baseline works end-to-end should feature implementation (swift_02 onward) begin.

## Open questions

- **Should `ClipzML` be a separate target that isn't loaded at launch?** If Core ML model loading adds measurable startup cost, consider dynamic loading (`Bundle(url:).load()`) on first analysis rather than at app boot. Revisit in swift_22.
- **Cloud backup** — does the user want iCloud Drive as a secondary backup target? Adds `com.apple.security.files.iclouddrive` entitlement. Deferred to swift_17.
