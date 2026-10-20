// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzCore

/// First-run welcome. Greets the user, sells the core value, and primes
/// the Accessibility permission so auto-paste works on day one instead of
/// being discovered buried in Settings.
struct OnboardingView: View {
    @Environment(AppContainer.self) private var container
    let onClose: () -> Void

    @State private var accessibilityGranted = false
    @State private var hotkeyLabel = "⌘⇧V"

    var body: some View {
        VStack(spacing: 18) {
            header
            features
            accessibilityPrime

            Spacer(minLength: 0)

            Button {
                finish()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 480, height: 620)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Re-check after the user returns from the system permission prompt.
            accessibilityGranted = AccessibilityPermission.isGranted()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            appIcon
            Text("Welcome to Clipz")
                .font(.largeTitle.bold())
            Text("Your clipboard history — captured, searchable, and always a keystroke away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(
                "doc.on.clipboard",
                "Captures everything",
                "Text, images, screenshots, files, and video — automatically."
            )
            featureRow(
                "sparkles",
                "AI-powered search",
                "Find text inside images, PDFs, and even video frames — all on-device."
            )
            featureRow(
                "command",
                "Always one shortcut away",
                "Press \(hotkeyLabel) from any app to open the quick-paste popup."
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func featureRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityPrime: some View {
        HStack(spacing: 10) {
            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(accessibilityGranted ? Color.green : Color.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(accessibilityGranted ? "Auto-paste is ready" : "Enable auto-paste")
                    .font(.callout.weight(.semibold))
                Text("Clipz can press ⌘V into the app you were using — a single keystroke per paste. This needs Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !accessibilityGranted {
                Button("Enable") { AccessibilityPermission.requestWithPrompt() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
        .frame(width: 72, height: 72)
    }

    // MARK: - Data

    private func load() async {
        accessibilityGranted = AccessibilityPermission.isGranted()
        let code = await container.settings.get(SettingsKeys.globalHotkeyKeyCode)
        let modsRaw = await container.settings.get(SettingsKeys.globalHotkeyModifiers)
        hotkeyLabel = HotkeyFormatter.string(
            keyCode: code,
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modsRaw))
        )
    }

    private func finish() {
        Task { await container.settings.set(SettingsKeys.hasSeenOnboarding, true) }
        onClose()
    }
}
