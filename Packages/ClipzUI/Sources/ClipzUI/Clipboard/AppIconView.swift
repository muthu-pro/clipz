// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

/// Renders the app icon for a given bundle identifier. Looks the app up
/// via `NSWorkspace.urlForApplication(withBundleIdentifier:)` and hands
/// the resolved URL to `NSWorkspace.icon(forFile:)` — that call always
/// returns something (a generic document icon when the bundle isn't on
/// disk), so there's no "missing icon" branch to handle.
///
/// Icons are memoised per bundle id so scrolling a timeline of 200
/// clips doesn't re-walk LaunchServices on every row.
struct AppIconView: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.icon(for: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Cache

    private static let cache = NSCache<NSString, NSImage>()

    private static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    /// An app icon with its `NSImage.size` baked to `points`. SwiftUI
    /// `Menu` items bridge to `NSMenuItem.image`, which renders at the
    /// image's own size and ignores SwiftUI frames — so for menu glyphs we
    /// hand back a copy sized up front instead of the full-resolution icon
    /// (which would render oversized). Returns nil when there's no icon, so
    /// callers can fall back to an SF Symbol.
    static func menuIcon(for bundleID: String?, points: CGFloat) -> NSImage? {
        guard let base = icon(for: bundleID),
              let copy = base.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: points, height: points)
        return copy
    }
}
