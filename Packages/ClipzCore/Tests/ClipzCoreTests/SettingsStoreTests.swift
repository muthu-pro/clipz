// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("SettingsStore")
struct SettingsStoreTests {

    private func makeStore() async throws -> (AppDatabase, SettingsStore) {
        let db = try AppDatabase.makeInMemory()
        return (db, SettingsStore(database: db))
    }

    @Test func getReturnsSeededDefaults() async throws {
        let (_, store) = try await makeStore()
        #expect(await store.get(SettingsKeys.retentionDays) == 90)
        #expect(await store.get(SettingsKeys.monitorClipboard) == true)
        #expect(await store.get(SettingsKeys.analysisEnabled) == true)
        #expect(await store.get(SettingsKeys.screenshotFileTypes) == ["png", "jpg", "mov"])
        #expect(await store.get(SettingsKeys.screenshotAfterImport) == .keep)
    }

    @Test func setThenGetRoundTripsInt() async throws {
        let (_, store) = try await makeStore()
        await store.set(SettingsKeys.retentionDays, 365)
        #expect(await store.get(SettingsKeys.retentionDays) == 365)
    }

    @Test func setThenGetRoundTripsBool() async throws {
        let (_, store) = try await makeStore()
        await store.set(SettingsKeys.muteCopySound, true)
        #expect(await store.get(SettingsKeys.muteCopySound) == true)
        await store.set(SettingsKeys.muteCopySound, false)
        #expect(await store.get(SettingsKeys.muteCopySound) == false)
    }

    @Test func setThenGetRoundTripsStringSet() async throws {
        let (_, store) = try await makeStore()
        await store.set(SettingsKeys.screenshotFileTypes, ["png", "gif"])
        #expect(await store.get(SettingsKeys.screenshotFileTypes) == ["png", "gif"])
    }

    @Test func setThenGetRoundTripsEnum() async throws {
        let (_, store) = try await makeStore()
        await store.set(SettingsKeys.screenshotAfterImport, .delete)
        #expect(await store.get(SettingsKeys.screenshotAfterImport) == .delete)
    }

    @Test func malformedRawFallsBackToDefault() async throws {
        let (db, store) = try await makeStore()
        // Poison the `retentionDays` row with non-integer content.
        try await db.write { db in
            try db.execute(
                sql: "UPDATE settings SET value = ? WHERE key = ?",
                arguments: ["not-a-number", "retentionDays"]
            )
        }
        #expect(await store.get(SettingsKeys.retentionDays) == 90)
    }
}
