// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Umbrella namespace for the ClipzCore package.
///
/// ClipzCore is the UI-free foundation of the Clipz app: models, database,
/// services, clipboard capture, screenshot monitoring, search, file storage,
/// backup, licensing, migration, and utilities. See `swift_00_overview.md`
/// for the module map.
public enum ClipzCore {
    /// Build-time version string for the ClipzCore package.
    ///
    /// Authoritative app version comes from the app bundle's
    /// `CFBundleShortVersionString`; this value is only used for logging
    /// and smoke tests.
    public static let version = "0.1.0"
}
