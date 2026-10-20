# Changelog

All notable changes to Clipz are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions track the app's
`MARKETING_VERSION`.

## [Unreleased]

### Open source
- **Clipz is now free and open-source under GPL-3.0-only.** All monetization
  was removed: the 30-day trial, the StoreKit in-app purchase, the paywall,
  the Pro settings tab, and the trial banner are gone — the app is always
  fully usable.
- Added `LICENSE` (GPLv3), `CLA.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  `SECURITY.md`, `NOTICE`/`THIRD_PARTY_LICENSES.md`, GitHub issue/PR
  templates, and SPDX headers across the sources.
- Distribution moves off the Mac App Store to notarized DMG + Homebrew.

## [1.0.1] - 2026-06-12

### Menu bar & app lifecycle
- **Tray click roles swapped**: left-click the menu-bar icon now opens the
  main window; right-click opens the quick-paste popup.
- **Runs as a menu-bar agent** (`LSUIElement`): no Dock icon, and closing
  the window no longer quits — Clipz keeps running and capturing in the
  background.
- **Quit button** added to the popup header (the right-click menu it used
  to live in is gone); ⌘Q still works when the window is focused.
- **Multi-monitor aware**: the main window opens on the display whose menu
  bar you clicked, positioned just under the menu bar with its left edge
  aligned to the tray icon (clamped to stay fully on-screen).
- Main window is now a single `Window` scene reopened via SwiftUI
  `openWindow`, so it reliably comes back after being closed as an agent app.

### Object detection & image previews
- **General object detection** (`ObjectDetector`): Vision objectness
  saliency finds prominent object regions, then each region is classified
  to produce a labeled bounding box — on-device, offline, no CoreML model
  bundled. Joins the existing OCR / barcode / animal / human analyzers and
  runs on the background analysis queue.
- **Bounding-box overlay** on the large image preview, drawn via `Canvas`
  with the correct aspect-fill mapping. Off by default; revealed with a
  hover toggle, or forced on for search hits that matched a detected object.
- **In-app full-screen image viewer**: tapping an image opens a fit-to-window
  viewer on a dark backdrop with an opt-in box toggle and a hand-off to the
  system default app. (PDFs/docs still open externally.)
- **Doubled the inline image preview height** (200 → 400 pt).

### Search
- **Detected objects are now searchable**: class names are seeded into
  `object_synonyms` (which the FTS index actually queries), so searching
  e.g. "person" or "laptop" surfaces the matching images.
- **One-time backfill** at startup indexes class names for detections
  written before this fix, so existing history becomes searchable without
  re-analysis.
- Image search results that matched a detected object reveal that object's
  bounding box automatically.

### Video
- **Inline video playback** — video clips now play in an AppKit
  `AVPlayerView` (native transport controls) sized to fit the card, instead
  of a static thumbnail. Fixed a crash that occurred when fast-scrolling
  reached a video (SwiftUI `VideoPlayer` aborting in `_AVKit_SwiftUI`).
- **Frame-sampled analysis of videos** — up to 30 frames (1 every 2s) are
  run through the image pipeline so on-screen text and detected objects in
  videos become searchable, deduped across frames.
- **Seek-to-frame search** — OCR hits store the frame timestamp
  (`ocr_results.frame_time`, migration `v2`); a video search result jumps
  the player to the matching frame (single match auto-seeks; multiple
  matches show clickable `m:ss` badges).

### Clipboard cards & filters
- Removed the colored accent line on the left of clipboard cards.
- Image previews now **fit the card width** (whole image visible, scales on
  resize) instead of cropping a fixed-height box.
- App filter renders as a proper pill, and the app dropdown shows small
  (14 pt) icons instead of oversized glyphs.

### Global shortcut & quick-paste panel
- **System-wide hotkey** (default ⌘⇧V) via Carbon `RegisterEventHotKey` — no
  Accessibility permission needed, sandbox-safe. Rebindable with a key
  recorder in Settings → General → Shortcut, and toggleable on/off.
- **Spotlight-style quick-paste panel** summoned by the hotkey: appears
  **near the cursor**, opens with a focused **search** field over up to 100
  clips, is **keyboard-navigable** (↑/↓ to select, ↩ to paste, esc to close),
  and pastes the chosen clip into the app the hotkey was pressed in. Mouse
  clicks work too; click-away dismisses it.

### Onboarding
- **First-run welcome** sheet: explains what Clipz captures, the on-device
  AI search, the global shortcut, and the 30-day-trial terms — and **primes
  the Accessibility permission up front** so auto-paste works on day one.

### Accessibility
- **Keyboard navigation** in the main timeline: ↑/↓ select a row, **↩ copies**
  it to the clipboard, **Delete** removes it (plus the existing
  PageUp/PageDown/Home/End). The selected row is highlighted.
- **VoiceOver**: each clip is one spoken element ("Image, invoice.png, from
  Safari, 2 hours ago") with Copy / Pin / Delete rotor actions; filter chips
  announce their selected state.

### Pinned / favorites
- **Pin a clip** (context-menu, or the VoiceOver Pin action) to mark it a
  favorite. Pinned clips show a ★, are **exempt from retention cleanup**
  (kept forever), and have a dedicated **Pinned** filter chip. Backed by a
  new `pinned` column (migration `v3`).

### Backup & restore
- **Backup/restore** in Settings → Backup. A backup is a **single zip
  archive** (via ZIPFoundation) bundling the database + media + a manifest
  (backup/app/schema versions), with **optional AES-GCM password
  encryption** (HKDF-SHA256 key). The default filename includes the app
  version, e.g. `Clipz Backup 1.0.1 2026-06-12.zip`.
- Restore validates the manifest/schema, unzips + decrypts, stages the
  data, and applies the swap at the next launch — before the database
  opens — then relaunches. Covered by a create→restore round-trip test.

### Privacy — excluded apps
- **Exclude apps from capture** in Settings → Clipboard: pick apps whose
  clipboard content Clipz should never record (on top of the always-on
  concealed-type rule for password managers). Capture is skipped when the
  source app's bundle id is on the list.

### Licensing (hard-lock, aligned with swift_20)
- Reverted the post-trial "soft-lock" experiment back to the documented
  **hard-lock** model: the whole feature set is active during the 30-day
  trial; once expired, only the paywall (and Settings → Pro/About) is
  reachable until a one-time purchase.
- Usability is gated **solely** at `WindowRouter` via `LicenseState`
  (swift_20 HR-5) — removed the per-service `canCapture` check from
  `ClipboardService` and the `allowsNewCaptures` plumbing.
- `PaywallView` is a full-window lock (Restore + Quit) with a
  store-unavailable **Retry** state; the exact swift_20 HR-6 trial-disclosure
  copy now appears in both the paywall and Settings → Pro.

### Startup, thumbnails & chrome
- **Start at login** (SMAppService) in General settings, with approval and
  error states.
- **Capture progress feedback**: a new `captureBegan` broadcaster event lets
  the tray icon pulse while a file-backed capture's disk copy is in flight.
- Higher-fidelity **PDF / document / media thumbnails** (off-main bitmap
  rendering, oversampled for Retina, white backing for transparent PDFs).
- Title-bar **"Clipz" wordmark + logo** hosted via a title-bar accessory,
  doubling as a Settings link.
- `PasteboardWriter` writes the correct pasteboard type per image format
  (PNG / JPEG / TIFF / HEIC / GIF / BMP) instead of assuming PNG.

### Tests
- Object-detection persistence and the object-name → search round-trip are
  covered in `ClipzML` tests.
