// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit

/// Resolves "what app was in the foreground when this clip was copied"
/// for attribution in the clipboard list. The bundle id is authoritative
/// and persists in the DB; the human-readable name is pulled from the
/// same NSRunningApplication so the strings match.
public enum SourceAppInspector {
    /// Snapshot of the frontmost application. Reads are synchronous
    /// because NSWorkspace is documented thread-safe for these properties;
    /// in practice we call from the watcher's actor.
    public struct FrontmostApp: Sendable {
        public let name: String
        public let bundleID: String?
    }

    public static func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Prefer the localized display name; fall back to the bundle's
        // executable name if localization is missing (rare for shipping
        // apps, common for dev builds).
        let name = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? "Unknown"
        return FrontmostApp(name: name, bundleID: app.bundleIdentifier)
    }
}
