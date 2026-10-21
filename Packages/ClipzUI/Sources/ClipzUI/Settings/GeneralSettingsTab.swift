// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ServiceManagement
import ClipzCore

/// General-app preferences: Dock icon, mute copy sound, auto-paste +
/// its Accessibility grant status, and start-at-login (SMAppService).
struct GeneralSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var showDockIcon = true
    @State private var muteCopySound = false
    @State private var autoPaste = true
    @State private var accessibilityGranted = false
    @State private var startAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String? = nil
    @State private var hotkeyEnabled = true
    @State private var hotkeyKeyCode = 9
    @State private var hotkeyModifiers: NSEvent.ModifierFlags = [.command, .shift]
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, new in
                        applyDockIcon(new)
                        Task { await container.settings.set(SettingsKeys.showDockIcon, new) }
                    }
                Text("When off, Clipz lives only in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Presence")
            }

            Section {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, new in
                        applyLoginItem(new)
                    }
                Text("Launch Clipz automatically when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if loginItemNeedsApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text("Approve Clipz under System Settings → General → Login Items.")
                            .font(.caption)
                        Spacer()
                        Button("Open Settings…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }

                if let message = loginItemError {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Mute copy sound", isOn: $muteCopySound)
                    .onChange(of: muteCopySound) { _, new in
                        Task { await container.settings.set(SettingsKeys.muteCopySound, new) }
                    }
            } header: {
                Text("Sound")
            }

            Section {
                Toggle("Auto-paste after selecting an item", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, new in
                        Task { await container.settings.set(SettingsKeys.autoPaste, new) }
                    }
                Text("Clicking an item in the menu-bar popover — or choosing one in the ⌘⇧V quick-paste panel — re-focuses the previous app and presses ⌘V for you. Requires Accessibility access (see Permissions below).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Paste")
            }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: accessibilityGranted
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accessibilityGranted
                            ? "Accessibility access is enabled"
                            : "Accessibility access is required")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(accessibilityGranted
                            ? "Clipz can paste a selected clip straight into the app you were using."
                            : "macOS blocks Clipz from pressing ⌘V without it — clips are copied but won't auto-paste. Clipz may not appear in the list until you enable it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !accessibilityGranted {
                        Button("Enable…") { enableAccessibility() }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Permissions")
            }

            Section {
                Toggle("Open quick-paste with a global shortcut", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, new in
                        Task {
                            await container.settings.set(SettingsKeys.globalHotkeyEnabled, new)
                            await container.reloadGlobalHotkey()
                        }
                    }
                if hotkeyEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotkeyRecorderView(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers) { code, mods in
                            hotkeyKeyCode = code
                            hotkeyModifiers = mods
                            Task {
                                await container.settings.set(SettingsKeys.globalHotkeyKeyCode, code)
                                await container.settings.set(
                                    SettingsKeys.globalHotkeyModifiers, Int(mods.rawValue)
                                )
                                await container.reloadGlobalHotkey()
                            }
                        }
                    }
                    Text("Press this from any app to open the Clipz quick-paste popup. Needs at least one modifier (⌘ ⌥ ⌃ ⇧).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Shortcut")
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(
                        "Clipz follows your macOS system appearance. Change Light / Dark in System Settings → Appearance."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            showDockIcon = await container.settings.get(SettingsKeys.showDockIcon)
            muteCopySound = await container.settings.get(SettingsKeys.muteCopySound)
            autoPaste = await container.settings.get(SettingsKeys.autoPaste)
            hotkeyEnabled = await container.settings.get(SettingsKeys.globalHotkeyEnabled)
            hotkeyKeyCode = await container.settings.get(SettingsKeys.globalHotkeyKeyCode)
            hotkeyModifiers = NSEvent.ModifierFlags(
                rawValue: UInt(await container.settings.get(SettingsKeys.globalHotkeyModifiers))
            )
            accessibilityGranted = AccessibilityPermission.isGranted()
            refreshLoginItemStatus()
            loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Re-check when the user returns from System Settings so the
            // status rows update without a restart.
            accessibilityGranted = AccessibilityPermission.isGranted()
            refreshLoginItemStatus()
        }
    }

    private func applyDockIcon(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    /// Fire the one-shot system prompt (which registers Clipz in the
    /// Accessibility list the first time) and then deep-link straight to
    /// the Accessibility pane so the user can flip the switch. Status
    /// refreshes automatically via didBecomeActiveNotification on return.
    private func enableAccessibility() {
        AccessibilityPermission.requestWithPrompt()
        AccessibilityPermission.openSettings()
    }

    /// Read the SMAppService status into the local view state. SMAppService
    /// is the source of truth — the toggle just mirrors it.
    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        startAtLogin = (status == .enabled)
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// Toggle the login-item registration. `register` / `unregister` are
    /// fast local calls but they can throw (sandbox quirks, app not in
    /// /Applications during dev, etc.) — surface the error inline so the
    /// user knows why the toggle snapped back.
    private func applyLoginItem(_ enable: Bool) {
        loginItemError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        // Re-read the actual status: register() may have returned
        // .requiresApproval without throwing, and unregister() may have
        // succeeded even when the toggle was already off.
        refreshLoginItemStatus()
    }
}
