// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How long a biometric unlock persists before Clipz re-locks its
/// clipboard data. User-selectable in Settings when `requireBiometricUnlock`
/// is on; the default (`perSession`) is the least intrusive.
public enum BiometricLockMode: String, Codable, CaseIterable, Sendable {
    /// Unlock once; stays unlocked until the app quits or the Mac
    /// locks / sleeps. Fewest prompts.
    case perSession
    /// Re-lock after a period of inactivity (`biometricIdleTimeoutMinutes`).
    case idleTimeout

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .perSession:  return "Each session (until I quit or lock my Mac)"
        case .idleTimeout: return "After I'm idle"
        }
    }
}
