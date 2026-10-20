// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit

/// User-facing flow to grant Clipz access to a screenshot folder.
/// Opens `NSOpenPanel`, converts the picked URL to a security-scoped
/// bookmark the app can re-use across launches.
@MainActor
public enum ScreenshotPermissions {

    /// Show the folder-picker and return the serialized bookmark on
    /// success. Throws `ScreenshotWatcherError.permissionDenied` if the
    /// user cancels.
    public static func requestAccess(
        defaultLocation: String? = nil,
        message: String = "Clipz needs access to your screenshot folder to detect new screenshots.",
        prompt: String = "Grant Access"
    ) async throws -> Data {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = URL(
            fileURLWithPath: defaultLocation ?? ScreenshotPreferences.systemScreenshotLocation()
        )

        let response = await panel.beginAsync()
        guard response == .OK, let url = panel.url else {
            throw ScreenshotWatcherError.permissionDenied
        }
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

// MARK: - Async NSOpenPanel wrapper

private extension NSOpenPanel {
    /// A tiny continuation bridge so callers can `await` the panel.
    @MainActor
    func beginAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { cont in
            self.begin { response in
                cont.resume(returning: response)
            }
        }
    }
}
