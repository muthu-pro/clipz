# Clipz

<p>
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="License: GPL-3.0-only" src="https://img.shields.io/badge/license-GPL--3.0--only-blue">
</p>

**Clipz is a free, open-source, privacy-first clipboard manager for macOS.**
It remembers everything you copy — text, images, screenshots, files, and video
— and makes it instantly searchable **on-device**, including text inside
images, PDFs, and video frames. Nothing ever leaves your Mac: no accounts, no
servers, no cloud sync, no telemetry.

- ⌘⇧V quick-paste from any app
- On-device AI search (Apple Vision + PDFKit)
- Optional Touch ID lock for your clipboard
- Automatic protection for passwords/keys (blur + Touch ID)
- Password-protected local backups

## Install

- **Download:** grab the latest notarized build from
  [GitHub Releases](https://github.com/muthu-pro/clipz-native/releases).
- **Homebrew:** `brew install --cask clipz` *(coming soon)*

Requires macOS 14 (Sonoma) or later, Apple silicon or Intel.

## Build from source

Requirements: macOS 14+, Xcode 16+.

```bash
# Open the app in Xcode and run the ClipzApp scheme (⌘R), or build from the CLI:
xcodebuild -project ClipzApp/ClipzApp.xcodeproj \
  -scheme ClipzApp -configuration Debug -destination 'platform=macOS' build

# The reusable packages can be built / tested on their own:
cd Packages/ClipzCore && swift build && swift test
```

## Project layout

```
clipz-native/
├── ClipzApp/        — Xcode app target (entry point, entitlements, fastlane)
├── Packages/
│   ├── ClipzCore/   — models, SQLite storage (GRDB), capture, search, settings
│   ├── ClipzML/     — on-device Vision / PDFKit analysis
│   └── ClipzUI/     — SwiftUI views + AppKit bridges
├── website/         — marketing site (Vite + React)
└── swift_*.md       — design specs / decision log
```

## Stack

- Swift 6, macOS 14+ (Sonoma)
- SwiftUI, with AppKit bridges (NSStatusItem / NSPanel / NSFilePromiseProvider)
- GRDB.swift (SQLite + FTS5) · Apple Vision + PDFKit · LocalAuthentication · CryptoKit

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) and
our [Code of Conduct](CODE_OF_CONDUCT.md). All contributors sign the
[Contributor License Agreement](CLA.md) (handled automatically by the CLA
Assistant bot on your first pull request). Security reports: see
[SECURITY.md](SECURITY.md).

## License

Clipz is licensed under the **GNU General Public License v3.0 only**
(GPL-3.0-only) — see [LICENSE](LICENSE). Copyright © 2026 Muthukumar
Thamilmani. Third-party components are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

The project uses a CLA so it can stay sustainable (including possible future
commercial licensing) while the public source always remains available under
the GPL.
