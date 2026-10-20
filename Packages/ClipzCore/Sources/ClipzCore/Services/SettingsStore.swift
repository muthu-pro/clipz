// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GRDB

/// A strongly-typed key into the settings K/V table. Each key declares
/// its default, an encoder (Swift → DB string) and a decoder (DB string
/// → Swift). `SettingsStore.get/set` are fully type-safe at call sites.
public struct SettingsKey<Value: Sendable>: Sendable {
    public let rawKey: String
    public let defaultValue: Value
    public let encode: @Sendable (Value) -> String
    public let decode: @Sendable (String) -> Value?

    public init(
        rawKey: String,
        defaultValue: Value,
        encode: @Sendable @escaping (Value) -> String,
        decode: @Sendable @escaping (String) -> Value?
    ) {
        self.rawKey = rawKey
        self.defaultValue = defaultValue
        self.encode = encode
        self.decode = decode
    }
}

/// Static factory for every known settings key. Keeping them in one
/// enum makes typos a compile error and gives `SettingsKeys.*` a single
/// discoverable surface. Theme-related keys are intentionally absent —
/// Clipz follows the macOS system appearance (swift_15).
public enum SettingsKeys {
    // MARK: - Clipboard
    public static let retentionDays = intKey("retentionDays", default: 90)
    public static let monitorClipboard = boolKey("monitorClipboard", default: true)
    public static let monitorClipboardTextOnly = boolKey("monitorClipboardTextOnly", default: false)
    public static let muteCopySound = boolKey("muteCopySound", default: false)

    // MARK: - Screenshots
    public static let screenshotMonitoring = boolKey("screenshotMonitoring", default: false)
    public static let screenshotFileTypes = stringSetKey(
        "screenshotFileTypes",
        default: ["png", "jpg", "mov"]
    )
    public static let screenshotAfterImport = rawRepresentableKey(
        "screenshotAfterImport",
        default: ScreenshotAfterImportAction.keep
    )
    /// Security-scoped bookmark for the user-granted screenshot folder.
    /// Base64 for storage in the text-typed settings column. `nil` means
    /// the user hasn't granted access yet.
    public static let screenshotFolderBookmark = optionalDataKey(
        "screenshotFolderBookmark"
    )

    // MARK: - Analysis
    public static let analysisEnabled = boolKey("analysisEnabled", default: true)

    // MARK: - Dock / startup
    public static let showDockIcon = boolKey("showDockIcon", default: true)

    // MARK: - Paste
    /// When on, clicking an item in the tray popover re-activates the
    /// previously-focused app and synthesizes Cmd+V. When off, the item
    /// is only written to the pasteboard and the user pastes manually.
    public static let autoPaste = boolKey("autoPaste", default: true)

    // MARK: - Global hotkey
    /// System-wide shortcut that opens the tray quick-paste popup.
    public static let globalHotkeyEnabled = boolKey("globalHotkeyEnabled", default: true)
    /// Carbon/AppKit virtual key code. Default 9 = the "V" key.
    public static let globalHotkeyKeyCode = intKey("globalHotkeyKeyCode", default: 9)
    /// `NSEvent.ModifierFlags` raw value. Default 1179648 = ⌘⇧
    /// (`.command` 1<<20 | `.shift` 1<<17). The UI layer converts to Carbon
    /// modifier masks when registering.
    public static let globalHotkeyModifiers = intKey("globalHotkeyModifiers", default: 1_179_648)

    // MARK: - Onboarding
    /// Set once the first-run welcome flow has been completed/dismissed.
    public static let hasSeenOnboarding = boolKey("hasSeenOnboarding", default: false)

    // MARK: - Privacy
    /// Bundle identifiers of apps Clipz must never capture clipboard
    /// content from (in addition to the always-on concealed-type rule).
    public static let excludedAppBundleIDs = stringSetKey("excludedAppBundleIDs", default: [])

