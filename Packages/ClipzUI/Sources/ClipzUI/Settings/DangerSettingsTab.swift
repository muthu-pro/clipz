// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ClipzCore

/// Type-to-confirm erase of all clipboard items. Storage usage numbers
/// come from `ClipboardService.storageUsage`.
struct DangerSettingsTab: View {
    @Environment(AppContainer.self) private var container

    private static let requiredPhrase = "DELETE EVERYTHING"

    @State private var usage: StorageUsage?
    @State private var captchaInput: String = ""
    @State private var isErasing = false
    @State private var eraseResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                storageSection
                eraseSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            usage = try? await container.clipboard.storageUsage()
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        GroupBox("Storage") {
            if let usage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.bytesFormatter.string(fromByteCount: usage.totalBytes))
                            .font(.title.bold())
                        Spacer()
                        Button {
                            Task {
                                try? await container.database.vacuum()
                                self.usage = try? await container.clipboard.storageUsage()
                            }
                        } label: {
                            Label("Vacuum DB", systemImage: "wind")
                                .labelStyle(.titleAndIcon)
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 12) {
                        legend("Media", Self.bytesFormatter.string(fromByteCount: usage.mediaBytes))
                        legend("Database", Self.bytesFormatter.string(fromByteCount: usage.dbBytes))
                    }

                    Text(
                        "\(usage.itemCount) clip\(usage.itemCount == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func legend(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Erase

    private var eraseSection: some View {
        GroupBox("Erase everything") {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "This permanently deletes all clipboard items and media files.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.red)

                Text("Type \(Self.requiredPhrase) to confirm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("", text: $captchaInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button(role: .destructive) {
                    Task { await erase() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text(isErasing ? "Erasing…" : "Erase Everything")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!canErase)

                if let eraseResult {
                    Text(eraseResult)
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canErase: Bool {
        !isErasing && captchaInput == Self.requiredPhrase
    }

    private func erase() async {
        guard canErase else { return }
        isErasing = true
        defer { isErasing = false }

        try? await container.clipboard.deleteEverything()

        captchaInput = ""
        eraseResult = "Everything erased."
        usage = try? await container.clipboard.storageUsage()
    }

    // MARK: - Formatters

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()
}
