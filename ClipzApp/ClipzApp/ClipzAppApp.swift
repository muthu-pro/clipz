// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzUI

@main
struct ClipzAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var container: AppContainer?
    @State private var bootstrapError: String?

    var body: some Scene {
        // A singleton `Window` (not `WindowGroup`): as an agent app we
        // re-open this scene by id from the tray, and `Window` focuses the
        // existing instance instead of spawning duplicate windows.
        Window("Clipz", id: "main") {
            rootView
                .frame(minWidth: 760, minHeight: 520)
                .task {
                    guard container == nil else { return }
                    do {
                        let c = try await AppContainer.bootstrap()
                        // Hand the tray a way to resurrect this window once
                        // it's been closed — only SwiftUI can do that for an
                        // LSUIElement scene.
                        c.showMainWindow = {
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        container = c
                    } catch {
                        bootstrapError = error.localizedDescription
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 680)
        // Hides the separate title-bar strip and lets TopBar fill the
        // full width of the window; traffic lights float over TopBar's
        // leading padding.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // Clipz only has the one main window; File → New Window
            // doesn't make sense here, so strip it from the menu.
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            if let container {
                SettingsRoot()
                    .environment(container)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading settings…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 640, height: 520)
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if let container {
            WindowRouter()
                .environment(container)
        } else if let bootstrapError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 40))
                Text("Clipz failed to start")
                    .font(.title2.bold())
                Text(bootstrapError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting Clipz…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }
}
