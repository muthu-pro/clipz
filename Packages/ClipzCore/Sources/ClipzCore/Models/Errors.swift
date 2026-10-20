// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Error types bubbled out of `ClipboardService` and its helpers.
public enum ClipboardError: Error, Sendable {
    case itemNotFound(id: String)
    case fileOperationFailed(underlying: any Error)
    case invalidPayload(reason: String)
    case databaseError(underlying: any Error)
}

/// Error types for the Vision/PDFKit analysis pipeline.
public enum AnalysisError: Error, Sendable {
    case modelLoadFailed(reason: String)
    case imageDecodeFailed
    case unsupportedFormat(extension: String)
    case cancelled
}

/// Error types for the backup/restore flow. Codes match the Electron
/// `backup-manager.js` enum so user-facing messages remain stable.
public enum BackupError: Error, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case corruptBackup
    case invalidFormat
    case versionTooNew(fileVersion: Int, supportedVersion: Int)
    case migrationFailed(reason: String)
    case invalidPassword
    case passwordRequired
    case fileNotFound
    case interrupted
}
