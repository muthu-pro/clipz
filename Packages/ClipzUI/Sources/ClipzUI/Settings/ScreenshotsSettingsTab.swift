// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzCore

/// Settings surface for the screenshot-folder watcher. The user grants
/// read access to a folder (typically ~/Desktop) via NSOpenPanel; we
/// persist a security-scoped bookmark and hand it to `ScreenshotWatcher`
/// at startup. File-type and after-import pickers round out the UI.
struct ScreenshotsSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var enabled = false
    @State private var folderPath: String?
    @State private var fileTypes: Set<String> = ["png", "jpg", "mov"]
    @State private var afterImport: ScreenshotAfterImportAction = .keep
    @State private var loaded = false
    @State private var errorMessage: String?

    private let supportedTypes: [(key: String, label: String)] = [
        ("png", "PNG"),
        ("jpg", "JPEG"),
        ("heic", "HEIC"),
        ("mov", "QuickTime (.mov)"),
        ("mp4", "MP4"),
    ]

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Import new files from a folder", isOn: $enabled)
                    .onChange(of: enabled) { _, new in
                        Task { await setMonitoring(new) }
                    }
                Text(
                    "When on, any screenshot or screen recording saved to the folder you pick is added to your clipboard history automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Folder") {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folderPath ?? "No folder selected")
                        .font(.callout)
                        .foregroundStyle(folderPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(folderPath == nil ? "Choose Folder…" : "Change…") {
                        pickFolder()
                    }
                    .controlSize(.small)
                }
                if folderPath == nil {
                    Text("Tip: pick the folder macOS saves screenshots to (typically Desktop, or whatever you've set in System Settings → Screen Capture).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("File types") {
                ForEach(supportedTypes, id: \.key) { pair in
                    Toggle(pair.label, isOn: binding(for: pair.key))
                }
            }
            .disabled(!enabled)

            Section("After import") {
                Picker("Original file", selection: $afterImport) {
                    Text("Keep").tag(ScreenshotAfterImportAction.keep)
                    Text("Move to Trash").tag(ScreenshotAfterImportAction.delete)
                }
                .pickerStyle(.segmented)
                .onChange(of: afterImport) { _, new in
                    Task { await container.settings.set(SettingsKeys.screenshotAfterImport, new) }
                }
                Text(
                    afterImport == .keep
                        ? "Files stay where they are on disk after being imported."
                        : "Files are moved to the Trash after import. You can recover them from the Trash until emptied."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            enabled = await container.settings.get(SettingsKeys.screenshotMonitoring)
            fileTypes = await container.settings.get(SettingsKeys.screenshotFileTypes)
            afterImport = await container.settings.get(SettingsKeys.screenshotAfterImport)
            folderPath = await resolveFolderPath()
            loaded = true
        }
    }

    // MARK: - Bindings

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { fileTypes.contains(key) },
            set: { shouldInclude in
                if shouldInclude {
                    fileTypes.insert(key)
                } else {
                    fileTypes.remove(key)
                }
                Task { await container.settings.set(SettingsKeys.screenshotFileTypes, fileTypes) }
            }
        )
    }

    // MARK: - Monitoring toggle

    private func setMonitoring(_ on: Bool) async {
        await container.settings.set(SettingsKeys.screenshotMonitoring, on)
        if on {
            // Flipping it on without a granted folder is a no-op at the
            // watcher level; prompt for one inline so the user doesn't
            // have to go hunting for the Choose Folder button.
            if folderPath == nil {
                await MainActor.run { pickFolder() }
            } else {
                errorMessage = nil
                await restartWatcher()
            }
        } else {
            await container.screenshotWatcher.stop()
        }
    }

    // MARK: - Folder picker

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "Choose the folder Clipz should watch for new screenshots."
        panel.directoryURL = URL(
            fileURLWithPath: ScreenshotPreferences.systemScreenshotLocation()
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            Task {
                await container.settings.set(SettingsKeys.screenshotFolderBookmark, bookmark)
                await MainActor.run {
                    folderPath = url.path
                    errorMessage = nil
                }
                if enabled {
                    await restartWatcher()
                }
            }
        } catch {
            errorMessage = "Couldn't save folder access: \(error.localizedDescription)"
        }
    }

    // MARK: - Watcher

    private func restartWatcher() async {
        await container.screenshotWatcher.stop()
        do {
            try await container.screenshotWatcher.startIfEnabled()
        } catch {
            await MainActor.run {
                errorMessage = "Monitoring couldn't start: \(error.localizedDescription)"
                enabled = false
            }
            await container.settings.set(SettingsKeys.screenshotMonitoring, false)
        }
    }

    // MARK: - Bookmark resolve

    private func resolveFolderPath() async -> String? {
        guard let bookmark = await container.settings.get(SettingsKeys.screenshotFolderBookmark) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.path
    }
}
