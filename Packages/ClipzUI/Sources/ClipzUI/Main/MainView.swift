// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import ClipzCore

/// The main-window shell. Clipz is clipboard-only, so there's no tab
/// switcher. The "Clipz" wordmark + logo lives in the
/// title bar itself via NSTitlebarAccessoryViewController — SwiftUI's
/// `.toolbar` was unreliable about right-anchoring when it held just
/// one item, so we route around it.
public struct MainView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppContainer.self) private var container

    @State private var showOnboarding = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ClipboardContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowChromeConfigurator(openSettings: openSettings))
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .environment(container)
        }
        .task {
            // First run: greet and prime Accessibility.
            if await container.settings.get(SettingsKeys.hasSeenOnboarding) == false {
                showOnboarding = true
            }
        }
    }
}

/// Button hosted inside the title-bar accessory. "Clipz" wordmark first,
/// logo after, the whole pill clickable. Opens SwiftUI's Settings scene;
/// while that window is on its way we swap in a "Clipz – Settings"
/// loading state so the click has visible feedback.
private struct TitlebarSettingsButton: View {
    let openSettings: () -> Void
    @State private var isOpening = false

    var body: some View {
        Button {
            guard !isOpening else { return }
            isOpening = true
            openSettings()
            waitForSettingsWindow()
        } label: {
            HStack(spacing: 5) {
                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text("Clipz – Settings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    ClipzWordmark(size: 13)
                        .fixedSize()
                    logo
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .help("Settings (⌘,)")
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var logo: some View {
        if let ns = NSImage(named: "ClipzLogo") {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 16, height: 16)
        }
    }

    /// Drop the loading state once the Settings window is actually on
    /// screen. SwiftUI doesn't surface a callback for opening Settings,
    /// and notification timing varies, so poll briefly.
    private func waitForSettingsWindow() {
        let deadline = Date().addingTimeInterval(3)
        Task { @MainActor in
            while Date() < deadline {
                if Self.settingsWindowIsVisible() {
                    isOpening = false
                    return
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            isOpening = false
        }
    }

    private static func settingsWindowIsVisible() -> Bool {
        for window in NSApp.windows where window.isVisible {
            if let id = window.identifier?.rawValue,
               id.localizedCaseInsensitiveContains("settings") {
                return true
            }
            if window.title.localizedCaseInsensitiveContains("settings") {
                return true
            }
        }
        return false
    }
}

/// SwiftUI's `.hiddenTitleBar` style suppresses the title bar's chrome
/// but doesn't extend the content view under it — so a title-bar-sized
/// dead band remains above content. We grab the host `NSWindow` once
/// it's attached, turn on `.fullSizeContentView`, and install a trailing
/// title-bar accessory hosting our "Clipz" button.
private struct WindowChromeConfigurator: NSViewRepresentable {
    let openSettings: OpenSettingsAction

    private static let accessoryIdentifier = NSUserInterfaceItemIdentifier(
        "tech.clipz.app.titlebarAccessory"
    )

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Idempotent across SwiftUI updates: only install once per window.
        if window.titlebarAccessoryViewControllers
            .contains(where: { $0.identifier == Self.accessoryIdentifier }) {
            return
        }

        let action = openSettings
        let hosting = NSHostingView(
            rootView: TitlebarSettingsButton(openSettings: { action() })
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let fitting = hosting.fittingSize
        container.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fitting.width, 120),
            height: max(fitting.height, 28)
        )

        let vc = NSTitlebarAccessoryViewController()
        vc.identifier = Self.accessoryIdentifier
        vc.layoutAttribute = .trailing
        vc.view = container
        window.addTitlebarAccessoryViewController(vc)
    }
}
