// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import SwiftUI
import ClipzCore

/// Owns the NSStatusItem and the NSPopover that hangs below it. Kept as
/// an NSObject so it can be the target of Cocoa action selectors
/// (button click, menu items).
@MainActor
public final class TrayController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// A bundled ~0.3 s bell chime. Held as a property: a temporary
    /// `NSSound` can be deallocated before the async `play()` finishes.
    private let captureChime = TrayController.loadCaptureChime()
    private weak var container: AppContainer?
    private var captureObserverTask: Task<Void, Never>?
    private var progressTimeoutTask: Task<Void, Never>?

    public init(container: AppContainer) {
        self.container = container
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        configureStatusButton()
        configurePopover(container: container)
        observeCaptures(broadcaster: container.broadcaster)
    }

    deinit {
        captureObserverTask?.cancel()
        progressTimeoutTask?.cancel()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        // The `TrayIconTemplate` asset ships at 20 / 40 / 60 pt. Its
        // Contents.json sets `template-rendering-intent = template`, so
        // `NSImage(named:)` returns it with `isTemplate == true` — macOS
        // would then strip the asset's colors and render only the alpha
        // mask as a single-ink silhouette (the "black icon" the user
        // sees). Overriding `isTemplate = false` lets the actual colored
        // Clipz mark show through, regardless of system appearance.
        let image = NSImage(named: "TrayIconTemplate")
            ?? NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Clipz"
            )
        image?.isTemplate = false
        button.image = image
        button.toolTip = "Clipz"
        button.target = self
        button.action = #selector(handleButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Layer-back so the capture pulse has somewhere to attach.
        // NSStatusBarButton is already layer-backed on modern macOS;
        // setting this explicitly is a no-op safeguard.
        button.wantsLayer = true
    }

    private func configurePopover(container: AppContainer) {
        popover.behavior = .transient   // auto-dismiss on outside click
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: TrayPopupView(onSelect: { [weak self] item in
                guard let self else { return }
                Task { await self.handleSelect(item) }
            })
            .environment(container)
            .frame(width: 360, height: 480)
        )
    }

    // MARK: - Click handling

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Right-click surfaces the quick-paste popover.
            togglePopover()
        } else {
            // Left-click brings up the full main app window.
            openMainWindow()
        }
    }

    public func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Snapshot who owns the focus *before* our popover takes it —
        // PasteEngine needs this to restore focus after an auto-paste.
        container?.pasteEngine.captureFrontmostApp()

        // Gate on the biometric lock *before* presenting so the auth sheet
        // doesn't dismiss a transient popover mid-prompt. When the lock is
        // off this resolves immediately.
        Task { @MainActor in
            if let container, await container.ensureUnlocked() == false { return }
            self.presentPopover(from: button)
        }
    }

    private func presentPopover(from button: NSStatusBarButton) {
        // A status-item *click* implicitly activates us, but the global
        // hotkey does not — so without this the hotkey-opened popover sits
        // in the background and the first click only activates it instead
        // of selecting a row (and auto-paste never fires). Activating after
        // the capture keeps the paste target intact.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
    }

    public func dismissPopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: - Main window

    @objc private func openMainWindow() {
        // Resolve the clicked display and the icon's on-screen rect *before*
        // anything else — the cursor and the status item are both still
        // parked where the user clicked at this instant.
        let target = clickedScreen()
        let anchor = statusItem.button?.window?.frame

        // Gate on the biometric lock, same as the popover and quick-paste,
        // so the main window can't reveal clips without authentication.
        // Applies the user's re-lock mode via `ensureUnlocked()`.
        Task { @MainActor in
            if let container, await container.ensureUnlocked() == false { return }
            self.revealMainWindow(anchor: anchor, target: target)
        }
    }

    private func revealMainWindow(anchor: NSRect?, target: NSScreen?) {
        // Ask SwiftUI to surface (or re-instantiate) the main window. As an
        // LSUIElement agent app the window is destroyed on close, so walking
        // NSApp.windows isn't enough; the scene must be re-opened by id.
        if let show = container?.showMainWindow {
            show()
        } else {
            // Fallback for the window-already-exists case if the bridge
            // hasn't been installed yet.
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
        }

        // The window may be created asynchronously by SwiftUI, so retry
        // until it appears, then drop it beneath the clicked icon.
        placeMainWindow(near: anchor, on: target, attemptsLeft: 20)
    }

    /// Position the main window just under the menu bar, left-aligned to the
    /// status item the user clicked. SwiftUI restores a scene's saved frame
    /// at creation time and may not have made the window yet, so we poll for
    /// it before repositioning.
    private func placeMainWindow(near anchor: NSRect?, on screen: NSScreen?, attemptsLeft: Int) {
        guard let screen else { return }
        if let window = mainWindow(), window.isVisible {
            position(window, near: anchor, on: screen)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.placeMainWindow(near: anchor, on: screen, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Drop `window` against the top of `screen` with its left edge aligned
    /// to the icon's `anchor`, clamped so it never spills off any edge (the
    /// tray sits at the right of the menu bar, so a wide window gets pushed
    /// back left to stay fully visible). Falls back to horizontal centering
    /// when the anchor is unavailable.
    private func position(_ window: NSWindow, near anchor: NSRect?, on screen: NSScreen) {
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)

        let desiredX = anchor?.minX ?? (visible.midX - frame.width / 2)
        let x = min(max(desiredX, visible.minX), visible.maxX - frame.width)
        let y = visible.maxY - frame.height   // hang from just below the menu bar

        frame.origin = NSPoint(x: x, y: y)
        window.setFrame(frame, display: true)
    }

    /// The app's main scene window, if one currently exists. Prefer the
    /// id SwiftUI assigns the scene; fall back to the frontmost standard
    /// titled window (anything but our own status-bar popover) in case the
    /// identifier isn't surfaced.
    private func mainWindow() -> NSWindow? {
        if let byID = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            return byID
        }
        let popoverWindow = popover.contentViewController?.view.window
        return NSApp.windows.first {
            $0 !== popoverWindow
                && $0.isVisible
                && $0.styleMask.contains(.titled)
                && $0.canBecomeMain
        }
    }

    /// The screen whose menu bar holds the status item the user clicked.
    /// We can't trust `statusItem.button?.window?.screen` — that system
    /// status-bar window frequently reports the primary display even when
    /// the icon was clicked on a secondary display's menu bar. The cursor,
    /// however, is parked right on the icon at click time, so the screen
    /// under the mouse is the reliable signal. Fall back to the status
    /// window's screen, then the primary, if the hit-test ever misses.
    private func clickedScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? statusItem.button?.window?.screen
            ?? NSScreen.main
    }

    // MARK: - Selection → pasteboard

    private func handleSelect(_ item: ClipboardItem) async {
        guard let container else { return }

        // Sensitive clips (passwords/keys) require Touch ID before we put
        // them on the pasteboard.
        guard await container.ensureSensitiveAccess(to: item) else {
            dismissPopover()
            return
        }

        // Always write the clip to the pasteboard first. This is what
        // makes the manual ⌘V workflow reliable — regardless of whether
        // auto-paste is on, regardless of Accessibility permission,
        // clicking a row puts the clip on the clipboard.
        await PasteboardWriter.write(
            item,
            fileStore: container.fileStore,
            watcher: container.clipboardWatcher
        )

        let autoPaste = await container.settings.get(SettingsKeys.autoPaste)
        if autoPaste && AccessibilityPermission.isGranted() {
            // Auto-paste path: dismiss immediately so the previously-
            // focused app can receive the synthesized ⌘V. The successful
            // paste itself is the user's confirmation.
            dismissPopover()
            _ = await container.pasteEngine.paste()
        } else {
            // Manual-paste path: hold the popover open briefly so the
            // row's "Copied" badge is visible, then dismiss. The user
            // pastes wherever they want with ⌘V. We also nudge the
            // Accessibility prompt the first time so they have the
            // option to enable auto-paste later.
            if autoPaste { _ = AccessibilityPermission.requestWithPrompt() }
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismissPopover()
        }
    }

    // MARK: - Capture feedback

    /// Subscribe to the broadcaster for capture lifecycle events:
    /// - `.captureBegan` (file-backed kinds only) starts an in-progress
    ///   pulse while the file copy is happening.
    /// - `.captured` clears that pulse and plays the brief confirmation
    ///   feedback (Tink + scale bounce).
    ///
    /// Clips the user pastes *out* of the tray don't reach either event
    /// because `ClipboardWatcher` suppresses the echo, so this fires
    /// only for real external captures.
    private func observeCaptures(broadcaster: EventBroadcaster) {
        captureObserverTask = Task { @MainActor [weak self] in
            let stream = await broadcaster.events()
            for await event in stream {
                guard let self else { return }
                switch event {
                case .captureBegan:
                    self.startProgressAnimation()
                case .captured:
                    self.stopProgressAnimation()
                    self.playCaptureFeedback()
                default:
                    break
                }
            }
        }
    }

    /// "Ambient confirmation, not interruption." A short, quiet bell chime
    /// plus a small peripheral pulse. `stop()` before `play()` so rapid
    /// captures re-trigger from the start.
    private func playCaptureFeedback() {
        if let chime = captureChime {
            chime.stop()
            chime.volume = 0.5
            chime.play()
        }
        pulseStatusButton()
    }

    /// Load the bundled capture chime from the package's resource bundle.
    private static func loadCaptureChime() -> NSSound? {
        guard let url = Bundle.module.url(forResource: "CaptureChime", withExtension: "wav")
        else { return NSSound(named: "Tink") }  // fallback: short system chime
        return NSSound(contentsOf: url, byReference: true)
    }

    /// Brief centered scale pulse on the status button's layer. We use
    /// translate-scale-translate transforms rather than mutating
    /// `anchorPoint` because that would offset the button's frame for
    /// the duration of the animation — fine for a single fire-and-
    /// forget pulse, but the cumulative drift over many captures would
    /// shift the menu-bar icon visibly.
    private func pulseStatusButton() {
        guard let button = statusItem.button,
              let layer = button.layer else { return }
        let bounds = layer.bounds
        let cx = bounds.midX
        let cy = bounds.midY
        func centered(scale: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            return t
        }
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [
            NSValue(caTransform3D: centered(scale: 1.0)),
            NSValue(caTransform3D: centered(scale: 1.18)),
            NSValue(caTransform3D: centered(scale: 1.0)),
        ]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 0.28
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        layer.add(pulse, forKey: "clipzCapturePulse")
    }

    // MARK: - In-progress animation (file captures)

    /// Slow repeating pulse that runs while a file capture is in flight
    /// — copy started, hasn't completed yet. Same centered-transform
    /// trick as the one-shot pulse so the icon doesn't drift in the
    /// menu bar over many file copies.
    private func startProgressAnimation() {
        guard let button = statusItem.button,
              let layer = button.layer else { return }
        // If the animation is already running, leave it alone — restart
        // would cause a visible "snap" each time a queued capture began.
        if layer.animation(forKey: "clipzCaptureProgress") != nil {
            return
        }
        let bounds = layer.bounds
        let cx = bounds.midX
        let cy = bounds.midY
        func centered(scale: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            return t
        }
        let progress = CAKeyframeAnimation(keyPath: "transform")
        progress.values = [
            NSValue(caTransform3D: centered(scale: 1.0)),
            NSValue(caTransform3D: centered(scale: 1.13)),
            NSValue(caTransform3D: centered(scale: 1.0)),
        ]
        progress.keyTimes = [0, 0.5, 1.0]
        progress.duration = 0.8
        progress.repeatCount = .infinity
        progress.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        layer.add(progress, forKey: "clipzCaptureProgress")

        // Safety net so a dropped `.captured` (persist failed silently,
        // broadcaster consumer fell behind) doesn't leave the icon
        // pulsing forever. 5 s comfortably covers even multi-hundred-MB
        // file imports.
        progressTimeoutTask?.cancel()
        progressTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.stopProgressAnimation()
        }
    }

    private func stopProgressAnimation() {
        progressTimeoutTask?.cancel()
        progressTimeoutTask = nil
        statusItem.button?.layer?.removeAnimation(forKey: "clipzCaptureProgress")
    }
}
