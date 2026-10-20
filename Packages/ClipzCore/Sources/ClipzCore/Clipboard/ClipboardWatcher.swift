// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit

/// Polls `NSPasteboard.general.changeCount` on a detached task and
/// feeds ClipboardService whenever the count advances.
///
/// Cocoa has never shipped an `NSPasteboardDidChangeNotification`;
/// polling `changeCount` is the official pattern. 250 ms is a sweet
/// spot for perceived-instant latency without meaningful CPU cost.
public actor ClipboardWatcher {
    /// Opt-out seam for the outgoing-paste path (swift_10). When a
    /// caller programmatically writes to the pasteboard, it first calls
    /// `ignoreNextChange()`; the watcher drops the next change event
    /// that arrives within the grace window.
    private static let ignoreGrace: TimeInterval = 1.0
    private static let pollInterval: Duration = .milliseconds(250)

    private let service: ClipboardService
    private let settings: SettingsStore
    private let classifier: ClipboardClassifier
    /// NSPasteboard is thread-safe for the APIs we use. Constructed
    /// inside the actor (from a Sendable `NSPasteboard.Name`) so we
    /// never have to cross isolation with an AppKit class that hasn't
    /// been annotated Sendable.
    private let pasteboard: NSPasteboard

    private var lastChangeCount: Int
    private var ignoreUntil: Date?
    private var pollTask: Task<Void, Never>?
    private var pausedForSleep = false
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    /// Production callers get `.general`; tests pass a unique
    /// `NSPasteboard.Name` so they don't stomp on each other or on the
    /// system clipboard.
    public init(
        service: ClipboardService,
        settings: SettingsStore,
        classifier: ClipboardClassifier = ClipboardClassifier(),
        pasteboardName: NSPasteboard.Name? = nil
    ) {
        self.service = service
        self.settings = settings
        self.classifier = classifier
        let pb = pasteboardName.map { NSPasteboard(name: $0) } ?? .general
        self.pasteboard = pb
        self.lastChangeCount = pb.changeCount
    }


    // MARK: - Lifecycle

    /// Start polling iff the `monitorClipboard` setting is on. No-op if
    /// the watcher is already running.
    public func startIfEnabled() async {
        guard pollTask == nil else { return }
        guard await settings.get(SettingsKeys.monitorClipboard) else { return }

        lastChangeCount = pasteboard.changeCount
        installSleepHandlers()

        pollTask = Task.detached(priority: .utility) { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        removeSleepHandlers()
    }

    /// Called before the app programmatically writes to the pasteboard
    /// so that the watcher doesn't turn around and re-capture its own
    /// write. The grace window auto-expires so a dropped write doesn't
    /// silently suppress the next real clipboard change.
    public func ignoreNextChange() {
        ignoreUntil = Date().addingTimeInterval(Self.ignoreGrace)
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            await tick()
        }
    }

    /// Internal `tick` — callable from tests to step the loop without
    /// waiting the poll interval.
    @discardableResult
    internal func tick() async -> ClipboardItem? {
        guard !pausedForSleep else { return nil }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current

        if let until = ignoreUntil {
            defer { ignoreUntil = nil }
            if Date() < until { return nil }
        }

        guard let payload = classifier.classify(pasteboard) else { return nil }

        // Sensitive-content policy: when the user chose "Don't save it,"
        // password/key clips (flagged by the source app) are never persisted.
        if payload.isSensitive {
            let policy = await settings.get(SettingsKeys.sensitiveContentPolicy)
            if policy == .skip { return nil }
        }

        // User exclude list — never capture from apps the user marked
        // private (on top of the always-on concealed-type rule).
        if let bundle = payload.sourceAppBundleID {
            let excluded = await settings.get(SettingsKeys.excludedAppBundleIDs)
            if excluded.contains(bundle) { return nil }
        }

        // Text-only mode: the user has said "don't collect media."
        if payload.kind.isFilesystemBacked || payload.kind == .html {
            let textOnly = await settings.get(SettingsKeys.monitorClipboardTextOnly)
            if textOnly && payload.kind.isFilesystemBacked {
                return nil
            }
        }

        return await service.capture(payload)
    }

    // MARK: - Sleep / wake

    private func installSleepHandlers() {
        // Pause polling when the machine sleeps. When we wake back up,
        // re-baseline changeCount so we don't fire a stale capture from
        // whatever the pasteboard held across sleep.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.setPaused(true) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.setPaused(false) }
        }
    }

    private func removeSleepHandlers() {
        if let s = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(s)
            sleepObserver = nil
        }
        if let w = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(w)
            wakeObserver = nil
        }
    }

    private func setPaused(_ paused: Bool) {
        pausedForSleep = paused
        if !paused {
            lastChangeCount = pasteboard.changeCount
        }
    }
}
