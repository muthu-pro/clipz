// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import CoreGraphics
import os

private let pasteLog = Logger(subsystem: "tech.clipz.app", category: "paste")

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
        guard AccessibilityPermission.isGranted() else {
            pasteLog.error("paste aborted: Accessibility not granted")
            return false
        }

        // Only yield activation if we actually hold it. The menu-bar (tray)
        // popover activates Clipz, so there we must re-focus the target and
        // hide ourselves or ⌘V lands in Clipz. The quick-paste panel is
        // non-activating — the target app never lost activation — so hiding
        // an inactive accessory app here only disrupts focus right as we post
        // the keystroke. Hide *conditionally*.
        let weHoldActivation = NSApp.isActive
        if let prev = previousFrontmostApp, !prev.isTerminated {
            prev.activate(options: [.activateAllWindows])
            if weHoldActivation { NSApp.hide(nil) }
            pasteLog.debug("paste: target=\(prev.bundleIdentifier ?? "?", privacy: .public) weActive=\(weHoldActivation)")
        } else if weHoldActivation {
            // No captured target but we're frontmost — step out of the way.
            NSApp.hide(nil)
            pasteLog.debug("paste: no target captured, hiding self")
        } else {
            pasteLog.debug("paste: no target captured, staying out of the way")
        }
        // Give the focus switch time to land before the keystroke. 150 ms
        // is stable across the activate → (hide) → key-post hop.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let ok = synthesizeCmdV()
        pasteLog.debug("paste: synthesized Cmd+V -> \(ok)")
        return ok
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
