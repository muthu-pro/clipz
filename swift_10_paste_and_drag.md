# swift_10 — Paste and Drag

## Purpose

Two related outgoing flows:

1. **Paste**: the user picks an item from the tray popup or list; we write it to the pasteboard and auto-trigger Cmd+V into the previously-focused app.
2. **Drag**: the user drags an item out of the app onto another app or Finder; we provide the content via a file-promise.

Replaces: `performPaste` in `electron/main.js:25-156` (robotjs keyTap), the `start-file-drag` IPC + renderer drag code, and `copy-to-desktop`.

## Current Electron behavior

### Paste
- `performPaste(itemContent, itemType)` (`main.js:25`):
  1. Stop clipboard watcher.
  2. If `type === 'html'`, run a chain of regex passes to strip HTML to plain text if the target demands it.
  3. Hide the popup window.
  4. After ~80 ms (wait for Electron window dismiss), call `robot.keyTap('v', ['command'])`.
  5. Restart clipboard watcher.
- Requires **Accessibility permission** (system toggle in Privacy & Security) for `robotjs` to synthesize keyboard events.

### Drag
- Renderer calls `window.electronAPI.startFileDrag(filename)`; main process uses Electron's `webContents.startDrag({file: path, icon: path})` — native drag with a file promise pre-resolved to an actual file in app support.

### Copy to desktop
- `copy-to-desktop` IPC writes the media file to `~/Desktop/<originalName>` via `fs.copyFile`.

## Swift design

### Accessibility grant flow

macOS gates synthetic keyboard events behind the **Accessibility** TCC grant. When our app calls `CGEvent.post`, macOS prompts the user once; the grant persists until revoked.

```swift
// Packages/ClipzCore/Sources/ClipzCore/Paste/AccessibilityPermission.swift
import ApplicationServices

public enum AccessibilityPermission {
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user with the system dialog. Returns current state.
    @discardableResult
    public static func requestWithPrompt() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [prompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    public static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
```

UI rule: the first time the user triggers a paste, call `requestWithPrompt()`. If it returns `false`, show a banner: "Grant Accessibility access to auto-paste items." with an **Open Settings…** button.

### Paste flow

```swift
// Packages/ClipzCore/Sources/ClipzCore/Paste/PasteEngine.swift
import AppKit
import CoreGraphics

public actor PasteEngine {
    private let service: ClipboardService
    private var previousFrontmostApp: NSRunningApplication?

    public init(service: ClipboardService) { self.service = service }

    /// Call just before showing the tray popup so we know who to return focus to.
    public func captureFrontmostApp() {
        self.previousFrontmostApp = NSWorkspace.shared.frontmostApplication
    }

    /// Paste an item into whichever app was frontmost before the popup opened.
    public func paste(_ item: ClipboardItem,
                      restoringFocus: Bool = true,
                      forcePlainText: Bool = false) async throws {
        // 1. Write item to pasteboard
        await writeItemToPasteboard(item, forcePlainText: forcePlainText)

        // 2. Hide tray popup (caller is expected to have dismissed it already, but
        //    this is idempotent)
        await MainActor.run { TrayController.shared?.dismissPopover() }

        // 3. Restore focus to previous app
        if restoringFocus, let prev = previousFrontmostApp, !prev.isTerminated {
            prev.activate(options: [])
            // Wait for the activation to take effect before synthesizing Cmd+V.
            try await Task.sleep(for: .milliseconds(80))
        }

        // 4. Check Accessibility permission
        guard AccessibilityPermission.isGranted() else {
            throw PasteError.accessibilityDenied
        }

        // 5. Synthesize Cmd+V
        try await synthesizeCmdV()
    }

    private func synthesizeCmdV() async throws {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // 'v' on ANSI keyboards

        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            throw PasteError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

public enum PasteError: Error, Sendable {
    case accessibilityDenied
    case eventCreationFailed
}
```

Virtual key 9 (V) is stable across ANSI keyboard layouts. For international layouts (AZERTY, Dvorak), `CGEventKeyboardSetUnicodeString` on the keyDown event before posting is more robust, but system-wide paste uses the **keyboard shortcut**, not a unicode V character — so virtual key 9 remains correct; macOS maps it to the user's actual V key.

### Writing item to pasteboard

