// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`.
/// This path needs **no Accessibility permission** and is App-Sandbox-safe
/// (unlike an `NSEvent` global monitor), so the shortcut works the moment
/// the app launches. Pressing it runs `onPressed` on the main actor — wired
/// to open the tray quick-paste popup.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPressed: () -> Void

    /// The Carbon C callback can't capture Swift context, so it routes
    /// through this single instance (the app has exactly one global hotkey).
    nonisolated(unsafe) private static weak var current: GlobalHotkey?

    /// FourCC 'CLZH' — our hotkey signature.
    private static let signature: OSType = 0x434C5A48

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    /// (Re)register for the given AppKit key code + `NSEvent` modifier
    /// flags. A no-op when disabled or when the combo has no modifiers
    /// (a bare key would hijack that key globally).
    func update(enabled: Bool, keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        unregister()
        guard enabled else { return }
        let carbonMods = Self.carbonModifiers(modifierFlags)
        guard carbonMods != 0, keyCode >= 0 else { return }

        Self.current = self
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr { hotKeyRef = ref }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                // Carbon dispatches on the main thread; hop through
                // DispatchQueue.main so we satisfy actor isolation, then
                // invoke the stored callback.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotkey.current?.onPressed() }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    // MARK: - Conversions

    /// `NSEvent.ModifierFlags` → Carbon modifier mask for `RegisterEventHotKey`.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

/// Human-readable rendering of a stored hotkey (e.g. "⌘⇧V").
enum HotkeyFormatter {
    static func string(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option)  { out += "⌥" }
        if modifiers.contains(.shift)   { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += keyLabel(keyCode)
        return out
    }

    /// Minimal key-code → label table covering the keys users are likely
    /// to bind. Falls back to a numeric code for anything exotic.
    static func keyLabel(_ code: Int) -> String {
        switch code {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"; case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"; case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"; case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"; case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"; case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"; case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        default: return "Key \(code)"
        }
    }
}
