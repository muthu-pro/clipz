<div align="center">

<img src="ClipzApp/ClipzApp/Assets.xcassets/ClipzLogo.imageset/clipz-logo.png" width="96" alt="Clipz logo" />

# Clipz

### Your clipboard, with a memory.

A free, open-source, **privacy-first** clipboard manager for macOS. It remembers everything you copy — text, images, screenshots, files, and video — and makes it instantly searchable **on-device**, even the text inside a video. No cloud, no accounts, no telemetry.

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0--only-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-black.svg?logo=apple)](https://github.com/muthu-pro/clipz/releases/latest)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg?logo=swift)](Packages)
[![Website](https://img.shields.io/badge/web-clipz.tech-ffcc00.svg)](https://clipz.tech)

[**⬇ Download**](https://github.com/muthu-pro/clipz/releases/latest) · [🌐 clipz.tech](https://clipz.tech) · [🐛 Issues](https://github.com/muthu-pro/clipz/issues) · [🤝 Contributing](CONTRIBUTING.md)

</div>

---

## ✨ Features

| | |
|---|---|
| 🔎 **On-device AI search** | Apple Vision reads text in images, PDFs, and video frames — a screenshot is as searchable as a note. Nothing is uploaded. |
| 🎞️ **Search inside video** | Find a phrase from a screen recording and Clipz seeks the player straight to the frame. |
| ⌨️ **⌘⇧V quick-paste** | A Spotlight-style panel at your cursor. Type, arrow down, press return — it pastes where you were. |
| 🔐 **Touch ID lock** | Optionally gate the whole clipboard — window, menu bar, and ⌘⇧V — behind Touch ID. |
| 🛡️ **Passwords protected** | Secrets from password managers are auto-detected, blurred, and require Touch ID to reveal or copy. |
| 📌 **Pins & filters** | Pin favorites; filter by kind, source app, or date range. |
| 💾 **Encrypted backups** | Export your whole history into one password-protected file, and restore it anytime. |
| 🕵️ **Private by design** | No cloud, no accounts, no tracking, no telemetry — ever. |

## ⬇ Install

Download the latest **notarized** build from the [Releases page](https://github.com/muthu-pro/clipz/releases/latest), open the `.dmg`, and drag **Clipz** to Applications.

> Requires **macOS 14 (Sonoma)** or later · Apple silicon & Intel.

## 🛠 Build from source

Requirements: macOS 14+, Xcode 16+.

```bash
git clone https://github.com/muthu-pro/clipz.git
cd clipz

# Open in Xcode and run the ClipzApp scheme (⌘R), or from the CLI:
xcodebuild -project ClipzApp/ClipzApp.xcodeproj \
  -scheme ClipzApp -configuration Debug -destination 'platform=macOS' build

# Run the package tests:
cd Packages/ClipzCore && swift test
```

## 🧱 Project layout

```
clipz/
├── ClipzApp/        — Xcode app target (entry point, entitlements, fastlane)
└── Packages/
    ├── ClipzCore/   — models, SQLite storage (GRDB), capture, search, settings
    ├── ClipzML/     — on-device Vision / PDFKit analysis
    └── ClipzUI/     — SwiftUI views + AppKit bridges
```

**Stack:** Swift 6 · SwiftUI (+ AppKit bridges) · GRDB.swift (SQLite + FTS5) · Apple Vision + PDFKit · LocalAuthentication · CryptoKit.

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). All contributors sign the [Contributor License Agreement](CLA.md) (the CLA Assistant bot prompts you on your first pull request). Found a security issue? See [SECURITY.md](SECURITY.md).

## 📬 Contact

- ✉️ **Email:** [mail@muthu.pro](mailto:mail@muthu.pro)
- 🌐 **Website:** [clipz.tech](https://clipz.tech)
- 💬 **Issues & ideas:** [github.com/muthu-pro/clipz/issues](https://github.com/muthu-pro/clipz/issues)
- 👤 **Author:** [Muthukumar Thamilmani](https://www.linkedin.com/in/muthukumar-t/)

## 📄 License

Clipz is licensed under the **GNU General Public License v3.0 only** ([GPL-3.0-only](LICENSE)). © 2026 Muthukumar Thamilmani. Third-party components are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

<div align="center"><sub>Built with ♥ for macOS · 100% on-device.</sub></div>
