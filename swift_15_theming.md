# swift_15 — Appearance (system default only)

## Purpose

Clipz uses the **macOS system appearance** as its single source of truth for colors. There is no in-app theme picker, no light/dark toggle, no custom palette, and no WCAG contrast enforcement layer. This file exists to document that decision and pin the tray icon strategy.

The old 2-theme palette system (`light-plus`, `gruvbox-dark`) and the iterative contrast adjuster (`ensureAAContrast`) from the Electron app are **not** ported.

## The rule

- Every SwiftUI view uses semantic colors that auto-invert for Light/Dark:
  - Foreground: `.primary`, `.secondary`, `.tertiary`, `.accentColor`
  - System-derived: `Color(nsColor: .textColor)`, `Color(nsColor: .windowBackgroundColor)`, `Color(nsColor: .controlBackgroundColor)`, `Color(nsColor: .separatorColor)`
  - Tint colors from asset catalogue are defined with "Any" + "Dark" variants
- Window chrome and sidebars use **system materials**, not fills: `.regularMaterial`, `.thinMaterial`, `.ultraThinMaterial`, `.hudWindow`
- Never hardcode hex colors for anything the user will see. Reviewer rule: a hex literal in a view file is a bug.
- Apple guarantees HIG-conforming components meet WCAG AAA under both Light and Dark. No runtime contrast adjustment is required — see swift_23 for the verification checklist.

Users change Light/Dark by going to **System Settings → Appearance**. The app follows automatically via SwiftUI's environment.

## Tray icon

Single template image; macOS auto-tints for menubar appearance.

```swift
// Packages/ClipzUI/Sources/ClipzUI/Theming/TrayIconProvider.swift
import AppKit

public enum TrayIconProvider {
    public static var image: NSImage {
        let img = NSImage(named: "TrayIconTemplate")
            ?? NSImage(systemSymbolName: "doc.on.clipboard",
                       accessibilityDescription: "Clipz")!
        img.isTemplate = true
        return img
    }
}
```

`TrayIconTemplate` is a single black-on-transparent PNG in the asset catalogue. `isTemplate = true` makes macOS:
- Draw it black on a light menubar
- Draw it white on a dark menubar
- Invert it on press / selection
- Switch to solid fill when "Reduce Transparency" is enabled

No per-theme tray icons, no `getTrayIconPath(themeKey)` equivalent.

## What was removed from the earlier draft

Files and types deleted from the Swift package (anything previously listed in `Packages/ClipzUI/Sources/ClipzUI/Theming/`):

- `Theme.swift` / `Themes.swift` — no theme registry
- `ThemeStore.swift` — no observable theme object
- `ColorResolver.swift` — no hex-to-Color helper
- `ContrastEnforcer.swift` — no runtime adjustment; covered by Apple's system colors
- `ThemeBroadcast.swift` — no `themeDidChange` notification
- `ThemePreview.swift` — no preview UI
- `.themed(_:)` view modifier — deleted
- `Theme.Palette`, `Theme.Appearance` enums — deleted

The `Theming/` directory still exists but contains only `TrayIconProvider.swift`.

## Migration carry-over

The Electron user's `theme` and `themeMode` settings are **not** imported (swift_25). They fall through to system appearance on first launch of the Swift app.

## MAS notes

- SwiftUI semantic colors, NSVisualEffectView materials, and `isTemplate` images are all sandbox-compatible with no entitlement implications.

## Open questions

- **High-contrast mode** — macOS's "Increase contrast" accessibility setting already bumps system colors. Our semantic-color usage inherits the boost for free. No app work needed. Verify during a11y audit.
- **Future custom themes** — not returning. If users ask, direct them to macOS Appearance and accent-color settings.
