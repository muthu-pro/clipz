# swift_22 — Performance and Caching

## Purpose

Consolidate the performance lessons distilled in the current repo's decision docs (`FREEZE_FIX_COMPLETE.md`, `PERFORMANCE_ANALYSIS_muthu.md`, `PERFORMANCE_OPTIMIZATION_PLAN.md`, `PERFORMANCE_TRACKING_SUMMARY.md`, `ENERGY_OPTIMIZATION_PLAN.md`, `SEARCH_PERFORMANCE_ANALYSIS.md`) and translate them into Swift-appropriate patterns. Cover queueing, threading, lazy loading, and what to do with the renderer-side IndexedDB cache (spoiler: delete it).

## Lessons from the Electron repo

### FREEZE_FIX_COMPLETE.md — screenshot capture optimization

Key findings from the existing notes:

- Screenshot capture on the main Electron process was blocking the UI for ~1.4 s per capture due to synchronous AppleScript calls.
- Fixed by conditionally running AppleScript only when file paths are detected.
- Optimized to ~120 ms per capture (~12× improvement).

**Swift equivalent**:

- NSPasteboard reads are native and fast (microseconds).
- We drop AppleScript entirely — `readObjects(forClasses: [NSURL.self])` replaces it.
- **No equivalent freeze risk** in the Swift capture path. The watcher (swift_03) runs on a utility-priority detached task; even worst-case image decode on 4K screenshots happens off the main thread.

### PERFORMANCE_ANALYSIS_muthu.md + PERFORMANCE_OPTIMIZATION_PLAN.md

Identifies:

- React re-render storms when receiving clipboard-item-added events for many items in rapid succession.
- Mitigated by batching updates (debounce) and using React's `useMemo` aggressively.

**Swift equivalent**:

- SwiftUI with `@Observable` has implicit batching — state changes within the same run loop coalesce.
- List rendering is already lazy.
- Apply debounced event coalescing in the view model if bursts of > 20 captures/s cause stutter (unlikely but measurable).

### SEARCH_PERFORMANCE_ANALYSIS.md

- Complaints: search slow on large histories.
- Fix: trigram tokenizer, result pagination.

**Swift equivalent**: already baked into swift_05 (trigram + porter), swift_08 (ranked BM25 with 200-result cap), swift_12 (debounced search input).

### ENERGY_OPTIMIZATION_PLAN.md

- Reduce CPU wake-ups; don't poll when idle.
- Respect power state.

**Swift equivalent**:

- Watcher pauses on `NSWorkspace.willSleepNotification` (swift_03).
- Analysis pipeline checks `ProcessInfo.thermalState` (swift_09).
- Timer-based polling uses `Task.sleep` with utility QoS, not a wall-clock `Timer`.

## Swift performance principles

### 1. Don't block the main actor

Main actor = UI thread. Anything beyond "show this" runs off the main actor:

```swift
// Wrong
@MainActor
func captureAndSave(payload: ClassifiedPayload) {
    let hash = ContentHasher.hash(payload)     // synchronous CPU
    try? database.write(...)                    // I/O
    updateUI()
}

// Right
@MainActor
func handleCapture(payload: ClassifiedPayload) {
    Task.detached(priority: .utility) {
        await self.service.capture(payload)
        await MainActor.run { self.refreshList() }
    }
}
```

All service actor methods are naturally off the main actor.

### 2. Use actors for serialized state, not classes with locks

The `ClipboardService`, `SettingsStore`, `AnalysisService`, `EventBroadcaster` are all actors. No manual locking, no queue management. Concurrency is obvious in the code.

### 3. Prefer async/await + AsyncStream over callbacks

Makes back-pressure and cancellation explicit:

```swift
// Backup progress
for try await step in backupService.create(to: dest, password: pw) {
    updateProgress(step)
}
```

### 4. GRDB best practices

