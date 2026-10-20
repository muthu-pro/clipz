// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Lightweight HTML → plain-text extraction.
///
/// We deliberately avoid `NSAttributedString(html:)`, which must run on the
/// main thread and is heavy; clipboard HTML (e.g. a selection copied from a
/// browser) only needs its tags removed and a handful of entities decoded for
/// both the search preview and the on-screen display. This is the single
/// source of truth used by capture (`ClipboardClassifier`) and rendering
/// (`ClipboardRow`).
public enum HTMLText {
    /// Strip tags, collapse block-level breaks into newlines, and decode the
    /// common named/numeric entities. Returns readable plain text.
    public static func plain(from html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)

        var inTag = false
        var tagName = ""
        var readingTagName = false
        var isClosingTag = false

        for ch in html {
            if ch == "<" {
                inTag = true
                readingTagName = true
                isClosingTag = false
                tagName = ""
            } else if ch == ">" {
                inTag = false
                // Map block-level boundaries to newlines so the stripped
                // text keeps its structure instead of running together.
                // We break on the *closing* tag (and on void `<br>`) only,
                // so adjacent blocks get a single break, not a double one.
                if tagName == "br" || (isClosingTag && Self.breakTags.contains(tagName)) {
                    out.append("\n")
                }
            } else if inTag {
                if readingTagName {
                    if ch == "/" && tagName.isEmpty {
                        isClosingTag = true                          // </tag>
                    } else if ch.isLetter || ch.isNumber {
                        tagName.append(Character(ch.lowercased()))
                    } else {
                        readingTagName = false                       // hit attrs/space
                    }
                }
            } else {
                out.append(ch)
            }
        }

        return decodeEntities(out)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            // Collapse runs of 3+ newlines the block-break mapping can create.
            .replacingOccurrences(
                of: "\n{3,}", with: "\n\n", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags whose boundary should become a line break in plain text.
    private static let breakTags: Set<String> = [
        "br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "ul", "ol", "table", "section", "article",
    ]

    private static func decodeEntities(_ s: String) -> String {
        var result = s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        // Numeric entities: &#160; and &#xA0;
        guard result.contains("&#") else { return result }
        let pattern = "&#(x?[0-9a-fA-F]+);"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        var output = ""
        var last = 0
        re.enumerateMatches(in: result, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            output += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1))
            let scalarValue: UInt32? = token.hasPrefix("x") || token.hasPrefix("X")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                output.append(Character(scalar))
            } else {
                output += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        output += ns.substring(from: last)
        result = output
        return result
    }
}
