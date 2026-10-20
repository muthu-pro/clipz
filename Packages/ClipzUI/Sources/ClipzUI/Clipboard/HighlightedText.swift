// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ClipzCore

/// Renders a `HighlightedString` as SwiftUI text with an accent-tinted
/// background on every matched range. Falls back to a plain Text when
/// the source has no highlights (SearchEngine still returns snippets
/// in that case — e.g., the LIKE fallback).
struct HighlightedText: View {
    let highlighted: HighlightedString
    var font: Font = .system(size: 12)
    var tint: Color = .accentColor

    init(
        highlighted: HighlightedString,
        font: Font = .system(size: 12),
        tint: Color = .accentColor
    ) {
        self.highlighted = highlighted
        self.font = font
        self.tint = tint
    }

    /// Convenience: parse a raw FTS snippet with `⟪⟫` delimiters.
    init(snippet: String, font: Font = .system(size: 12), tint: Color = .accentColor) {
        self.init(
            highlighted: HighlightedString.parse(snippet),
            font: font,
            tint: tint
        )
    }

    var body: some View {
        Text(attributedString)
            .font(font)
            .textSelection(.enabled)
    }

    private var attributedString: AttributedString {
        var attr = AttributedString(highlighted.plain)
        for range in highlighted.highlightedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attr),
                  let upper = AttributedString.Index(range.upperBound, within: attr)
            else { continue }
            attr[lower..<upper].backgroundColor = tint.opacity(0.25)
            attr[lower..<upper].foregroundColor = .primary
            attr[lower..<upper].font = font.weight(.semibold)
        }
        return attr
    }
}
