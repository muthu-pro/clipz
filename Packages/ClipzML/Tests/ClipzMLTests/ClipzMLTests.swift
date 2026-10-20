// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzML

@Test func visionPipelineIsAvailableOnTargetOS() {
    #expect(ClipzML.isVisionPipelineAvailable)
}
