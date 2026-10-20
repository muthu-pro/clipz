// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Declares the shape, schema version, and (optional) encryption
/// parameters of a `.clipzbackup` archive. Field names and JSON shape
/// match the Electron-era manifest so backups made on the Electron app
/// restore cleanly on the Swift app. See swift_17.
public struct BackupManifest: Codable, Sendable {
    public let version: Int
    /// Always `"clipz-backup"` for now; reserves room for a forked format.
    public let format: String
    public let createdAt: Date
    public let dbSchemaVersion: Int
    public let appVersion: String
    public let itemCount: Int
    public let mediaFileCount: Int
    public let totalBytes: Int64
    public let encryption: EncryptionInfo?

    public init(
        version: Int,
        format: String,
        createdAt: Date,
        dbSchemaVersion: Int,
        appVersion: String,
        itemCount: Int,
        mediaFileCount: Int,
        totalBytes: Int64,
        encryption: EncryptionInfo?
    ) {
        self.version = version
        self.format = format
        self.createdAt = createdAt
        self.dbSchemaVersion = dbSchemaVersion
        self.appVersion = appVersion
        self.itemCount = itemCount
        self.mediaFileCount = mediaFileCount
        self.totalBytes = totalBytes
        self.encryption = encryption
    }

    public struct EncryptionInfo: Codable, Sendable {
        public let algorithm: String
        public let kdfAlgorithm: String
        public let kdfParams: KDFParams
        public let salt: Data
        public let nonce: Data

        public init(
            algorithm: String,
            kdfAlgorithm: String,
            kdfParams: KDFParams,
            salt: Data,
            nonce: Data
        ) {
            self.algorithm = algorithm
            self.kdfAlgorithm = kdfAlgorithm
            self.kdfParams = kdfParams
            self.salt = salt
            self.nonce = nonce
        }
    }

    public struct KDFParams: Codable, Sendable {
        /// scrypt cost factor (power of two, e.g., 2^14 = 16384).
        public let n: Int
        public let r: Int
        public let p: Int

        public init(n: Int, r: Int, p: Int) {
            self.n = n
            self.r = r
            self.p = p
        }
    }
}
