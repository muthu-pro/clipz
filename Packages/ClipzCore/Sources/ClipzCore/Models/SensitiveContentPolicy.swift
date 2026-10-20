// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What Clipz does when it captures a clip the source app marked private
/// (a password or key). User-selectable in Settings; the default protects.
public enum SensitiveContentPolicy: String, Codable, CaseIterable, Sendable {
    /// Save it, but blur it and require Touch ID to reveal or copy (default).
    case protect
    /// Save and show it like any other clip.
    case reveal
    /// Never save sensitive clips.
    case skip

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .protect: return "Save it, blur it, and ask for Touch ID"
        case .reveal:  return "Save and show it like any clip"
        case .skip:    return "Don't save it"
        }
    }
}
