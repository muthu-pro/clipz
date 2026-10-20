# swift_23 — Accessibility and Contrast

## Purpose

Every visual element audited for: keyboard navigation, VoiceOver, contrast, reduced motion, Dynamic Type. Because we dropped the in-app theme system (swift_15) in favour of macOS system appearance, contrast is handled by Apple's semantic colors rather than a runtime adjuster — this file no longer ports `src/utils/wcag.ts`.

## Current Electron behavior (not carried over)

- WCAG AAA contrast enforced via `ensureAAContrast` (7:1 normal, 4.5:1 large) — adjusted iteratively by `src/utils/wcag.ts`. Two full decision docs (`AAA_CONTRAST_COMPLETE.md`, `AAA_CONTRAST_FIX.md`) documented the algorithm. **Not ported.** Apple's HIG-compliant semantic colors meet AAA under both Light and Dark without runtime adjustment.
- No explicit VoiceOver support (Electron apps often fall back on Chromium's ARIA handling, which is imperfect on macOS).
- No explicit reduce-motion or reduce-transparency handling.

## Swift design

### Goals

1. **Contrast**: use SwiftUI semantic colors (`.primary`, `.secondary`, etc.) and system materials. Apple guarantees AAA for HIG-conforming components; our obligation is to not override with hex fills that break the guarantee.
2. **VoiceOver**: every list cell has a descriptive label; every button has a label/hint.
3. **Keyboard navigation**: every action reachable via keyboard without mouse.
4. **Reduce motion**: respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — short or disabled animations.
5. **Reduce transparency**: swap vibrancy for solid color.
6. **Dynamic type**: font scales via user's system font size.
7. **VoiceOver + keyboard through the tray popover**: the hardest surface; special focus.
8. **Paywall accessibility**: `PaywallWindow` (swift_18) must be fully keyboard-reachable and VoiceOver-navigable — it's the only screen a post-trial user can interact with.

## VoiceOver labels

### Clipboard item cells

```swift
ClipboardItemCell(item: item)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(for: item))
    .accessibilityHint("Double-tap to paste. Use the rotor for more actions.")
    .accessibilityCustomActions([
        .init(name: "Copy") { Task { await container.pasteEngine.writeItemToPasteboard(item, forcePlainText: false); return true } },
        .init(name: "Copy to Desktop") { Task { await container.pasteEngine.copyToDesktop(item: item); return true } },
        .init(name: "Delete") { Task { try? await container.clipboardService.delete(id: item.id); return true } },
    ])

func accessibilityLabel(for item: ClipboardItem) -> String {
    let kindWord: String = {
        switch item.kind {
        case .text: return "Text"
        case .image: return "Image"
        case .screenshot: return "Screenshot"
        case .html: return "Rich text"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .doc, .docx: return "Word document"
        case .xls, .xlsx: return "Spreadsheet"
        case .numbers: return "Numbers document"
        }
    }()
    let source = item.sourceApp?.name ?? "Unknown app"
    let excerpt = (item.searchPreview ?? item.content).prefix(80)
    let time = item.createdAt.formatted(.relative(presentation: .named))
    return "\(kindWord) copied from \(source), \(time). \(excerpt)"
}
```

Examples:

- "Text copied from Safari, 3 minutes ago. The quick brown fox jumps over…"
- "Screenshot copied from Screenshot, 1 hour ago. 2 detected objects: person, laptop."

### Tray popover

```swift
TrayPopupView()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Clipz clipboard history")
    .accessibilityHint("Select an item to paste it into the previous app.")
```

Keyboard users can navigate with arrow keys + Enter; VoiceOver users rotate through items via the rotor.

### Buttons / toggles

Every button has a label + hint where needed:

```swift
Button(action: ...) { Image(systemName: "trash") }
    .accessibilityLabel("Delete this item")

Toggle("Monitor clipboard", isOn: $monitor)
    .accessibilityHint("When on, Clipz captures each copy automatically.")
```

SwiftUI's `Toggle` already exposes its label; the hint adds a spoken explanation.

## Keyboard navigation

Every major action is keyboard-reachable:

| Key | Action | Location |
|---|---|---|
| `Cmd+,` | Open Settings | menu bar (automatic) |
| `Cmd+F` | Focus search | ClipboardView |
| `Cmd+N` | New note | Commands |
| `Cmd+Shift+D` | Copy hovered to Desktop | ClipboardView |
| `Cmd+Shift+V` | Toggle tray popover | global hotkey |
| `Esc` | Close preview / popover | context |
| `Return` | Paste selected item | tray popover + list |
| `Option+Return` | Paste as plain text | same |
| `Delete` | Delete selected item | list |
| `↑ ↓` | Navigate rows | list + popover |
| `Space` | Preview selected item | list |
| `Cmd+.` | Cancel in-flight search | search bar |

`FocusState` for in-view keyboard focus (e.g., `@FocusState private var searchFocused: Bool`). App-level shortcuts registered via `CommandMenu` + `.keyboardShortcut`.

## Reduce motion

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Usage
.animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: selection)
```

Where we have custom animations (search glow pulse, popover slide-in, tray icon rotation when analyzing), check `reduceMotion` and either skip or drastically shorten the animation.

### Animations to audit

| Animation | Normal | Reduced |
|---|---|---|
| Search glow pulse on Cmd+F | 0.25s fade | none |
| Item cell hover scale | 0.15s | none |
| Tray popover open/close | 0.18s slide | instant |
| Sidebar width change | 0.2s | instant |
| Modal sheet present | default | `.easeIn(duration: 0.1)` |

## Reduce transparency

```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

