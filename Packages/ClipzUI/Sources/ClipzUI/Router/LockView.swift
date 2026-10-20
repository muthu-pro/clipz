// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

/// Full-window lock screen shown in place of `MainView` when the biometric
/// gate is engaged. Auto-prompts on appear and offers a manual retry if the
/// user cancels the system sheet.
struct LockView: View {
    @Environment(AppContainer.self) private var container

    @State private var authenticating = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 18) {
            appIcon

            VStack(spacing: 6) {
                ClipzWordmark(size: 30)
                Text("Locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Your clipboard is protected. Authenticate to view it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                Task { await unlock() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "touchid")
                    Text("Unlock with \(BiometricAuthenticator.methodLabel())")
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authenticating)

            if failed {
                Text("Authentication failed. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Prompt automatically the first time the lock screen appears.
            await unlock()
        }
    }

    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        failed = false
        let ok = await container.unlock()
        authenticating = false
        if !ok { failed = true }
    }

    private var appIcon: some View {
        Image(nsImage:
            NSImage(named: "ClipzLogo")
                ?? NSApp.applicationIconImage
                ?? NSImage(named: NSImage.applicationIconName)
                ?? NSImage()
        )
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 96, height: 96)
    }
}