- Prepared statements auto-cached; don't rebuild.
- Read in `dbPool.read { }`; write in `dbPool.write { }`. Mixing leads to deadlocks.
- Use `fetchCursor` for streaming large result sets (rare in our case).
- Wrap bulk inserts in a single transaction via `db.inTransaction { }`.

### 5. Don't ship a renderer-side cache

The current Electron app has `src/services/clipboard.ts` (QueryCache) + IndexedDB persistence to paper over IPC latency. **Delete the concept in Swift.**

- In-process SQLite: query latency is 1–5 ms for a 50-item page with FTS filter on an M1 laptop. No cache needed.
- The only cache worth keeping is **AppIconCache** (swift_16), because `NSWorkspace.shared.icon(forFile:)` hits the file system per call and we render many cells per second while scrolling.

### 6. Media loading

- `AsyncImage(url:)` handles lazy load + failure state out of the box. Don't roll your own.
- For thumbnails, pre-generate and store on disk (swift_16). Don't decode the full-resolution image at list time.

### 7. AttributedString snippet rendering

- Parsing snippets (swift_08) happens once per visible row; ~O(chars in snippet). Negligible.
- If profiling shows this as hot (unlikely for < 200 visible rows), memoize via a per-ID cache on the view model.

## Caching map (what we explicitly cache vs don't)

| Layer | Cache? | Why |
|---|---|---|
| SQLite queries (fetch page, search) | **No** | Fast enough in-process |
| Item → rendered cell | **Yes, via SwiftUI** | Implicit |
| AppIcon by bundle ID | **Yes** (`AppIconCache`) | File system hits are expensive |
| PDF thumbnails | **Yes** (on disk) | Regenerating is expensive |
| Vision request handlers | **No** — cheap to create per-call | Vision's internal model caching handles hot paths |
| FTS results | **No** | Already fast; staleness risk |
| Source app list | **Partial** — cached in view model for 60s | Rarely changes |
| Analysis results (OCR/detections per item) | **No in-memory** — DB-backed, GRDB's prepared statements are fast | |

## Energy optimization

### Respect power / thermal state

```swift
extension ProcessInfo {
    var shouldPauseAnalysis: Bool {
        isLowPowerModeEnabled || thermalState == .critical
    }
}

// In AnalysisService.runLoop:
while !Task.isCancelled {
    if ProcessInfo.processInfo.shouldPauseAnalysis {
        try? await Task.sleep(for: .seconds(5))
        continue
    }
    // …
}
```

### Sleep/wake handling

Watcher pauses on `NSWorkspace.willSleepNotification`, resumes on `didWakeNotification`. On wake, reset `lastChangeCount` to current so we don't process accumulated events at once.

### Fast user switching

`NSWorkspace.sessionDidResignActiveNotification` pauses the watcher; `sessionDidBecomeActiveNotification` resumes. Prevents capturing another user's clipboard.

### Mechanisms we avoid

- **NSTimer at sub-second intervals** — drains battery. Our polling uses `Task.sleep(for: .milliseconds(250))`, which doesn't schedule a wake.
- **FSEvents at 1 Hz latency** — already event-driven; fires only on change.

## Startup time target

- Cold launch to main window visible: ≤ 500 ms on M1.
- Key contributors:
  - Vision requests — no cold-load cost to defer; first call warms the shared system framework.
  - Database schema migration — runs once on first launch; a few ms on each subsequent.
  - Settings load — one DB query; a few ms.
  - First list fetch — 50 items, ~2 ms.

### Deferred work

Apple Vision has no cold-load model cost for us to defer — the system loads shared ML models on first use. We still defer:

- `SynonymsSeeder` JSON load — parse on first use, not at startup.
- `AnalysisService.start()` — invoked after `AppContainer.bootstrap()` has completed, not in `applicationDidFinishLaunching` synchronously.
- `AnimalDetector`, `ImageClassifier`, etc. — stateless structs; instantiate per-call with no cost.

## Memory budget

Target steady-state memory under load (10k items, 100 rendered):

