// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Minimal delegate so closing the main window doesn't quit the app —
/// Clipz lives on in the menu bar and the user returns via the tray or
/// the Dock. The app only actually quits on explicit "Quit Clipz" (from
/// the tray's right-click menu) or Cmd+Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Globally opt out of AppKit's automatic window tabbing. Without
    /// this, every WindowGroup window picks up the View → Show Tab Bar
    /// and Show All Tabs commands — features that don't apply to Clipz's
    /// single-surface UI.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// When the user clicks the Dock icon with no windows visible,
    /// bring the main window back. Standard macOS idiom.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in sender.windows where window.identifier?.rawValue == "main" {
                window.makeKeyAndOrderFront(nil)
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}
