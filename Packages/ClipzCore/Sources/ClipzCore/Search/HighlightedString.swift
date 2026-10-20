// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Parses SQLite's `snippet(…)` output into a structured representation
/// with highlighted ranges. We use `⟪` and `⟫` as the match delimiters
/// — non-ASCII characters that are extraordinarily unlikely to appear
/// in clipboard content but are easy to grep for.
///
/// SwiftUI consumers turn `ranges` into `AttributedString` styling in
/// the ClipzUI package; this Core-side type stays UI-agnostic so the
/// models remain testable without importing SwiftUI.
public struct HighlightedString: Sendable, Hashable {
    public let plain: String
    /// Byte-offset-free character ranges into `plain`. Non-overlapping,
    /// sorted, inclusive start / exclusive end.
    public let highlightedRanges: [Range<String.Index>]

    public init(plain: String, highlightedRanges: [Range<String.Index>]) {
        self.plain = plain
        self.highlightedRanges = highlightedRanges
    }

    /// Parse an FTS snippet. Delimiters are stripped; their positions
    /// become `highlightedRanges`. Any stray delimiter (opener without
    /// closer, or vice versa) is treated as plain text.
    public static func parse(_ raw: String) -> HighlightedString {
        let open: Character = "\u{27EA}"   // ⟪
        let close: Character = "\u{27EB}"  // ⟫

        var plain = ""
        var ranges: [Range<String.Index>] = []
        var highlightStart: String.Index? = nil

        for ch in raw {
            if ch == open {
                highlightStart = plain.endIndex
            } else if ch == close {
                if let start = highlightStart {
                    ranges.append(start..<plain.endIndex)
                    highlightStart = nil
                }
            } else {
                plain.append(ch)
            }
        }
        return HighlightedString(plain: plain, highlightedRanges: ranges)
    }

    /// True when this snippet has at least one highlighted segment.
    public var hasHighlights: Bool { !highlightedRanges.isEmpty }
}