// In VibrancyView wrapper
var body: some View {
    if reduceTransparency {
        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
    } else {
        VibrancyView(material: material, blendingMode: blendingMode)
    }
}
```

Every `VibrancyView` use in swift_11 / swift_15 goes through this wrapper.

## Dynamic Type

SwiftUI respects user text size preferences by default. Ensure:

- Use semantic font tokens (`.body`, `.caption`, `.title3`) instead of hardcoded sizes.
- Test with **Settings → Accessibility → Display → Text Size** at max.
- For list cells: use `.minimumScaleFactor(0.8)` where layout breaks at max size.
- Multi-line labels: prefer `Text(...)` with `.fixedSize(horizontal: false, vertical: true)` so they wrap.

Fonts:

- Body: `.body` (17pt default)
- Captions: `.caption` (12pt)
- Titles: `.title2`, `.title3`
- Monospaced (code): `.system(.body, design: .monospaced)`

## Contrast

Runtime contrast adjustment is **not** implemented. Apple's semantic colors on NSVisualEffectView materials meet WCAG AAA (7:1 normal, 4.5:1 large) under both Light and Dark appearances; the burden shifts from "adjust at runtime" to "never override with hex fills".

**Rules of thumb:**

- Foreground text: always one of `.primary`, `.secondary`, `.tertiary`, or a system-derived `Color(nsColor: …)`.
- Backgrounds: prefer `.regularMaterial` / `.thinMaterial` / `Color(nsColor: .windowBackgroundColor)`.
- Accent: `.accentColor` or `Color(nsColor: .controlAccentColor)` — follows the user's System Settings → Appearance → Accent Color.
- Status indicators (warning, error, success): use SwiftUI's `.orange`, `.red`, `.green` overlaid on system backgrounds; Apple's default palette meets AAA in both appearances when paired with system backgrounds.
- If a design calls for a tinted chip or badge, rely on `.tint(_:)` and materials rather than hex; that way "Increase contrast" and dark mode both get the correct variant for free.

Verification is by **Accessibility Inspector → Audit** (see checklist below), not by runtime math.

## High-contrast mode

Users with **Accessibility → Display → Increase contrast** toggled want bolder borders, stronger text:

```swift
@Environment(\.accessibilityContrast) private var contrast

Text("Monitor clipboard")
    .fontWeight(contrast == .increased ? .semibold : .regular)
