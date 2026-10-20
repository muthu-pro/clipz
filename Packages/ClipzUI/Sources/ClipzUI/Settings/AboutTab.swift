// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

/// About screen. App icon, version, support links, privacy statement.
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            appIcon

            ClipzWordmark(size: 32)

            Text("Version \(marketingVersion) (build \(buildNumber))")
                .foregroundStyle(.secondary)
                .font(.callout)

            HStack(spacing: 16) {
                Link("clipz.tech",
                     destination: URL(string: "https://clipz.tech")!)
                Link("Source (GitHub)",
                     destination: URL(string: "https://github.com/muthu-pro/clipz-native")!)
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
