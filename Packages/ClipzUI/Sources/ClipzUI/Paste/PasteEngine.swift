// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import CoreGraphics

/// Remembers which app was frontmost before the tray popover stole
/// focus, then re-activates it and synthesizes Cmd+V after an item is
/// written to the pasteboard. Mirrors what Paste.app does: the user
/// clicks a clip and it appears at their cursor in the app they were
/// just typing in.
@MainActor
public final class PasteEngine {
    private var previousFrontmostApp: NSRunningApplication?

    public init() {}

    /// Called just before the tray popover is shown. Captures the app
    /// whose text field is (presumably) the target of the eventual
    /// paste. Clipz itself is skipped — if Clipz was already frontmost,
    /// restoring to it defeats the whole point.
    public func captureFrontmostApp() {
        let candidate = NSWorkspace.shared.frontmostApplication
        if candidate?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        previousFrontmostApp = candidate
    }

    /// Re-activates the previously captured app, pauses briefly for the
    /// activation to take effect, then posts a synthetic Cmd+V. No-ops
    /// (returning `false`) if Accessibility isn't granted — callers can
    /// surface a banner in that case.
    @discardableResult
    public func paste() async -> Bool {
        guard AccessibilityPermission.isGranted() else { return false }

        if let prev = previousFrontmostApp, !prev.isTerminated {
            // We activated ourselves to make the (hotkey-opened) popover
            // clickable, so a *polite* activation of the target loses the
            // race and ⌘V would land in Clipz. Force focus back: bring the
            // target's windows forward AND hide ourselves so we can't stay
            // frontmost.
            prev.activate(options: [.activateAllWindows])
            NSApp.hide(nil)
        } else {
            // No captured target — at least step out of the way.
            NSApp.hide(nil)
        }
        // Give the focus switch time to land before the keystroke. 150 ms
        // is stable across the activate → hide → key-post hop.
        try? await Task.sleep(nanoseconds: 150_000_000)

        return synthesizeCmdV()
    }

    private func synthesizeCmdV() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // 'v' — position-based on macOS, layout-stable.

        guard
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
