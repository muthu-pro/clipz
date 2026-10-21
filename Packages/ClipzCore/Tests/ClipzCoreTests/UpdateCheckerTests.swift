// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("UpdateChecker")
struct UpdateCheckerTests {

    @Test("isNewer compares semantic versions")
    func newerComparisons() {
        #expect(UpdateChecker.isNewer("1.0.3", than: "1.0.2"))
        #expect(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))     // missing component == 0
        // Not newer:
        #expect(!UpdateChecker.isNewer("1.0.2", than: "1.0.2"))
        #expect(!UpdateChecker.isNewer("1.0.2", than: "1.0.3"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))    // equal
        #expect(!UpdateChecker.isNewer("1.9.9", than: "2.0.0"))
    }

    @Test("isNewer tolerates a leading v and whitespace")
    func normalizedComparisons() {
        #expect(UpdateChecker.isNewer("v1.0.3", than: "1.0.2"))
        #expect(UpdateChecker.isNewer("v1.0.3", than: "v1.0.2"))
        #expect(!UpdateChecker.isNewer(" v1.0.2 ", than: "1.0.2"))
        #expect(UpdateChecker.normalize("v1.0.2") == "1.0.2")
        #expect(UpdateChecker.normalize("1.0.2") == "1.0.2")
    }

    @Test("parse decodes tag, release URL, dmg asset and notes")
    func parseRelease() throws {
        let json = """
        {
          "tag_name": "v1.0.3",
          "html_url": "https://github.com/muthu-pro/clipz/releases/tag/v1.0.3",
          "body": "Fixes and improvements.",
          "assets": [
            { "browser_download_url": "https://github.com/muthu-pro/clipz/releases/download/v1.0.3/notes.txt" },
            { "browser_download_url": "https://github.com/muthu-pro/clipz/releases/download/v1.0.3/Clipz-1.0.3.dmg" }
          ]
        }
        """.data(using: .utf8)!

        let info = try UpdateChecker.parse(json)
        #expect(info.version == "1.0.3")
        #expect(info.releaseURL.absoluteString == "https://github.com/muthu-pro/clipz/releases/tag/v1.0.3")
        #expect(info.downloadURL?.absoluteString.hasSuffix("Clipz-1.0.3.dmg") == true)
        #expect(info.notes == "Fixes and improvements.")
    }

    @Test("parse handles a release with no dmg asset and empty notes")
    func parseNoAsset() throws {
        let json = """
        { "tag_name": "1.0.0", "html_url": "https://example.com/r", "body": "   ", "assets": [] }
        """.data(using: .utf8)!
        let info = try UpdateChecker.parse(json)
        #expect(info.version == "1.0.0")
        #expect(info.downloadURL == nil)
        #expect(info.notes == nil)
    }
}
