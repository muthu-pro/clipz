// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import AppKit
import ClipzCore
import ClipzML

/// Umbrella namespace for the ClipzUI package.
///
/// ClipzUI contains every SwiftUI view and AppKit bridge that renders the
/// Clipz app: clipboard timeline, settings, tray popover, quick-paste
/// panel, and the supporting components. See
/// `swift_12_ui_clipboard_view.md` through `swift_14_ui_settings.md` for
/// the individual view designs, and `swift_15_theming.md` for the
/// system-appearance stance.
public enum ClipzUI {
    public static let version = "0.1.0"
}

/// Placeholder root view used during scaffolding. Replaced in Phase 9 by
/// `ClipboardView` (swift_12) wired to the `AppContainer` described in
/// `swift_02_app_lifecycle.md`.
public struct ClipzRootPlaceholderView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            if let logo = NSImage(named: "ClipzLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
            }
            Text("Clipz")
                .font(.largeTitle.bold())
            Text("ClipzCore \(ClipzCore.version) · ClipzML \(ClipzML.version) · ClipzUI \(ClipzUI.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 320, minHeight: 220)
        .padding(32)
    }
}
