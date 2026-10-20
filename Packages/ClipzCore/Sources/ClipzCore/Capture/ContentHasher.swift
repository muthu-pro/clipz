// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// SHA-256 over the canonical byte representation of a payload. Drives
/// capture dedup (avoids re-inserting the same clip on every pasteboard
/// change-count tick) and cross-path matching (file-drop vs. pasteboard
/// for the same screenshot).
///
/// The hash input always includes `kind.rawValue` so two different kinds
/// with the same bytes (rare but possible) don't collapse.
public enum ContentHasher {
    public static func hash(_ payload: ClassifiedPayload) -> String {
        var h = SHA256()
        h.update(data: Data(payload.kind.rawValue.utf8))
        switch payload.data {
        case .inlineText(let s):
            h.update(data: Data(s.utf8))
        case .imageData(let data, let ext):
            h.update(data: Data(ext.utf8))
            h.update(data: data)
        case .fileURL(let url):
            if let data = try? Data(contentsOf: url) {
                h.update(data: data)
            } else {
                // File unreadable — hash the path as a last resort so
                // repeated drops of the same unreachable file still dedup.
                h.update(data: Data(url.path.utf8))
            }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience for hashing a file directly (used by the drop-import
    /// path to look up the just-captured row by content hash).
    public static func hashFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