```swift
extension PasteEngine {
    func writeItemToPasteboard(_ item: ClipboardItem, forcePlainText: Bool) async {
        switch item.kind {
        case .text:
            await service.writeText(item.content)

        case .html:
            if forcePlainText {
                let plain = HTMLToPlainText.strip(item.content)
                await service.writeText(plain)
            } else {
                await service.writeHTML(item.content,
                                        fallbackPlain: HTMLToPlainText.strip(item.content))
            }

        case .image, .screenshot:
            let url = FileStore.shared.mediaURL(for: item.content)
            if let data = try? Data(contentsOf: url) {
                await service.writeImage(data)
            }

        case .video, .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            let url = FileStore.shared.mediaURL(for: item.content)
            await service.writeFile(at: url)
        }
    }
}
```

`ClipboardService.writeHTML(_:fallbackPlain:)` writes both `.html` and `.string` pasteboard types so apps that want plain text get it:

```swift
public func writeHTML(_ html: String, fallbackPlain: String) async {
    await watcher.ignoreNextChange()
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(html, forType: .html)
    pb.setString(fallbackPlain, forType: .string)
}
```

### Force-plain-text option

Current Electron has `performPaste` regex-strip HTML before paste — purpose is to let the user paste into a plain-text field (Terminal, Slack code block) without dragging formatting. Swift equivalent: a **modifier key** on the popup card:

- **Enter / click** → normal paste (HTML preserved if the item is HTML).
- **Option + Enter / option+click** → force plain text.

HTML stripping uses `NSAttributedString(data: …, options: [.documentType: .html])` — robust against malformed HTML in a way the regex chain isn't (see swift_03).

### File drag

Replaces `start-file-drag` + Electron `webContents.startDrag`. SwiftUI drag modifier on each item cell:

```swift
struct ClipboardItemCell: View {
    let item: ClipboardItem

    var body: some View {
        content
            .onDrag { dragProvider(for: item) }
    }

    private func dragProvider(for item: ClipboardItem) -> NSItemProvider {
        switch item.kind {
        case .text, .html:
            let provider = NSItemProvider(object: item.content as NSString)
            return provider

        case .image, .screenshot:
            let url = FileStore.shared.mediaURL(for: item.content)
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier,
                                                  fileOptions: [],
                                                  visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            provider.suggestedName = item.originalName ?? "\(item.id).png"
            return provider

        case .video, .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            let url = FileStore.shared.mediaURL(for: item.content)
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            provider.suggestedName = item.originalName
            return provider
        }
    }
}
```

For large files we use **NSFilePromiseProvider** (the sandbox-safe way to provide files on drag):

```swift
final class ClipFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    let sourceURL: URL
    let suggestedFilename: String

    init(typeIdentifier: String, sourceURL: URL, suggestedFilename: String) {
        self.sourceURL = sourceURL
        self.suggestedFilename = suggestedFilename
        super.init()
        self.fileType = typeIdentifier
        self.delegate = self
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              fileNameForType fileType: String) -> String {
        suggestedFilename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              writePromiseTo url: URL,
                              completionHandler: @escaping (Error?) -> Void) {
        do {
            try FileManager.default.copyItem(at: sourceURL, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
```

Use `.onDrag { … }` with an `NSItemProvider` that wraps the promise provider. The receiving side (Finder, Mail, Slack) calls back when it needs the actual bytes; we copy lazily.

### Copy to desktop

Current Electron `copy-to-desktop` silently writes to `~/Desktop`. That fails in sandbox — the app has no `~/Desktop` access by default. Replacement:

```swift
@MainActor
public func copyToDesktop(item: ClipboardItem) async {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()
                                .appending("/Desktop"))  // hint, user confirms
    panel.nameFieldStringValue = item.originalName ?? defaultName(for: item)
    panel.allowedContentTypes = allowedContentTypes(for: item.kind)

    guard await panel.begin() == .OK, let dest = panel.url else { return }

    do {
        if let sourceURL = FileStore.shared.mediaURLIfExists(for: item.content) {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } else {
            try item.content.write(to: dest, atomically: true, encoding: .utf8)
        }
    } catch {
        await showError("Couldn't save: \(error.localizedDescription)")
    }
}
```

