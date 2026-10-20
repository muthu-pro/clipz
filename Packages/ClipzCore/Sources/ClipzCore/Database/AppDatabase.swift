// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

/// The only handle to the on-disk SQLite database. Uses `DatabasePool`
/// (WAL mode) so readers don't block the single writer — matches the
/// Electron app's better-sqlite3 + WAL setup.
///
/// All app code reaches the DB through this type — callers never import
/// GRDB directly outside `Database/`.
public final class AppDatabase: Sendable {
    /// Current schema version. Bumped whenever `migrator` registers a new
    /// migration. Written into the `BackupManifest.dbSchemaVersion` field
    /// so restore can refuse a backup from a future schema. (v1 initial,
    /// v2 added `ocr_results.frame_time`.)
    public static let currentSchemaVersion = 2

    private let dbWriter: any DatabaseWriter

    // MARK: - Construction

    /// Open (or create) the database at `url`. Applies pragmas, runs any
    /// pending migrations, returns a ready-to-use handle.
    public static func make(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA journal_size_limit = 10485760")  // 10 MB WAL cap
            try db.execute(sql: "PRAGMA mmap_size = 268435456")           // 256 MB
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try AppDatabase.migrator.migrate(pool)
        return AppDatabase(dbWriter: pool)
    }

    /// Open an in-memory database with the current schema. Used by tests.
    public static func makeInMemory() throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return AppDatabase(dbWriter: queue)
    }

    private init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Read / write

    /// Read from the database. Reader runs concurrently with other readers
    /// and with the writer under WAL snapshot isolation (no-op for the
    /// in-memory queue path, which serializes).
    public func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbWriter.read(block)
    }

    /// Write to the database. Writers are serialized; the block runs inside
    /// a transaction and is committed atomically.
    public func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbWriter.write(block)
    }

    // MARK: - Maintenance

    /// User-triggered full VACUUM. Expensive (rewrites the whole file);
    /// surface via the Settings → Danger tab.
    public func vacuum() async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "VACUUM")
        }
    }

    /// Truncate-checkpoint the WAL so `clipz.db` is fully self-contained on
    /// disk — call before copying the file into a backup. No-op for the
    /// in-memory test path.
    public func checkpoint() async throws {
        try await dbWriter.writeWithoutTransaction { db in
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
