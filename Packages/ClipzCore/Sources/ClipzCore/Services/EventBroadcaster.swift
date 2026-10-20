// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Cross-process-style pub/sub within the app. `ClipboardService`
/// publishes captures / deletions / updates here; SwiftUI views subscribe
/// via `.task { for await e in broadcaster.events() { … } }`.
///
/// There is no back-pressure — if a subscriber falls behind we buffer,
/// which is acceptable for UI-tier consumers that keep up naturally.
public actor EventBroadcaster {
    public enum Event: Sendable {
        /// A capture passed dedup and we're about to persist. Emitted
        /// only for filesystem-backed kinds (image / screenshot / pdf /
        /// doc / video / etc.) where the file copy can block for many
        /// hundreds of milliseconds on a large source — text/HTML
        /// captures complete inline and don't need the heads-up.
        case captureBegan(kind: ClipboardKind)
        case captured(ClipboardItem)
        case deleted(id: String)
        case manyDeleted(ids: [String])
        case updated(ClipboardItem)
        case analysisUpdated(itemID: String)
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    /// Hand out a fresh event stream. The stream ends when the consumer
    /// stops iterating (e.g., SwiftUI view goes away); we remove the
    /// continuation from the registry in the termination handler.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id: id) }
        }
        return stream
    }

    public func emit(_ event: Event) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    public func subscriberCount() -> Int { continuations.count }

    private func remove(id: UUID) {
        continuations[id] = nil
    }
}