- SQLite: ~30 MB (statement cache, cached pages)
- AsyncImage decoded images: ~50 MB (peak during scroll bursts)
- Apple Vision requests (transient, per-call): ~30 MB peak during inference, released after
- Swift heap: ~40 MB
- **Total p95**: ~150 MB

No bundled ML model means no persistent model-memory budget. Vision loads its own shared models into kernel-shared memory pages; they don't count against our process's RSS meaningfully.

## Benchmarks (targets)

From the existing repo's tracking docs, the current Electron app achieves (post-optimization):

- Screenshot capture: ~120 ms
- Clipboard item save: ~20 ms (text), ~50 ms (image 2MP), ~200 ms (PDF + thumbnail)
- Search: ~50 ms for trigram, ~100 ms for porter on 50k items
- Page fetch: ~5 ms

Swift targets (match or beat):

- Screenshot capture (event to saved row): **≤ 100 ms**
- Clipboard capture: **≤ 40 ms text, ≤ 80 ms image**
- Search: **≤ 50 ms p95 on 50k items**
- Page fetch: **≤ 5 ms**
- Analysis (image, OCR + object detection + barcode, 2MP): **≤ 800 ms** on M1
- App launch to window visible: **≤ 500 ms**

Measure with `signpost` + Instruments during dev; bake a few benchmark tests (swift_24).

## Profiling workflow

1. **Instruments** — Allocations + Time Profiler templates for SwiftUI.
2. **SwiftUI tracing** — use `_printChanges()` to debug unexpected re-renders.
3. **os_log signposts** — mark phases (capture begin/end, search begin/end) so they show up in Instruments timeline.
4. **MetricKit** — production perf signals (launch time, hang duration, disk writes).

## Anti-patterns to avoid

1. **Synchronous file I/O on the main actor** — never. Always `await` async variants or hop off.
2. **`DispatchQueue.main.async` from a service** — prefer `await MainActor.run { }`.
3. **Observing DB table changes via timer-based re-fetch** — use GRDB's `ValueObservation` for live queries where needed (note list updates when a new note is created).
4. **Rendering 10,000 items in a non-lazy `VStack`** — use `List` or `LazyVStack`.
5. **Hashing huge video bytes on capture** — hash by filename + size + mtime (swift_03). Don't read entire files into memory.
6. **Persisting large derived state** (like thumbnail image data in a DB column) — store on disk with a filename ref.

## Edge cases & gotchas

1. **Burst of 50+ captures/s** (e.g., user holds down a macro) — actor serialization means they process sequentially; no queue overflow, but user sees items appear at ~30 Hz in the list. Acceptable.

2. **Huge clipboard content** (e.g., copy a 50 MB text blob) — `NSPasteboard.general.string(forType: .string)` copies bytes into memory. Check size first via `pb.data(forType: .string)?.count` and drop if > 100 MB.

3. **Database corruption recovery** — GRDB throws on corruption; catch, move corrupt DB aside, create fresh, prompt user to restore from backup.

4. **WAL file growth** — `PRAGMA journal_size_limit = 10485760` caps at 10 MB. Checkpoint periodically (`PRAGMA wal_checkpoint(TRUNCATE)`).

5. **Scroll stutter during capture burst** — if users report it, add capture-aware debouncing: coalesce `captured` events into one `refresh` event per 200ms window.

6. **Slow disk (spinning) users** — rare on modern Macs, but possible with external drives. Cap media file size for import; warn on > 1 GB.

## Open questions

- **GRDB migration of data types** — does GRDB's `TRACE_SLOW_STATEMENTS` macro need enabling in debug? Probably yes; gives visibility into slow queries during dev.
- **Concurrent object detection** — should we run 2 items in parallel on M1 Pro/Max (more Neural Engine cores)? Test with 1/2/4 concurrency levels; tune per-SKU.
- **Progressive search rendering** — stream search results into the UI as they come back rather than waiting for the full result set. Small win; defer.
- **Preheat the search index** — run a dummy FTS query at app launch to warm caches? Probably unnecessary; measure before adding.
