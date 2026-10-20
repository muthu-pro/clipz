// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A parsed user search query. Produced by `ParsedSearch.parse` and
/// consumed by `SearchEngine`.
public struct ParsedSearch: Sendable, Equatable {
    public let tokens: [Token]
    /// True when at least one token is ≤ 2 characters — FTS5's porter
    /// tokenizer rejects very short words, so we route to the trigram
    /// indices (or, if shorter than the trigram minimum, fall back to
    /// `LIKE`).
    public let useTrigram: Bool
    /// True when the shortest token is too short for even trigram
    /// matching. Callers should `LIKE '%q%'` against `searchPreview`.
    public let fallbackToLike: Bool

    public enum Token: Sendable, Equatable {
        case word(String)
        case phrase(String)
    }

    public init(tokens: [Token], useTrigram: Bool, fallbackToLike: Bool) {
        self.tokens = tokens
        self.useTrigram = useTrigram
        self.fallbackToLike = fallbackToLike
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

public enum ParsedSearchParser {
    /// Parse a raw user input into tokens. Supports:
    /// - Quoted phrases: `"exact phrase"` → `.phrase`
    /// - Bare tokens split on whitespace → `.word`
    /// - Trims surrounding whitespace.
    public static func parse(_ raw: String) -> ParsedSearch {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedSearch(tokens: [], useTrigram: false, fallbackToLike: false)
        }

        var tokens: [ParsedSearch.Token] = []
        var buffer = ""
        var inQuotes = false

        for ch in trimmed {
            if ch == "\"" {
                if inQuotes {
                    if !buffer.isEmpty {
                        tokens.append(.phrase(buffer))
                    }
                } else if !buffer.isEmpty {
                    for w in buffer.split(whereSeparator: \.isWhitespace) {
                        tokens.append(.word(String(w)))
                    }
                }
                buffer = ""
                inQuotes.toggle()
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            if inQuotes {
                tokens.append(.phrase(buffer))
            } else {
                for w in buffer.split(whereSeparator: \.isWhitespace) {
                    tokens.append(.word(String(w)))
                }
            }
        }

        // Compute the shortest word-equivalent length. For phrases, use
        // the shortest word within the phrase.
        let minLen: Int = tokens.compactMap { token -> Int? in
            switch token {
            case .word(let w): return w.count
            case .phrase(let p):
                return p.split(whereSeparator: \.isWhitespace).map(\.count).min()
            }
        }.min() ?? 0

        let useTrigram = minLen > 0 && minLen <= 2
        let fallbackToLike = minLen > 0 && minLen < 3 && !tokens.contains { token in
            if case .phrase = token { return true } else { return false }
        }

        return ParsedSearch(
            tokens: tokens,
            useTrigram: useTrigram,
            fallbackToLike: fallbackToLike
        )
    }
}

extension ParsedSearch {
    /// Build the SQLite FTS5 `MATCH` expression. Bare tokens are ANDed,
    /// phrases are quoted. Characters that FTS5 treats as syntax
    /// (`"()*:-`) are stripped from bare words to avoid MATCH errors;
    /// phrases keep their content intact because they're already quoted.
    public func toFTSMatchExpression() -> String {
        let parts: [String] = tokens.map { token in
            switch token {
            case .word(let raw):
                let sanitized = Self.stripFTSSyntax(raw)
                return sanitized.isEmpty ? "" : "\(sanitized)*"
            case .phrase(let raw):
                let sanitized = raw.replacingOccurrences(of: "\"", with: "")
                return "\"\(sanitized)\""
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func stripFTSSyntax(_ s: String) -> String {
        let banned: Set<Character> = ["\"", "(", ")", "*", ":", "-", "^"]
        return String(s.filter { !banned.contains($0) })
    }
}
