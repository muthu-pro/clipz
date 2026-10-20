// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ClipzCore

/// Umbrella namespace for the ClipzML package. See
/// `swift_09_ml_analysis_vision.md` for the analysis pipeline design.
public enum ClipzML {
    public static let version = "0.2.0"

    /// macOS 14+ guarantees every Vision request type we depend on. The
    /// function exists so callers can verify the deployment target didn't
    /// drift before we call into Vision.
    public static var isVisionPipelineAvailable: Bool { true }
}
