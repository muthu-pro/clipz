// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import ApplicationServices

/// macOS gates synthetic keyboard events behind the Accessibility TCC
/// grant. Without it, `CGEvent.post` is silently dropped by the kernel
/// and auto-paste becomes a no-op. This enum is the single source of
/// truth for checking that grant and sending the user to System Settings
/// when they need to toggle it on.
@MainActor
public enum AccessibilityPermission {
    /// True when the app is listed under System Settings → Privacy &
    /// Security → Accessibility with the switch ON. Safe to call from
    /// any context — zero side effects.
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's one-shot prompt the first time it's called.
    /// macOS suppresses the prompt on subsequent invocations if the user
    /// previously declined, so treat this as an opportunistic kick — if
    /// it returns `false`, hand off to `openSettings()`.
    @discardableResult
    public static func requestWithPrompt() -> Bool {
        // The global `kAXTrustedCheckOptionPrompt` isn't Sendable under
        // Swift 6 strict concurrency; the string value it wraps is
        // documented and stable, so we inline it.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Deep-link into the Accessibility pane. We use this from the
    /// "Grant access" banner when the first-shot prompt has already been
    /// declined.
    public static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
