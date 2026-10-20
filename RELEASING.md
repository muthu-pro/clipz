# Releasing Clipz

Clipz is distributed **outside the Mac App Store** as a Developer ID-signed,
notarized, stapled `.app` inside a `.dmg`, published on GitHub Releases and via
a Homebrew cask.

## Prerequisites

- An Apple Developer account with a **Developer ID Application** signing
  certificate installed in your keychain (team `YOUR_TEAM_ID`).
- An **App Store Connect API key** for notarization. Copy
  `ClipzApp/fastlane/.env.example` to `.env` and set `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, and `ASC_KEY_PATH`.
- `fastlane` installed (`brew install fastlane`).

## Cut a release

1. Bump `CURRENT_PROJECT_VERSION` (build) and, for a user-facing release,
   `MARKETING_VERSION` in `ClipzApp.xcodeproj`. Update `CHANGELOG.md`.
2. From `ClipzApp/`:
   ```sh
   fastlane release      # clean build → notarize → staple → Clipz.dmg
   ```
   Output lands in `build/fastlane/Clipz.dmg`.
3. Verify the notarized app runs on a clean Mac (Gatekeeper should accept it):
   ```sh
   spctl -a -vvv -t install build/fastlane/Clipz.app
   xcrun stapler validate build/fastlane/Clipz.dmg
   ```
4. Create a GitHub Release, tag it (e.g. `v1.0.1`), and attach `Clipz.dmg`.

## Homebrew cask (optional, follow-up)

Publish a cask in a tap (e.g. `muthu-pro/homebrew-clipz`) pointing at the
release DMG and its SHA-256, so users can `brew install --cask clipz`. The tap
lives in a separate repository.
