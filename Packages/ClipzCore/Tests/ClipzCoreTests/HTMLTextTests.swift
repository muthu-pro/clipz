// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

struct HTMLTextTests {
    @Test func stripsTagsToPlainText() {
        let html = "<p>Hello <b>world</b></p>"
        #expect(HTMLText.plain(from: html) == "Hello world")
    }

    @Test func decodesCommonEntities() {
        let html = "Tom &amp; Jerry &lt;3 &quot;quoted&quot; &#39;apos&#39;"
        #expect(HTMLText.plain(from: html) == "Tom & Jerry <3 \"quoted\" 'apos'")
    }

    @Test func decodesNumericAndHexEntities() {
        // &#160; (nbsp) becomes a normal space; &#x41; is "A".
        let html = "a&#160;b &#x41;&#66;"
        #expect(HTMLText.plain(from: html) == "a b AB")
    }

    @Test func blockTagsBecomeLineBreaks() {
        let html = "<div>line one</div><div>line two</div>"
        #expect(HTMLText.plain(from: html) == "line one\nline two")

        let list = "<ul><li>one</li><li>two</li></ul>"
        #expect(HTMLText.plain(from: list) == "one\ntwo")
    }

    @Test func collapsesExcessiveBlankLines() {
        let html = "<p>top</p><br><br><br><p>bottom</p>"
        #expect(HTMLText.plain(from: html) == "top\n\nbottom")
    }

    @Test func ignoresTagAttributesAndChrome() {
        // The kind of markup Chrome stamps onto an HTML copy.
        let html = """
        <meta charset='utf-8'><span style="color: rgb(32,33,36); \
        font-family: Arial">Virginia is a state.</span>
        """
        #expect(HTMLText.plain(from: html) == "Virginia is a state.")
    }

    @Test func plainTextPassesThroughUnchanged() {
        #expect(HTMLText.plain(from: "just text, no tags") == "just text, no tags")
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        let html = "<div>  padded  </div>"
        #expect(HTMLText.plain(from: html) == "padded")
    }
}
