// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzCore

@Test func versionStringIsPresent() {
    #expect(!ClipzCore.version.isEmpty)
}
