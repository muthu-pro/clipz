// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzCore

@Suite("ClipboardKind")
struct ClipboardKindTests {

    @Test func allEnumCasesRoundTripThroughRawValue() {
        for kind in ClipboardKind.allCases {
            #expect(ClipboardKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test func mediaCasesReportIsMediaTrue() {
        let media: Set<ClipboardKind> = [.image, .screenshot, .video]
        for kind in ClipboardKind.allCases {
            #expect(kind.isMedia == media.contains(kind))
        }
    }

    @Test func documentCasesReportIsDocumentTrue() {
        let docs: Set<ClipboardKind> = [.pdf, .doc, .docx, .xls, .xlsx, .numbers]
        for kind in ClipboardKind.allCases {
            #expect(kind.isDocument == docs.contains(kind))
        }
    }

    @Test func textAndHtmlAreNotFilesystemBacked() {
        #expect(!ClipboardKind.text.isFilesystemBacked)
        #expect(!ClipboardKind.html.isFilesystemBacked)
    }

    @Test func everyMediaOrDocumentKindIsFilesystemBacked() {
        for kind in ClipboardKind.allCases where kind.isMedia || kind.isDocument {
            #expect(kind.isFilesystemBacked)
        }
    }
}
