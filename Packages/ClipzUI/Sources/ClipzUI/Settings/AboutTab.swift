// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzCore

/// About screen. App icon, version, update status, support links, privacy.
struct AboutTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        VStack(spacing: 14) {
            appIcon

            ClipzWordmark(size: 32)

            Text("Version \(marketingVersion) (build \(buildNumber))")
                .foregroundStyle(.secondary)
                .font(.callout)

            updateRow

            HStack(spacing: 16) {
                Link("clipz.tech",
                     destination: URL(string: "https://clipz.tech")!)
                Link("Source (GitHub)",
                     destination: URL(string: "https://github.com/muthu-pro/clipz")!)
                Link("Support",
                     destination: URL(string: "mailto:support@clipz.tech")!)
            }
            .font(.callout)

            Text("Free & open source — GPLv3")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Created by")
                    .foregroundStyle(.secondary)
                Link("Muthukumar Thamilmani",
                     destination: URL(string: "https://www.linkedin.com/in/muthukumar-t/")!)
            }
            .font(.callout)

            Divider()
                .frame(maxWidth: 240)
                .padding(.vertical, 4)

            VStack(spacing: 2) {
                // `year` is a String so SwiftUI's Text doesn't apply a
                // locale grouping separator to the Int (which rendered
                // "2,026" instead of "2026").
                Text("© \(year) Muthukumar Thamilmani")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("100% on-device. No cloud sync. No data collection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Built with GRDB.swift and ZIPFoundation (MIT).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Update status + actions, driven by the shared `container.updateState`.
    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: 8) {
            switch container.updateState {
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Checking for updates…")
                    .font(.caption).foregroundStyle(.secondary)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("You're on the latest version.")
                    .font(.caption).foregroundStyle(.secondary)
            case .available(let info):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("Update available: \(info.version)")
                    .font(.caption.weight(.medium))
                Button("Download…") {
                    NSWorkspace.shared.open(info.downloadURL ?? info.releaseURL)
                }
                .controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't check for updates.")
                    .font(.caption).foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }

            if !isChecking {
                Button("Check for Updates") {
                    Task { await container.checkForUpdates(force: true) }
                }
                .controlSize(.small)
            }
        }
        .frame(minHeight: 20)
    }

    private var isChecking: Bool {
        if case .checking = container.updateState { return true }
        return false
    }

    private var appIcon: some View {
        // Prefer the branded ClearLight / ClearDark logo from the
        // bundle so the About surface always reads as "Clipz" even if
        // macOS hasn't refreshed its LaunchServices cache of the
        // app-icon yet. Falls back to the running app's live icon.
        Image(nsImage:
            NSImage(named: "ClipzLogo")
                ?? NSApp.applicationIconImage
                ?? NSImage(named: NSImage.applicationIconName)
                ?? NSImage()
        )
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 112, height: 112)
    }

    private var year: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
