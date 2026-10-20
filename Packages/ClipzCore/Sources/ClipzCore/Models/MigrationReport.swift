// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The outcome of an Electron-era data import. Surfaced to the UI so the
/// welcome screen can show counts and any skipped-row reasons. See
/// swift_25.
public struct MigrationReport: Sendable {
    public let itemsImported: Int
    public let itemsFailed: Int
    public let mediaFilesCopied: Int
    public let errors: [MigrationError]
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        itemsImported: Int,
        itemsFailed: Int,
        mediaFilesCopied: Int,
        errors: [MigrationError],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.itemsImported = itemsImported
        self.itemsFailed = itemsFailed
        self.mediaFilesCopied = mediaFilesCopied
        self.errors = errors
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public struct MigrationError: Sendable {
        public let entity: String
        public let id: String
        public let reason: String

        public init(entity: String, id: String, reason: String) {
            self.entity = entity
            self.id = id
            self.reason = reason
        }
    }
}
