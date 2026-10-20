// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzCore

@Suite("ParsedSearchParser")
struct ParsedSearchTests {

    @Test func parsesSimpleWords() {
        let p = ParsedSearchParser.parse("apple banana")
        #expect(p.tokens == [.word("apple"), .word("banana")])
        #expect(p.useTrigram == false)
        #expect(p.fallbackToLike == false)
    }

    @Test func parsesQuotedPhrase() {
        let p = ParsedSearchParser.parse("\"hello world\" swift")
        #expect(p.tokens == [.phrase("hello world"), .word("swift")])
    }

    @Test func unbalancedTrailingQuoteStillCapturesThePhrase() {
        let p = ParsedSearchParser.parse("\"unterminated")
        #expect(p.tokens == [.phrase("unterminated")])
    }

    @Test func shortestTokenTriggersTrigramPath() {
        let p = ParsedSearchParser.parse("lo a very-long-word")
        // shortest token is "a" -> length 1 -> useTrigram + fallback to LIKE
        #expect(p.useTrigram)
        #expect(p.fallbackToLike)
    }

    @Test func tokensBetweenThreeAndNineCharsUsePorter() {
        let p = ParsedSearchParser.parse("apple swift clipz")
        #expect(p.useTrigram == false)
    }

    @Test func emptyInputIsEmpty() {
        let p = ParsedSearchParser.parse("   ")
        #expect(p.isEmpty)
        #expect(p.useTrigram == false)
        #expect(p.fallbackToLike == false)
    }

    @Test func matchExpressionSanitizesFtsSyntax() {
        let p = ParsedSearchParser.parse("select(name)")
        // The `(` / `)` get stripped; what remains becomes a prefix match.
        #expect(p.toFTSMatchExpression() == "selectname*")
    }

    @Test func matchExpressionQuotesPhrases() {
        let p = ParsedSearchParser.parse("\"press cmd c\"")
        #expect(p.toFTSMatchExpression() == "\"press cmd c\"")
    }
}
