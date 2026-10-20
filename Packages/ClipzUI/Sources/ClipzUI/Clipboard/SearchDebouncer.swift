// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

/// Small @Observable wrapper that coalesces a rapidly-typed search
/// string into a single fired query after 180ms of silence. Used by
/// `ClipboardView` so SearchEngine isn't hit on every keystroke.
@Observable @MainActor
final class SearchDebouncer {
    var query: String = "" {
        didSet { schedule() }
    }

    private var task: Task<Void, Never>?
    private let interval: Duration
    private let onFire: @MainActor (String) -> Void

    init(
        interval: Duration = .milliseconds(180),
        onFire: @escaping @MainActor (String) -> Void
    ) {
        self.interval = interval
        self.onFire = onFire
    }

    private func schedule() {
        task?.cancel()
        let current = query
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.interval)
            guard !Task.isCancelled else { return }
            self.onFire(current)
        }
    }
}
