// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipzCore

/// Create and restore encrypted `.clipzbackup` packages. Restore replaces
/// the current history and relaunches the app (the swap happens at the
/// next launch, before the database opens).
struct BackupSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var encrypt = false
    @State private var createPassword = ""
    @State private var restorePassword = ""
    @State private var working = false
    @State private var status: StatusMessage?
    @State private var pendingRestoreURL: URL?
    @State private var pendingRestoreCount = 0
    @State private var showRestoreConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("Password-protect the backup", isOn: $encrypt)
                if encrypt {
                    SecureField("Backup password", text: $createPassword)
                }
                Button {
                    createBackup()
                } label: {
                    Label("Create Backup…", systemImage: "arrow.down.doc")
                }
                .disabled(working || (encrypt && createPassword.isEmpty))
                Text("Saves your clipboard history and media into a single backup package you can store anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Create")
            }

            Section {
                SecureField("Password (if the backup is encrypted)", text: $restorePassword)
                Button {
                    chooseRestore()
                } label: {
                    Label("Restore from Backup…", systemImage: "arrow.up.doc")
                }
                .disabled(working)
                Text("Replaces your current history with the backup's. Clipz relaunches to finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Restore")
            }

            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                }
            } else if let status {
                HStack(spacing: 8) {
                    Image(systemName: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? Color.green : Color.orange)
                    Text(status.text).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Restore backup?", isPresented: $showRestoreConfirm) {
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
            Button("Restore & Relaunch", role: .destructive) { relaunch() }
        } message: {
            Text("This replaces your current history with \(pendingRestoreCount) clip\(pendingRestoreCount == 1 ? "" : "s") from the backup. Clipz will relaunch to finish.")
        }
    }

    // MARK: - Create

    private func createBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.defaultBackupName).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.prompt = "Create Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let password = (encrypt && !createPassword.isEmpty) ? createPassword : nil
        let backups = container.backups
        working = true
        status = nil
        Task {
            do {
                try await backups.createBackup(to: url, password: password)
                status = .init(ok: true, text: "Backup created.")
            } catch {
                status = .init(ok: false, text: "Backup failed: \(error.localizedDescription)")
            }
            working = false
        }
    }

    // MARK: - Restore

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let password = restorePassword.isEmpty ? nil : restorePassword
        let backups = container.backups
        working = true
        status = nil
        Task {
            do {
                let manifest = try await Task.detached {
                    try backups.stageRestore(from: url, password: password)
                }.value
                pendingRestoreURL = url
                pendingRestoreCount = manifest.itemCount
                showRestoreConfirm = true
            } catch {
                status = .init(ok: false, text: Self.friendly(error))
            }
            working = false
        }
    }

    private func relaunch() {
        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Helpers

    private struct StatusMessage { let ok: Bool; let text: String }

    private static func friendly(_ error: Error) -> String {
        guard let backupError = error as? BackupError else {
            return "Restore failed: \(error.localizedDescription)"
        }
        switch backupError {
        case .passwordRequired: return "This backup is password-protected — enter its password and try again."
        case .invalidPassword:  return "Wrong password for this backup."
        case .invalidFormat:    return "That folder isn't a valid Clipz backup."
        case .versionTooNew:    return "This backup was made by a newer version of Clipz."
        case .fileNotFound:     return "The backup couldn't be read."
        default:                return "Restore failed."
        }
    }

    /// e.g. "Clipz Backup 1.0.1 2026-06-12" — includes the app version.
    private static var defaultBackupName: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Clipz Backup \(version) \(f.string(from: Date()))"
    }
}
