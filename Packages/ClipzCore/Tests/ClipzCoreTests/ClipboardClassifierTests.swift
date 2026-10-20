// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import Testing
@testable import ClipzCore

/// A test-scoped pasteboard created with a unique name so concurrent
/// tests don't stomp on each other or on the system's general pasteboard.
/// Released on deinit.
@MainActor
private final class TestPasteboard {
    let pb: NSPasteboard

    init() {
        self.pb = NSPasteboard(name: NSPasteboard.Name("tech.clipz.test.\(UUID().uuidString)"))
    }

    // NSPasteboard is process-scoped; the macOS runtime disposes of
    // test-only pasteboards on exit. Skipping `releaseGlobally()` here
    // avoids the Sendable/deinit isolation dance.
}

@MainActor
@Suite("ClipboardClassifier")
struct ClipboardClassifierTests {

    private let classifier = ClipboardClassifier()

    @Test func classifiesPlainText() throws {
        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setString("hello world", forType: .string)

        let payload = try #require(classifier.classify(tb.pb))
        #expect(payload.kind == .text)
        if case .inlineText(let s) = payload.data {
            #expect(s == "hello world")
        } else {
            Issue.record("Expected inlineText, got \(payload.data)")
        }
        #expect(payload.searchPreview == "hello world")
    }

    @Test func htmlBeatsPlainText() throws {
        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setString("<b>bold</b> words", forType: .html)
        tb.pb.setString("bold words", forType: .string)

        let payload = try #require(classifier.classify(tb.pb))
        #expect(payload.kind == .html)
        #expect(payload.searchPreview?.contains("bold words") == true)
        // Tags are stripped from the preview.
        #expect(payload.searchPreview?.contains("<b>") == false)
    }

    @Test func concealedTextIsMarkedSensitive() {
        // Concealed text (e.g. a password-manager copy) is no longer dropped
        // at classify time — it's captured and flagged `isSensitive` so the
        // capture policy in ClipboardWatcher can decide what to do, and the
        // UI can blur + Touch-ID-gate it. Its text is not search-indexed.
        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setString("hunter2secret", forType: .string)
        tb.pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        let payload = classifier.classify(tb.pb)
        #expect(payload?.kind == .text)
        #expect(payload?.isSensitive == true)
        #expect(payload?.searchPreview == nil)
    }

    @Test func transientTextIsMarkedSensitive() {
        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setString("transient", forType: .string)
        tb.pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        #expect(classifier.classify(tb.pb)?.isSensitive == true)
    }

    @Test func emptyStringFallsThrough() {
        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setString("", forType: .string)
        #expect(classifier.classify(tb.pb) == nil)
    }

    @Test func documentKindFromFilenameExtension() {
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.pdf")) == .pdf)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.docx")) == .docx)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.xlsx")) == .xlsx)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.numbers")) == .numbers)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.png")) == .image)
        // Plain-text / Markdown files are captured as file-backed `.doc`
        // clips (so they get a QuickLook thumbnail + extracted text).
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.txt")) == .doc)
        #expect(classifier.documentKind(for: URL(fileURLWithPath: "/tmp/a.md")) == .doc)
    }

    @Test func imageDataClassifiesAsImage() throws {
        // Build a 1×1 PNG via NSBitmapImageRep so we don't need a fixture.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let png = try #require(rep?.representation(using: .png, properties: [:]))

        let tb = TestPasteboard()
        tb.pb.clearContents()
        tb.pb.setData(png, forType: .png)

        let payload = try #require(classifier.classify(tb.pb))
        // Will be `.image` unless the frontmost app happens to be
        // com.apple.screencaptureui (unlikely during tests).
        #expect(payload.kind == .image || payload.kind == .screenshot)
        if case .imageData(let bytes, let ext) = payload.data {
            #expect(!bytes.isEmpty)
            #expect(ext == "png")
        } else {
            Issue.record("Expected imageData, got \(payload.data)")
        }
    }
}
