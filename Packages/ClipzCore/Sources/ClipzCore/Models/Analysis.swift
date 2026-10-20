// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A bounding box in normalized image coordinates (0…1). Top-left origin
/// to match the rest of the app (AppKit bridges flip as needed for Core
/// Graphics consumers).
public struct BoundingBox: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Object-detection output. `classID` is a string identifier under Apple
/// Vision (e.g., `cat`, `laptop`); legacy Electron rows use integer COCO
/// ids and are surfaced unchanged — rendering degrades gracefully when
/// the matching `ObjectClass` row isn't present (swift_09, swift_25).
public struct Detection: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let itemID: String
    public let classID: Int
    public let confidence: Double
    public let bbox: BoundingBox?

    public init(id: Int64, itemID: String, classID: Int, confidence: Double, bbox: BoundingBox?) {
        self.id = id
        self.itemID = itemID
        self.classID = classID
        self.confidence = confidence
        self.bbox = bbox
    }
}

/// A detection joined to its class name and guaranteed to carry a box —
/// the shape the UI needs to draw a labeled overlay rectangle. Built by
/// `ClipboardService.fetchDetections(forItemID:)`; boxless rows (whole-
/// image classifier tags) are excluded.
public struct DetectedObject: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let label: String
    public let confidence: Double
    public let bbox: BoundingBox

    public init(id: Int64, label: String, confidence: Double, bbox: BoundingBox) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.bbox = bbox
    }
}

/// OCR output — either recognized text or a decoded barcode. The same
/// table backs both because both are "text found inside an image at a
/// bounding box".
public struct OCRResult: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let itemID: String
    public let kind: Kind
    public let text: String?
    public let barcodeSymbology: BarcodeSymbology?
    public let barcodePayload: String?
    public let confidence: Double?
    public let bbox: BoundingBox?

    public init(
        id: Int64,
        itemID: String,
        kind: Kind,
        text: String?,
        barcodeSymbology: BarcodeSymbology?,
        barcodePayload: String?,
        confidence: Double?,
        bbox: BoundingBox?
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.text = text
        self.barcodeSymbology = barcodeSymbology
        self.barcodePayload = barcodePayload
        self.confidence = confidence
        self.bbox = bbox
    }

    public enum Kind: String, Codable, Sendable { case text, barcode }

    public enum BarcodeSymbology: String, Codable, Sendable {
        case qr, ean8, ean13, upc, code39, code128, pdf417, dataMatrix, aztec, other
    }
}

/// An object class known to the analysis pipeline. The integer id mirrors
/// the Electron-era schema; Apple Vision class names are inserted with
/// auto-incrementing ids on first use.
public struct ObjectClass: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// A searchable synonym for an object class (e.g., "kitten" → cat).
/// Powers search-expansion so typing "puppy" finds cat-classified-as-dog
/// false positives and true hits alike.
public struct ObjectSynonym: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let classID: Int
    public let synonym: String

    public init(id: Int64, classID: Int, synonym: String) {
        self.id = id
        self.classID = classID
        self.synonym = synonym
    }
}

/// Extracted text from a document-kind clip. `pages` is the per-page
/// breakdown used to power in-document search highlighting.
public struct DocumentText: Hashable, Sendable {
    public let itemID: String
    public let fullText: String
    public let pages: [String]

    public init(itemID: String, fullText: String, pages: [String]) {
        self.itemID = itemID
        self.fullText = fullText
        self.pages = pages
    }
}
