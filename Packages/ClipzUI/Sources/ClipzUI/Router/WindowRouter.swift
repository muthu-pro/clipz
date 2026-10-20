// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ClipzCore

/// Root of the main window. Clipz is free and open-source — there is no
/// license gate — so the only thing in front of the clipboard is the
/// optional biometric lock (`AppContainer.lockState`): when engaged the
/// window shows `LockView`, otherwise the full `MainView`.
public struct WindowRouter: View {
    @Environment(AppContainer.self) private var container

    public init() {}

    public var body: some View {
        if container.lockState == .locked {
            LockView()
        } else {
            MainView()
        }
    }
}
