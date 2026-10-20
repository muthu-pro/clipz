// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ClipzCore

@Suite("ClipboardItem row mapping")
struct ClipboardItemMappingTests {

    @Test func roundTripPreservesAllFields() throws {
        let original = ClipboardItem(
            id: "abc-123",
            kind: .pdf,
            content: "doc.pdf",
            searchPreview: "a searchable excerpt",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalName: "Brief.pdf",
            sourceApp: .init(name: "Safari", bundleID: "com.apple.Safari"),
            mediaInfo: .init(thumbnailFilename: "abc-123_thumb.png", pageCount: 12, wordCount: 3_400),
            metadata: .init(title: "Brief", author: "M. Clipz", mimeType: "application/pdf"),
            contentHash: "deadbeef",
            analysisStatus: .init(
                textDone: true,
                objectDone: false,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        )

        let row = original.toRow()
        let roundTripped = ClipboardItem(row: row)

        #expect(roundTripped.id == original.id)
        #expect(roundTripped.kind == original.kind)
        #expect(roundTripped.content == original.content)
        #expect(roundTripped.searchPreview == original.searchPreview)
        #expect(roundTripped.createdAt == original.createdAt)
        #expect(roundTripped.originalName == original.originalName)
        #expect(roundTripped.sourceApp == original.sourceApp)
        #expect(roundTripped.mediaInfo == original.mediaInfo)
        #expect(roundTripped.metadata == original.metadata)
        #expect(roundTripped.contentHash == original.contentHash)
        #expect(roundTripped.analysisStatus == original.analysisStatus)
    }

    @Test func timestampsRoundTripToMillisecondsAsElectronSchemaRequires() {
        let sample = Date(timeIntervalSince1970: 1_700_000_000.125)
        let item = ClipboardItem(
            id: "t",
            kind: .text,
            content: "hi",
            createdAt: sample
        )

        let row = item.toRow()
        // Stored as Int64 ms since epoch — matches Electron schema.
        #expect(row.createdAt == 1_700_000_000_125)

        // And converting back gives a Date within a millisecond of the original.
        let back = ClipboardItem(row: row).createdAt
        #expect(abs(back.timeIntervalSince1970 - sample.timeIntervalSince1970) < 0.001)
    }

    @Test func unknownKindRawValueDecodesAsText() {
        var row = ClipboardItem(id: "x", kind: .text, content: "", createdAt: .now).toRow()
        row.type = "plasma-blob"  // not a valid kind

        let item = ClipboardItem(row: row)
        #expect(item.kind == .text)
    }

    @Test func analysisFlagsMapCorrectly() {
        let yes = ClipboardItem(
            id: "y",
            kind: .image,
            content: "pic.png",
            createdAt: .now,
            analysisStatus: .init(textDone: true, objectDone: true, updatedAt: .now)
        ).toRow()
        #expect(yes.analysisTextDone == 1)
        #expect(yes.analysisObjectDone == 1)

        let no = ClipboardItem(
            id: "n",
            kind: .image,
            content: "pic.png",
            createdAt: .now
        ).toRow()
        #expect(no.analysisTextDone == 0)
        #expect(no.analysisObjectDone == 0)
        #expect(no.analysisUpdatedAt == nil)
    }
}
