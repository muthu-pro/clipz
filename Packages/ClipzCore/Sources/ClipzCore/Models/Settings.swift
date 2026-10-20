// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What to do with the original file on disk after a screenshot has been
/// imported into the clipboard history. The `move` option from the Electron
/// app is not ported — sandbox rules make silent moves to arbitrary folders
/// impossible. Trash is reversible and sandbox-legal.
public enum ScreenshotAfterImportAction: String, Codable, Sendable {
    case keep
    case delete
}

/// A snapshot of every user-visible setting. Used by the Settings view to
/// render a consistent state; the authoritative store is the `settings`
/// K/V table plus `SMAppService` for `startAtLogin`.
///
/// Note: theme-related fields are intentionally absent. Clipz follows the
/// system appearance (swift_15) and exposes no in-app picker.
public struct SettingsSnapshot: Sendable {
    public var retentionDays: Int
    public var monitorClipboard: Bool
    public var monitorClipboardTextOnly: Bool
    public var muteCopySound: Bool
    public var screenshotMonitoring: Bool
    public var screenshotFileTypes: Set<String>
    public var screenshotAfterImport: ScreenshotAfterImportAction
    public var analysisEnabled: Bool
    public var showDockIcon: Bool
    /// Derived from `SMAppService.mainApp.status` at read time; never
    /// stored in the DB.
    public var startAtLogin: Bool

    public init(
        retentionDays: Int,
        monitorClipboard: Bool,
        monitorClipboardTextOnly: Bool,
        muteCopySound: Bool,
        screenshotMonitoring: Bool,
        screenshotFileTypes: Set<String>,
        screenshotAfterImport: ScreenshotAfterImportAction,
        analysisEnabled: Bool,
        showDockIcon: Bool,
        startAtLogin: Bool
    ) {
        self.retentionDays = retentionDays
        self.monitorClipboard = monitorClipboard
        self.monitorClipboardTextOnly = monitorClipboardTextOnly
        self.muteCopySound = muteCopySound
        self.screenshotMonitoring = screenshotMonitoring
        self.screenshotFileTypes = screenshotFileTypes
        self.screenshotAfterImport = screenshotAfterImport
        self.analysisEnabled = analysisEnabled
        self.showDockIcon = showDockIcon
        self.startAtLogin = startAtLogin
    }
}
