// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os

/// Unified logger for ClipzCore. Subsystems are per-file on the call side;
/// here we pin the bundle id. Keep logs structured and dull — App Store
/// reviewers read these to diagnose submission rejections.
public enum Log {
    /// Categories map loosely to spec files so grep-ability is good.
    public enum Category: String {
        case clipboard = "clipboard"
        case search = "search"
        case settings = "settings"
        case fileStore = "fileStore"
        case database = "database"
        case analysis = "analysis"
        case backup = "backup"
        case lifecycle = "lifecycle"
    }

    private static let subsystem = "tech.clipz.app"

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    // Convenience for the common case — one-off error logs from places
    // that don't want to import `os` directly.
    public static func error(_ message: String,
                             category: Category = .clipboard,
                             file: StaticString = #fileID,
                             line: UInt = #line) {
        logger(category).error("\(file, privacy: .public):\(line) \(message, privacy: .public)")
    }
}
