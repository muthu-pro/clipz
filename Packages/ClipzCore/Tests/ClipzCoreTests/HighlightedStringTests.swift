// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzCore

@Suite("HighlightedString")
struct HighlightedStringTests {

    @Test func parsesSingleHighlight() {
        let hs = HighlightedString.parse("press \u{27EA}Cmd\u{27EB} to copy")
        #expect(hs.plain == "press Cmd to copy")
        #expect(hs.highlightedRanges.count == 1)
        let range = hs.highlightedRanges[0]
        #expect(hs.plain[range] == "Cmd")
    }

    @Test func parsesMultipleHighlights() {
        let hs = HighlightedString.parse(
            "\u{27EA}hello\u{27EB} world \u{27EA}swift\u{27EB}"
        )
        #expect(hs.plain == "hello world swift")
        #expect(hs.highlightedRanges.count == 2)
    }

    @Test func noDelimitersMeansNoHighlights() {
        let hs = HighlightedString.parse("plain text")
        #expect(hs.plain == "plain text")
        #expect(!hs.hasHighlights)
    }

    @Test func strayDelimitersFailSafe() {
        let hs = HighlightedString.parse("broken \u{27EA}ok no-close")
        #expect(hs.plain == "broken ok no-close")
        #expect(hs.highlightedRanges.isEmpty)
    }
}
