// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click-to-record control for a keyboard shortcut. Shows the current
/// combo; clicking it listens for the next key-with-modifiers and reports
/// it via `onRecorded`. Esc cancels, and a combo with no modifier is
/// rejected (a bare global key would hijack that key everywhere).
struct HotkeyRecorderView: View {
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags
    let onRecorded: (Int, NSEvent.ModifierFlags) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording
                 ? "Press shortcut…  (Esc to cancel)"
                 : HotkeyFormatter.string(keyCode: keyCode, modifiers: modifiers))
                .font(.body.weight(.medium))
                .frame(minWidth: 150)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Esc with no modifiers cancels.
            if Int(event.keyCode) == kVK_Escape, mods.isEmpty {
                stop()
                return nil
            }
            // Require at least one modifier; ignore bare keys but stay armed.
            guard !mods.isEmpty else { return nil }

            onRecorded(Int(event.keyCode), mods)
            stop()
            return nil  // swallow so the keystroke doesn't leak elsewhere
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }
}