**Multi-file copy** (the current app has Cmd+Shift+D on a hovered item to copy-to-desktop; extending to multi-select):

- For a single item: NSSavePanel.
- For multiple selection: NSOpenPanel in "directory only" mode — the user picks a folder once, and we write all selected items into it.

## Edge cases & gotchas

1. **Accessibility prompt quirks** — the first `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` call shows the system prompt; subsequent calls with `true` **do not** re-prompt (macOS suppresses after the first decline). If the user denies, our only recourse is `AccessibilityPermission.openSettings()`.

2. **Kernel-level restriction for synthetic events** — `CGEvent.post` requires Accessibility. A user can *explicitly* disable the app in Settings → Privacy & Security → Accessibility at any time; our paste attempts then fail silently (macOS drops the events). Periodically call `isGranted()` and show a banner if it flipped false.

3. **Activation timing** — 80 ms sleep between app-activate and Cmd+V is empirical; works on M1/M2. On slow displays or with heavy animation, 80 ms might not be enough. If tests flake, bump to 120 ms.

4. **International keyboards** — virtual key 9 is 'v' on ANSI/ISO; on JIS keyboards it's still 'v' (layout-based virtual keys are a Windows thing, on macOS the VK is position-based). So we don't need per-layout handling.

5. **Dead-key states** — if the user is composing a dead key (´ + e), CGEvent injection into that app can confuse the input method. Rare. No mitigation; rely on the 80 ms activation delay pushing our paste after the composition resolves.

6. **Pasting into password fields** — macOS blocks synthesized paste into secure input fields (1Password icon appears in menu bar to indicate "secure input"). Paste silently does nothing. Show no banner; this is a user-facing macOS protection, not our bug.

7. **Multi-monitor popover** — tray popover shows on whichever display the menu bar lives on (usually the main). Capture frontmost app *before* the popover shows so we can restore focus to the correct app even if the user rubber-banded around.

8. **Paste + forcePlainText for images** — nonsensical; ignore the flag for non-text kinds.

9. **File promise for broken references** — if the item's content file was deleted outside our knowledge (user trashed the container folder manually, etc.), the drag fails when the drop target requests bytes. Show a one-off error toast ("This item's file is missing").

10. **Reading Accessibility state from a sandboxed app** — `AXIsProcessTrusted()` works in sandbox. The actual grant persists in `tccd`'s database, which we read indirectly via this API. MAS-approved.

11. **`NSSavePanel` in a tray popover** — the popover dismisses when focus leaves it. Opening a sheet on top of the popover works, but a standalone save panel is displayed as a modal attached to the main window. If the popover is the only window visible, attach the save panel to the main window *if it exists*, otherwise open as standalone panel.

## MAS notes

- **Accessibility permission** is TCC-based, not entitlement-based. Works in sandbox. No `NSApplescriptUsageDescription` or similar needed.
- **`CGEvent.post`** — explicitly allowed under sandbox when Accessibility is granted.
- **`NSSavePanel` / `NSOpenPanel`** — sandbox-allowed and grant implicit access to the selected URL (Powerbox mechanism).
- **`NSItemProvider` drag** — sandbox-compatible. Dragged files must live in our container or be user-selected.
- **`NSFilePromiseProvider`** — sandbox-safe; the drop target operates through a standardized handoff.
- **`x-apple.systempreferences:` URL** — sandbox-allowed via `NSWorkspace.shared.open(_:)`.
- **Reading the previously-frontmost app's activation state** — `NSRunningApplication.activate(options:)` works without additional entitlement.

## Open questions

- **Auto-paste as default?** — the current app auto-pastes on item click. Some users prefer "copy only, I'll paste manually". Add a setting: "After selecting an item: ( ) Only copy to clipboard  (•) Copy and paste into previous app". Default auto-paste.
- **Paste-with-transform** — add variants like "Paste as lowercase", "Paste without formatting", in context menu. Scope creep; defer.
- **Drag as link for URL text** — if a text item is a URL, when dragged to Safari or Mail, should we register `public.url` type so it drops as a link, not plain text? Yes — detect URL shape, register both types.
- **Promise-based drag for *all* kinds** — currently we use NSItemProvider direct for small items, NSFilePromiseProvider for large ones. Unifying to always-promise simplifies the code but adds a round-trip for the drop target; measure.
