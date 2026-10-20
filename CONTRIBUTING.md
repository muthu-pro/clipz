# Contributing to Clipz

Thanks for your interest in improving Clipz! Clipz is a free, open-source,
privacy-first clipboard manager for macOS, licensed under **GPL-3.0-only**.

## Ground rules

- Be kind — this project follows our [Code of Conduct](CODE_OF_CONDUCT.md).
- By contributing you agree to the [Contributor License Agreement](CLA.md).
  The **CLA Assistant** bot will ask you to accept it on your first pull
  request; a PR can't be merged until it's signed. (The CLA lets the project
  stay sustainable — including possible future commercial licensing — while
  the public code remains open under the GPL.)
- Security issues: please follow [SECURITY.md](SECURITY.md), not a public issue.

## Project layout

Clipz is a thin Xcode app target plus three local Swift packages:

- `ClipzApp/` — the macOS app target (`ClipzApp.xcodeproj`), entry point,
  entitlements, fastlane.
- `Packages/ClipzCore/` — storage (GRDB/SQLite), capture, search, settings,
  models. No UI.
- `Packages/ClipzML/` — on-device Vision/OCR analysis.
- `Packages/ClipzUI/` — all SwiftUI views and AppKit bridges.
- `website/` — the marketing site (Vite + React).

## Building & running

Requirements: macOS 14+, Xcode 16+.

```sh
# Open in Xcode and run the ClipzApp scheme (⌘R), or from the CLI:
xcodebuild -project ClipzApp/ClipzApp.xcodeproj \
  -scheme ClipzApp -configuration Debug -destination 'platform=macOS' build

# Run the package tests:
cd Packages/ClipzCore && swift test
```

## Pull requests

1. Fork and create a topic branch.
2. Keep changes focused; match the surrounding code style (the codebase favors
   small, well-documented types and clear comments explaining *why*).
3. Add a `// SPDX-License-Identifier: GPL-3.0-only` header to any new Swift
   source file.
4. Make sure `xcodebuild … build` and `swift test` pass.
5. Open the PR, fill in the template, and accept the CLA when prompted.

## Reporting bugs & requesting features

Use the GitHub issue templates. Include your macOS version, Clipz build
number, and clear reproduction steps for bugs.