    /// When on, macOS biometric authentication (Touch ID, with device-
    /// password fallback) is required before any clipboard data is shown —
    /// the main window, the tray popover, and the ⌘⇧V quick-paste panel.
    public static let requireBiometricUnlock = boolKey("requireBiometricUnlock", default: false)
    /// How long an unlock persists before Clipz re-locks. See `BiometricLockMode`.
    public static let biometricLockMode = rawRepresentableKey(
        "biometricLockMode",
        default: BiometricLockMode.perSession
    )
    /// Idle window, in minutes, before re-locking — only used when
    /// `biometricLockMode == .idleTimeout`.
    public static let biometricIdleTimeoutMinutes = intKey("biometricIdleTimeoutMinutes", default: 5)

    /// What to do when a clip the source app marked private (a password /
    /// key) is copied. See `SensitiveContentPolicy`.
    public static let sensitiveContentPolicy = rawRepresentableKey(
        "sensitiveContentPolicy",
        default: SensitiveContentPolicy.protect
    )

    // MARK: - Encoder helpers

    private static func boolKey(_ key: String, default value: Bool) -> SettingsKey<Bool> {
        SettingsKey(
            rawKey: key,
            defaultValue: value,
            encode: { $0 ? "1" : "0" },
            decode: { $0 == "1" || $0.lowercased() == "true" }
        )
    }

    private static func intKey(_ key: String, default value: Int) -> SettingsKey<Int> {
        SettingsKey(
            rawKey: key,
            defaultValue: value,
            encode: { String($0) },
            decode: { Int($0) }
        )
    }

    // Kept for future keys that store a single string (none right now).
    @available(*, unavailable, message: "no string keys are declared at the moment — add here when one appears")
    private static func stringKey(_ key: String, default value: String) -> SettingsKey<String> {
        SettingsKey(rawKey: key, defaultValue: value, encode: { $0 }, decode: { $0 })
    }

    private static func stringSetKey(
        _ key: String, default value: Set<String>
    ) -> SettingsKey<Set<String>> {
        SettingsKey(
            rawKey: key,
            defaultValue: value,
            encode: { set in
                let sorted = Array(set).sorted()
                if let data = try? JSONEncoder().encode(sorted),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
                return "[]"
            },
            decode: { raw in
                guard let data = raw.data(using: .utf8),
                      let array = try? JSONDecoder().decode([String].self, from: data)
                else { return nil }
                return Set(array)
            }
        )
    }

    private static func rawRepresentableKey<V: RawRepresentable & Sendable>(
        _ key: String, default value: V
    ) -> SettingsKey<V> where V.RawValue == String {
        SettingsKey(
            rawKey: key,
            defaultValue: value,
            encode: { $0.rawValue },
            decode: V.init(rawValue:)
        )
    }

    /// Optional bytes stored as base64. Absent row → nil; invalid base64
    /// also → nil (the caller treats nil as "not granted").
    private static func optionalDataKey(_ key: String) -> SettingsKey<Data?> {
        SettingsKey(
            rawKey: key,
            defaultValue: nil,
            encode: { $0?.base64EncodedString() ?? "" },
            decode: { raw in raw.isEmpty ? nil : Data(base64Encoded: raw) }
        )
    }
}

/// Actor-wrapped access to the `settings` K/V table. Getters return the
/// declared default when the row is missing or malformed (never throws).
/// Setters are fire-and-forget — failures log via `Log` but don't
/// propagate, because settings are never load-bearing for correctness.
public actor SettingsStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func get<V: Sendable>(_ key: SettingsKey<V>) async -> V {
        let rawKey = key.rawKey
        do {
            let raw = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM settings WHERE key = ?",
                    arguments: [rawKey]
                )
            }
            if let raw, let decoded = key.decode(raw) {
                return decoded
            }
        } catch {
            Log.logger(.settings).error(
                "failed to read setting \(rawKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return key.defaultValue
    }

    public func set<V: Sendable>(_ key: SettingsKey<V>, _ value: V) async {
        let encoded = key.encode(value)
        let rawKey = key.rawKey
        do {
            try await database.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                    arguments: [rawKey, encoded]
                )
            }
        } catch {
            Log.logger(.settings).error(
                "failed to write setting \(rawKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