```

Borders on cards: thicker + more opaque when `contrast == .increased`.

## VoiceOver test flow

Add a testing checklist (and pair of XCUITest scripts):

1. Enable VoiceOver (`Cmd+F5`).
2. Navigate from launch → main list → first item → context actions → delete.
3. Verify every label makes sense ("Image copied from Safari, 3 minutes ago, 2 objects detected").
4. Activate a custom action via VoiceOver rotor.
5. Confirm focus returns to the list after action.
6. Navigate to Settings → Pro tab; verify purchase flow is reachable with Tab and the Purchase button activates with Return.
7. With trial back-dated (or Keychain cleared) so the app is in `.expired`, confirm that `PaywallWindow` is announced on focus, the "Unlock Clipz" and "Restore Purchase" buttons are reachable by Tab, and `Cmd+W` quits.

## Accessibility audit checklist

Before each release:

- [ ] Every interactive element has `accessibilityLabel` (or a visible Text label SwiftUI picks up).
- [ ] Every image-only button has an `accessibilityLabel`.
- [ ] Custom gestures have equivalents via `accessibilityCustomActions`.
- [ ] No `accessibilityHidden(true)` on content that isn't truly decorative.
- [ ] Color alone never conveys meaning (completion uses checkmark + color, not color alone).
- [ ] Focus ring visible on every control (SwiftUI default; verify with keyboard navigation).
- [ ] Reduce Motion scenario works (enable in Accessibility settings, walk through app).
- [ ] Reduce Transparency scenario works.
- [ ] High Contrast scenario works.
- [ ] Dynamic Type at maximum size — no clipped text, no overlapping elements.
- [ ] VoiceOver walks the whole app.
- [ ] Keyboard-only walk: every user task achievable without touching the mouse.

## Accessibility-related code locations

- `Packages/ClipzUI/Sources/ClipzUI/Accessibility/` — helper modifiers only (SF Symbols wrappers, focus helpers). No contrast utilities.
- View files: `.accessibilityLabel`, `.accessibilityCustomActions` per element.

## RTL readiness

Not a v1 goal — the app is English-only in v1 — but:

- Use `.leading` / `.trailing` (layout direction-aware) instead of `.left` / `.right`.
- Use `Text(...)` rather than manual string concatenation for dates/numbers.

This keeps v1.1 localization cheap.

## Edge cases & gotchas

1. **VoiceOver rotor actions** — register per-cell actions, not per-row-group. SwiftUI composes them into the rotor automatically.

2. **Focus after modal dismiss** — SwiftUI can lose focus on sheet/popover dismiss. Restore via `.focused($field)` with explicit state management.

3. **VoiceOver reading long content** — if a clipboard item is 10,000 characters, VoiceOver reads forever. Truncate the label to ~200 chars; VoiceOver's "read full" action is still available via system gesture.

4. **OCR data in VoiceOver label** — for image items, include "2 detected objects: person, laptop" in the label; for OCR content, include a short excerpt.

5. **Drag-and-drop accessibility** — macOS provides keyboard-alternative drag via the VoiceOver rotor. Our items support this automatically when they have an `onDrag` modifier + `accessibilityCustomActions` for the same targets.

6. **Dynamic Type with fixed-size cells** — if a cell's layout assumes 44pt height, at extraordinarily large text sizes it breaks. Use `.frame(minHeight: 44)` instead of `.frame(height: 44)`.

7. **Color contrast tooling** — Xcode's Accessibility Inspector has a built-in contrast checker and an Audit mode. Run the Audit over every top-level view in both Light and Dark; any failures are addressed by reaching for a different system semantic color, not by introducing runtime adjustment.

## MAS notes

- No permission or entitlement needed for accessibility features. All handled via standard SwiftUI + AppKit.
- Apple favors apps with strong accessibility in featuring and search ranking. Bonus motivation.

## Open questions

- **Switch Control** — macOS Switch Control (accessibility input method) works with any keyboard-navigable app. Automatic once keyboard nav is solid.
- **Voice Control** — same as Switch Control; automatic once every element has an accessibility label.
- **Spoken UI for captures** — "New clip captured from Safari" voice notification. Nice; out of v1.
- **Subtitle for tray icon** — not a thing on macOS. Skip.
