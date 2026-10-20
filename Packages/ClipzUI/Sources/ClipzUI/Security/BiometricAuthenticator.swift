// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LocalAuthentication

/// Single source of truth for the Touch ID / device-password gate that
/// protects viewing clipboard data. Mirrors `AccessibilityPermission`'s
/// shape: a small `@MainActor` facade over the system API (here
/// `LAContext`), so callers never touch LocalAuthentication directly.
///
/// We always use `.deviceOwnerAuthentication` (biometrics **with** an
/// automatic account-password fallback), never `...WithBiometrics`, so a
/// Mac without Touch ID — or a failed fingerprint — can still authenticate
/// with the login password. That guarantees the user can never be locked
/// out of their own clipboard.
@MainActor
public enum BiometricAuthenticator {
    /// True when the device can evaluate the owner-authentication policy —
    /// i.e. Touch ID / Optic ID is enrolled, or (via the password fallback)
    /// the account simply has a password. Zero side effects.
    public static func isAvailable() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &error
        )
        return ok
    }

    /// A short noun for the primary method, for UI copy ("Unlock with
    /// Touch ID"). Falls back to "your password" when no biometry is
    /// enrolled but the policy is still satisfiable via the login password.
    public static func methodLabel() -> String {
        let context = LAContext()
        // Populate `biometryType` by probing the policy first.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .faceID:  return "Face ID"
        default:       return "your password"
        }
    }

    /// Present the system authentication sheet. Returns `true` only on a
    /// verified success; user cancel, fallback exhaustion, or any error
    /// returns `false`. A fresh `LAContext` per call, per Apple guidance.
    public static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason
            )
        } catch {
            return false
        }
    }
}
