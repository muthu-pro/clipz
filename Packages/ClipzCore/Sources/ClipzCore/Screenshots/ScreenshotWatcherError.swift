// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ScreenshotWatcherError: Error, Sendable {
    /// The user dismissed the NSOpenPanel without picking a folder.
    case permissionDenied
    /// The bookmark fails to resolve (folder moved/deleted, volume
    /// unmounted). The watcher surfaces this so the UI can prompt for
    /// a re-grant.
    case bookmarkStale
    /// `open(2)` on the resolved URL failed. Rare — means the sandbox
    /// extension was lost or the file system returned a transient error.
    case openFailed(path: String, errno: Int32)
}
