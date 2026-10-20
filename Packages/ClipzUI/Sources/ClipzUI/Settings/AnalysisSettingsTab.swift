// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ClipzCore

/// On/off switch for the local ML pipeline (Apple Vision OCR + object
/// classification on images, text extraction on documents). Everything
/// runs on-device; flipping this toggle only changes whether we queue
/// new work, not what's already been analyzed.
struct AnalysisSettingsTab: View {
    @Environment(AppContainer.self) private var container

    @State private var enabled = true
    @State private var queueDepth: Int = 0
    @State private var loaded = false

    var body: some View {
        Form {
            Section("On-device analysis") {
                Toggle("Enable AI analysis", isOn: $enabled)
                    .onChange(of: enabled) { _, new in
                        Task {
                            await container.settings.set(SettingsKeys.analysisEnabled, new)
                            if new {
                                await container.analysis.start()
                            } else {
                                await container.analysis.stop()
                            }
                            await refreshQueue()
                        }
                    }
                Text(
                    "Extracts text from copied images with OCR, tags objects in screenshots, and pulls readable text out of PDFs and Office documents. Everything runs on-device — nothing leaves your Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack(spacing: 8) {
                    Image(systemName: enabled ? "sparkles" : "pause.circle")
                        .foregroundStyle(enabled ? Color.accentColor : .secondary)
                    Text(enabled
                        ? "Running — \(queueDepth) item\(queueDepth == 1 ? "" : "s") in queue"
                        : "Paused — new clips won't be analyzed"
                    )
                    .font(.callout)
                    Spacer()
                    Button("Refresh") {
                        Task { await refreshQueue() }
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Text(
                    "Disabling analysis will keep existing OCR and object tags, but full-text search on new clips will fall back to the raw text that was copied."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            enabled = await container.settings.get(SettingsKeys.analysisEnabled)
            await refreshQueue()
            loaded = true
        }
    }

    private func refreshQueue() async {
        let depth = await container.analysis.queueDepth()
        await MainActor.run { queueDepth = depth }
    }
}
