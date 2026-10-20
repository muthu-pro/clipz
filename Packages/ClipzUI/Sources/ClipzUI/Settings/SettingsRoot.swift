// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Top-level Settings scene contents.
public struct SettingsRoot: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            ClipboardSettingsTab()
                .tabItem { Label("Clipboard", systemImage: "list.clipboard") }

            ScreenshotsSettingsTab()
                .tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }

            AnalysisSettingsTab()
                .tabItem { Label("Analysis", systemImage: "sparkles") }

            BackupSettingsTab()
                .tabItem { Label("Backup", systemImage: "externaldrive") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }

            DangerSettingsTab()
                .tabItem { Label("Danger", systemImage: "exclamationmark.triangle") }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }
}
