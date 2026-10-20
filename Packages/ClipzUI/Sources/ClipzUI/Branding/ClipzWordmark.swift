// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The Clipz brand accent — the same yellow (#FFCC00) the wordmark uses
/// on clipz.tech, so the app and website read as one identity.
extension Color {
    static let clipzAccent = Color(red: 1.0, green: 0.8, blue: 0.0)
}

/// The "Clipz." wordmark, matching the website: a serif face with a
/// yellow accent dot. Centralised so the About screen, main-window title
/// bar, and tray header all render identically. macOS's built-in serif
/// (New York) stands in for the site's Fraunces.
struct ClipzWordmark: View {
    var size: CGFloat = 19
    var weight: Font.Weight = .semibold

    var body: some View {
        // A single Text (not an HStack) so it reports a stable intrinsic
        // size — the title-bar accessory measures this view with
        // `NSHostingView.fittingSize`, and container layouts can under-
        // report there, clipping the wordmark + logo out of view.
        Text(wordmark)
            .font(.system(size: size, weight: weight, design: .serif))
    }

    private var wordmark: AttributedString {
        var name = AttributedString("Clipz")
        name.foregroundColor = .primary
        var dot = AttributedString(".")
        dot.foregroundColor = .clipzAccent
        name.append(dot)
        return name
    }
}
