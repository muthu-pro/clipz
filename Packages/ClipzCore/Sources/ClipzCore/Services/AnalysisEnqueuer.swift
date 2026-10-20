// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Injection seam for the Vision/PDFKit pipeline. `ClipboardService` only
/// needs the ability to say "please analyze this item" — by hiding that
/// behind a protocol we keep the actual analysis dependency in `ClipzML`
/// and let tests substitute a no-op implementation.
public protocol AnalysisEnqueuer: Sendable {
    func enqueue(itemID: String, kind: ClipboardKind) async
}

/// Default implementation used before `ClipzML` wires its service in.
/// Also used by unit tests that don't exercise the analysis path.
public struct NoopAnalysisEnqueuer: AnalysisEnqueuer {
    public init() {}
    public func enqueue(itemID: String, kind: ClipboardKind) async {}
}
