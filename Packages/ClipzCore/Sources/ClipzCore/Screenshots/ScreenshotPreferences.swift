// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

/// Reads the system-wide screenshot settings from
/// `com.apple.screencapture` preferences. The domain is publicly
/// readable even from a sandboxed app.
///
/// We consult these to:
/// 1. Suggest a default directory when the user first opens the
///    NSOpenPanel in the Screenshots settings tab.
/// 2. Match filenames against the user's custom prefix (if any).
public enum ScreenshotPreferences {

    /// Absolute path of the macOS screenshot save-to-file location, or
    /// `~/Desktop` expanded if the user hasn't customized it.
    public static func systemScreenshotLocation() -> String {
        let value = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String
        let path = value ?? "~/Desktop"
        return (path as NSString).expandingTildeInPath
    }

    /// User-customized filename prefix, e.g., `"MyScreenshot"` if the
    /// user ran `defaults write com.apple.screencapture name …`.
    /// Defaults to `"Screenshot"` on modern macOS.
    public static func systemScreenshotNamePrefix() -> String {
        let value = CFPreferencesCopyAppValue(
            "name" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String
        return value ?? "Screenshot"
    }
}
