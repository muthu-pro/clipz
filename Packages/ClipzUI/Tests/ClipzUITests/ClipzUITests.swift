// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import ClipzUI

@Test func versionStringIsPresent() {
    #expect(!ClipzUI.version.isEmpty)
}
