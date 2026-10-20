// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipzCore

/// Capture-related preferences. Retention shrink warns before deleting
/// a large number of existing clips.
struct ClipboardSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var monitorEnabled = true
    @State private var textOnly = false
    @State private var retentionDays = 90
    @State private var excludedApps: [String] = []
    @State private var loaded = false

    // Biometric lock
    @State private var biometricEnabled = false
    @State private var biometricMode: BiometricLockMode = .perSession
    @State private var biometricIdleMinutes = 5
    @State private var biometricAvailable = false
    @State private var biometricMethod = "Touch ID"

    // Sensitive content (passwords / keys)
    @State private var sensitivePolicy: SensitiveContentPolicy = .protect

    @State private var showShrinkAlert = false
    @State private var pendingRetention = 90
    @State private var pendingExpiredCount = 0

    private static let retentionOptions: [(Int, String)] = [
        (7, "7 days"),
        (30, "30 days"),
        (90, "90 days"),
        (365, "1 year"),
        (Int.max, "Forever"),
    ]

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Monitor clipboard", isOn: $monitorEnabled)
                    .onChange(of: monitorEnabled) { _, new in
                        Task {
                            await container.settings.set(SettingsKeys.monitorClipboard, new)
                            if new {
                                await container.clipboardWatcher.startIfEnabled()
                            } else {
                                await container.clipboardWatcher.stop()
                            }
                        }
                    }

                Toggle("Only capture text", isOn: $textOnly)
                    .disabled(!monitorEnabled)
                    .onChange(of: textOnly) { _, new in
                        Task { await container.settings.set(SettingsKeys.monitorClipboardTextOnly, new) }
                    }
            }

            Section("Retention") {
                Picker("Keep clips for", selection: $retentionDays) {
                    ForEach(Self.retentionOptions, id: \.0) { pair in
                        Text(pair.1).tag(pair.0)
                    }
                }
                .onChange(of: retentionDays) { oldValue, newValue in
                    Task { await confirmRetentionChange(from: oldValue, to: newValue) }
                }
            }

            Section {
                Toggle("Require \(biometricMethod) to view clipboard", isOn: $biometricEnabled)
                    .disabled(!biometricAvailable)
                    .onChange(of: biometricEnabled) { _, new in
                        Task { await setBiometricEnabled(new) }
                    }

                if biometricEnabled {
                    Picker("Lock again", selection: $biometricMode) {
                        ForEach(BiometricLockMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: biometricMode) { _, new in
                        Task {
                            await container.settings.set(SettingsKeys.biometricLockMode, new)
                            await container.refreshBiometricLock()
                        }
                    }

                    if biometricMode == .idleTimeout {
                        Stepper("Re-lock after \(biometricIdleMinutes) min",
                                value: $biometricIdleMinutes, in: 1...120)
                            .onChange(of: biometricIdleMinutes) { _, new in
                                Task {
                                    await container.settings.set(
                                        SettingsKeys.biometricIdleTimeoutMinutes, new
                                    )
                                    await container.refreshBiometricLock()
                                }
                            }
                    }
                }

                if !biometricAvailable {
                    Label(
                        "Touch ID or a device password isn't set up on this Mac.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("When on, Clipz asks for \(biometricMethod) before showing your clipboard — in the main window, the menu-bar popover, and the ⌘⇧V quick-paste panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("When a password or key is copied", selection: $sensitivePolicy) {
                    ForEach(SensitiveContentPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: sensitivePolicy) { _, new in
                    Task {
                        await container.settings.set(SettingsKeys.sensitiveContentPolicy, new)
                        await container.refreshSensitiveContentPolicy()
                    }
                }
                Text("Passwords and keys are detected only when the source app marks them private — password managers, Keychain, and browser password fields. Clipz never scans files, screenshots, or ordinary text for secrets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy & Security")
            }

            Section {
                if excludedApps.isEmpty {
                    Text("Clipz captures from every app. Add apps here to keep their clipboard content out of your history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedApps, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            AppIconView(bundleID: bundleID, size: 18)
                            Text(appName(for: bundleID))
                            Spacer()
                            Button {
                                removeExcludedApp(bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button {
                    addExcludedApps()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                Text("Password managers and apps that mark the clipboard as concealed are always skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Excluded apps")
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            monitorEnabled = await container.settings.get(SettingsKeys.monitorClipboard)
            textOnly = await container.settings.get(SettingsKeys.monitorClipboardTextOnly)
            retentionDays = await container.settings.get(SettingsKeys.retentionDays)
            excludedApps = (await container.settings.get(SettingsKeys.excludedAppBundleIDs)).sorted()
            biometricEnabled = await container.settings.get(SettingsKeys.requireBiometricUnlock)
            biometricMode = await container.settings.get(SettingsKeys.biometricLockMode)
            biometricIdleMinutes = await container.settings.get(SettingsKeys.biometricIdleTimeoutMinutes)
            biometricAvailable = BiometricAuthenticator.isAvailable()
            biometricMethod = BiometricAuthenticator.methodLabel()
            sensitivePolicy = await container.settings.get(SettingsKeys.sensitiveContentPolicy)
            loaded = true
        }
        .alert(
            "Shorten retention?",
            isPresented: $showShrinkAlert
        ) {
            Button("Cancel", role: .cancel) {
                // Revert the picker to its pre-change value.
                Task { retentionDays = await container.settings.get(SettingsKeys.retentionDays) }
            }
            Button("Delete \(pendingExpiredCount) clips", role: .destructive) {
                Task {
                    _ = try? await container.clipboard.deleteExpired(olderThanDays: pendingRetention)
                    await container.settings.set(SettingsKeys.retentionDays, pendingRetention)
                }
            }
        } message: {
            Text(
                "Lowering retention will delete \(pendingExpiredCount) clip\(pendingExpiredCount == 1 ? "" : "s") immediately. This can't be undone."
            )
        }
    }

    // MARK: - Biometric lock

    /// Persist the toggle and (re)arm the gate. We don't authenticate here:
    /// the actual Touch ID challenge happens the next time clipboard data is
    /// shown, and `deviceOwnerAuthentication` always offers the account-
    /// password fallback, so enabling can never lock the user out.
    private func setBiometricEnabled(_ enabled: Bool) async {
        await container.settings.set(SettingsKeys.requireBiometricUnlock, enabled)
        await container.refreshBiometricLock()
    }

    // MARK: - Excluded apps

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func addExcludedApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }

        var set = Set(excludedApps)
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { set.insert(id) }
        }
        persistExcluded(set)
    }

    private func removeExcludedApp(_ bundleID: String) {
        var set = Set(excludedApps)
        set.remove(bundleID)
        persistExcluded(set)
    }

    private func persistExcluded(_ set: Set<String>) {
        excludedApps = set.sorted()
        Task { await container.settings.set(SettingsKeys.excludedAppBundleIDs, set) }
    }

    private func confirmRetentionChange(from old: Int, to new: Int) async {
        // Shrinking? Confirm if anything would be affected.
        if new < old {
            let count = (try? await container.clipboard.countExpired(olderThanDays: new)) ?? 0
            if count > 0 {
                await MainActor.run {
                    pendingRetention = new
                    pendingExpiredCount = count
                    showShrinkAlert = true
                }
                return
            }
        }
        await container.settings.set(SettingsKeys.retentionDays, new)
    }
}
