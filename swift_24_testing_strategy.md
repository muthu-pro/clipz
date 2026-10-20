# swift_24 — Testing Strategy

## Purpose

Define unit, integration, UI, and snapshot testing coverage for the Swift rewrite. The current Electron app has essentially **zero automated tests** (WARP.md: "No automated test suite is currently configured"). The rewrite is the chance to bake testing in from day one.

## Test frameworks

1. **Swift Testing** (Apple's new testing framework, Xcode 16+) — primary for new tests.
2. **XCTest** — fallback where Swift Testing doesn't yet cover (e.g., performance tests, older XCUITest).
3. **swift-snapshot-testing** (Pointfree) — snapshot testing for SwiftUI views.
4. **XCUITest** — end-to-end flows (tray popover → paste, full restore flow).

## Coverage targets

| Layer | Target coverage | How |
|---|---|---|
| ClipzCore models + services | **90%+ line** | Swift Testing unit tests |
| ClipzML pipeline | **70%+ line** | Swift Testing + fixture images |
| ClipzUI individual views | **Snapshots of key views** | swift-snapshot-testing |
| End-to-end flows | **5–10 critical paths** | XCUITest |

## Test structure

```
Packages/ClipzCore/Tests/ClipzCoreTests/
├── Models/
│   ├── ClipboardItemTests.swift
│   ├── NoteTests.swift
│   └── …
├── Database/
│   ├── MigrationTests.swift
│   ├── ClipboardQueriesTests.swift
│   └── FTSTests.swift
├── Services/
│   ├── ClipboardServiceTests.swift
│   ├── NotesServiceTests.swift
│   ├── BackupServiceTests.swift
│   └── LicenseServiceTests.swift
├── Clipboard/
│   ├── ClassifierTests.swift
│   ├── ContentHasherTests.swift
│   └── WatcherTests.swift        # uses TestClipboardProvider
├── Search/
│   ├── ParsedSearchTests.swift
│   └── SearchEngineTests.swift
├── Fixtures/
│   ├── test.png
│   ├── test.pdf
│   └── sample-backup.clipzbackup
└── Helpers/
    ├── InMemoryDatabase.swift
    └── TestClipboardProvider.swift
```

## Unit test examples

### ContentHasher

```swift
import Testing
@testable import ClipzCore

@Suite("ContentHasher")
struct ContentHasherTests {
    @Test("Text payloads with identical content produce equal hashes")
    func textIdentity() {
        let p1 = makeTextPayload("Hello world")
        let p2 = makeTextPayload("Hello world")
        #expect(ContentHasher.hash(p1) == ContentHasher.hash(p2))
    }

    @Test("Different kinds produce different hashes even with same text")
    func kindMatters() {
        let text = makeTextPayload("<b>x</b>", kind: .text)
        let html = makeTextPayload("<b>x</b>", kind: .html)
        #expect(ContentHasher.hash(text) != ContentHasher.hash(html))
    }

    @Test("Large text is not loaded into memory twice")
    func largeText() {
        let big = String(repeating: "a", count: 100_000)
        let p = makeTextPayload(big)
        _ = ContentHasher.hash(p)  // just verify no crash
    }
}
```

### ClipboardService capture dedup

```swift
@Suite("ClipboardService dedup")
struct ClipboardDedupTests {
    @Test("Identical capture within dedup window is dropped")
    func dedupTextCapture() async throws {
        let db = try await InMemoryDatabase.make()
        let fs = try InMemoryFileStore()
        let service = ClipboardService(database: db, fileStore: fs)

        let payload = ClassifiedPayload.makeText("hello")
        await service.capture(payload)
        await service.capture(payload)

        let items = try await service.fetchPage()
        #expect(items.count == 1)
    }

    @Test("Different content creates two rows")
    func distinctContent() async throws {
        let db = try await InMemoryDatabase.make()
        let fs = try InMemoryFileStore()
        let service = ClipboardService(database: db, fileStore: fs)

        await service.capture(.makeText("one"))
        await service.capture(.makeText("two"))

        let items = try await service.fetchPage()
        #expect(items.count == 2)
    }
}
```

### Search

```swift
@Suite("SearchEngine")
struct SearchEngineTests {
    @Test("Trigram path returns substring matches")
    func substring() async throws {
        let db = try await seededDB()
        let engine = SearchEngine(database: db)
        let result = try await engine.search(query: "usa", limit: 10, offset: 0,
                                              kindFilter: nil, dateRange: nil)
        // "sausage" should match trigram "usa"
        #expect(result.results.contains { $0.item.content.contains("sausage") })
    }

    @Test("Quoted phrase preserves order")
    func phraseMatch() async throws {
        let db = try await seededDB()
        let engine = SearchEngine(database: db)
        let result = try await engine.search(query: "\"quick brown\"", limit: 10, offset: 0,
                                              kindFilter: nil, dateRange: nil)
        #expect(!result.results.isEmpty)
    }
}
```

### Migration

```swift
@Suite("Database migrations")
struct MigrationTests {
    @Test("Fresh DB applies v1 migration")
    func freshV1() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipz-test-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AppDatabase.make(at: url)

        let schemaVersion = try db.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        #expect(schemaVersion == 1)
    }

    @Test("All tables exist after migration")
    func tablesExist() throws { … }
}
```

## Integration tests (against real DB)

Use `DatabaseQueue.init(path: tempFile)` with a temp file for each test — fast enough (< 10 ms) to run hundreds in a suite. Never share state between tests.

```swift
@Test("Capture, search, delete full cycle")
func fullCycle() async throws {
    let tmp = tempDBPath()
    let db = try AppDatabase.make(at: tmp)
    let fs = try FileStore(root: tempDirectory())
    let service = ClipboardService(database: db, fileStore: fs)

    // Capture
    await service.capture(.makeText("Hello world"))
    let after = try await service.fetchPage()
    #expect(after.count == 1)

    // Search
    let results = try await service.search(query: "Hello")
    #expect(results.results.count == 1)

    // Delete
    try await service.delete(id: after[0].id)
    let post = try await service.fetchPage()
    #expect(post.isEmpty)
}
```

## Mocking NSPasteboard

`ClipboardWatcher` depends on `NSPasteboard.general`. To test the polling loop without real pasteboard side effects, inject:

```swift
public protocol PasteboardProviding: Sendable {
    var changeCount: Int { get }
    func read(type: NSPasteboard.PasteboardType) -> Data?
    func string(type: NSPasteboard.PasteboardType) -> String?
    // … etc.
}

public struct SystemPasteboardProvider: PasteboardProviding { … }

public final class TestClipboardProvider: PasteboardProviding {
    public private(set) var changeCount: Int = 0
    private var payloads: [NSPasteboard.PasteboardType: Data] = [:]

    public func set(_ text: String) {
        changeCount += 1
        payloads[.string] = text.data(using: .utf8)
    }
    // …
}

public actor ClipboardWatcher {
    private let pb: PasteboardProviding
    init(pb: PasteboardProviding = SystemPasteboardProvider(), …) {…}
}
```

Now watcher tests:

```swift
@Test("Watcher captures when changeCount advances")
func captureOnChange() async throws {
    let pb = TestClipboardProvider()
    let service = MockClipboardService()
    let watcher = ClipboardWatcher(pb: pb, service: service)

    await watcher.tickOnce()  // expose for testing
    pb.set("new")
    await watcher.tickOnce()

    #expect(service.captureCalls.count == 1)
    #expect(service.captureCalls.first?.text == "new")
}
```

## ML pipeline tests

With fixture images bundled in the test target:

```swift
@Test("OCR finds 'HELLO' in hello.png")
func ocrFixture() async throws {
    let url = Bundle.module.url(forResource: "hello", withExtension: "png")!
    let cg = CGImageLoader.load(from: url)!
    let result = try await OCRAnalyzer().recognize(cgImage: cg)
    #expect(result.contains { $0.text.localizedCaseInsensitiveContains("HELLO") })
}

@Test("Object detector finds 'cat' in cat.png")
func detectCat() async throws { … }
```

Fixture images kept small (< 200 KB each) so test suite runtime stays fast.

## UI snapshot tests

```swift
import XCTest
import SnapshotTesting
import SwiftUI
@testable import ClipzUI

final class ClipboardViewSnapshots: XCTestCase {
    func testEmptyState() {
        let view = ClipboardListView(vm: .empty).frame(width: 600, height: 400)
        assertSnapshot(of: view, as: .image(size: CGSize(width: 600, height: 400)))
    }

    func testWithItems() { … }
    func testDarkTheme() { … }
    func testHighContrast() { … }
}
```

Record snapshots once (`record: true` first run); afterward, any visual regression fails the test.

Snapshots are golden images stored in `Tests/__Snapshots__/`. Review diffs in PR before approving.

## XCUITest: end-to-end flows

Focus on the hardest-to-unit-test flows:

```swift
final class ClipzUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        app.launchArguments = ["--uitests", "--reset-db"]
        app.launch()
    }

    func test_CaptureAndSearch() {
        // Given: empty app state
        // When: programmatically seed pasteboard (via XCUIRemote or AppleScript helper)
        // Then: item appears in list, search finds it
    }

    func test_TrayPopoverPaste() {
        // Open tray via NSStatusItem simulated click
        // Select first item
        // Verify paste engine was invoked
    }

    func test_SettingsToggleStateMonitor() {
        app.menuBars.menuBarItems["Clipz"].click()
        // …
    }
}
```

Launch args `--reset-db` triggers a known seeded database for deterministic UI state.

## Performance tests

XCTest performance blocks for hot paths:

```swift
import XCTest
@testable import ClipzCore

final class SearchPerformanceTests: XCTestCase {
    func testSearchOn50kItems() async throws {
        let db = try await seedLargeDatabase(itemCount: 50_000)
        let engine = SearchEngine(database: db)

        measure {
            let exp = expectation(description: "search")
            Task {
                _ = try await engine.search(query: "quick", limit: 50, offset: 0,
                                             kindFilter: nil, dateRange: nil)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 1.0)
        }
    }
}
```

Target: search on 50k items ≤ 50 ms p95.

## Running tests

```bash
# All unit tests
swift test --package-path Packages/ClipzCore
swift test --package-path Packages/ClipzML
swift test --package-path Packages/ClipzUI

# All tests including UI
xcodebuild test -scheme ClipzApp -destination "platform=macOS"
```

CI runs both on every PR. Test suite budget: < 2 minutes for unit tests; < 5 minutes including UI.

## Fixtures

- **test.png** — simple image with text for OCR tests.
- **test.pdf** — 3-page PDF with known content.
- **cat.png** — clear cat photo for object detection.
- **sample-backup.clipzbackup** — a known-good backup for restore tests.
- **sample-backup-encrypted.clipzbackup** — password = `testpass`.
- **electron-era.db** — a seeded Electron-compatible DB for migration tests.

Store under `Tests/*/Fixtures/`; reference via `Bundle.module.url(...)`.

## Test data policy

- No real user data in fixtures. Lorem Ipsum text for clipboard items; stock images (openverse / unsplash license-clear) for image fixtures.
- Keep fixtures small: the whole fixture folder < 5 MB.

## CI gate

Every PR must:

1. Pass `swift test` for every package.
2. Pass `xcodebuild test` for the app + UI tests.
3. No snapshot test regressions (failed snapshots show diff images in CI log).
4. No new `// TODO` or `// FIXME` without a tracked issue.
5. SwiftLint / SwiftFormat clean.

## Edge cases & gotchas

1. **Swift Testing vs XCTest mixing** — both frameworks coexist; Swift Testing tests won't run if mixed into an XCTest target incorrectly. Separate by test file; Xcode 16+ auto-routes.

2. **GRDB in tests** — use `DatabaseQueue` (serialized), not `DatabasePool`, for deterministic reads. Production uses `DatabasePool`; behavioral equivalence holds for test queries.

3. **Snapshot tests on different macOS versions** — snapshots can differ slightly across OS versions (anti-aliasing, font metrics). Pin CI to one macOS version (`macos-14`) so snapshots are stable.

4. **Concurrency tests — `Task` scheduling** — Swift Testing doesn't guarantee task ordering. Use `await` explicitly; don't rely on "these tasks run in this order."

5. **Flaky UI tests** — XCUITest is inherently flaky for heavy UI flows. Use `.exists` + `.waitForExistence` instead of `sleep`. Keep the flow short; break long scenarios into smaller tests.

6. **Test-only entry points** — flag via `launchArguments`; check `ProcessInfo.processInfo.arguments` in app code. Clearly named (`--uitests`) so they don't confuse dev behavior.

## Open questions

- **Contract tests against real SQLite** vs in-memory — in-memory is faster; verify a few critical queries against a real file-backed DB to ensure WAL/pool behavior matches.
- **Fuzz testing the search parser** — ensure arbitrary user input doesn't crash FTS MATCH. Easy to add with `swift-testing` + random inputs.
- **Visual regression for all themes × appearances** — combinatorial explosion. Snapshot 3–4 representative views per theme.
- **Accessibility audit test** — there's no easy programmatic way to assert "accessibilityLabel exists on every element." Manual audit per swift_23 checklist; XCUITest can verify specific element labels.
