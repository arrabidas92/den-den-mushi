# architecture.md

Architecture and technical decisions for the BeReal Stories test.

## Architectural pattern

**MVVM + Repository, modular by feature.** No Clean Architecture full-blown, no TCA.

Rationale:
- TCA in a 3-day test is risky. It's powerful but introduces concepts (reducers, effects, dependencies) that you must explain in review. If you can't justify every line, it hurts more than it helps.
- Clean Architecture (use cases, entities, interactors) is overkill at this scope and slows you down.
- MVVM with `@Observable` is the modern SwiftUI standard, well-understood, and lets you focus on UX polish and tests.

## Folder structure

```
StoriesTest/
├── App/
│   └── StoriesTestApp.swift              // entry, composition root
│
├── Features/
│   ├── StoryList/
│   │   ├── StoryListView.swift
│   │   └── StoryListViewModel.swift
│   │
│   └── StoryViewer/
│       ├── StoryViewerView.swift
│       ├── ViewerStateModel.swift          // which user/item, seen, like, dismiss
│       ├── PlaybackController.swift        // timer, progress, pause/resume
│       └── Components/
│           ├── StoryViewerPage.swift
│           ├── StoryViewerHeader.swift
│           └── StoryViewerFooter.swift
│
├── Domain/
│   ├── Models/
│   │   ├── User.swift
│   │   ├── Story.swift
│   │   ├── StoryItem.swift
│   │   └── UserState.swift
│   └── Repositories/
│       ├── StoryRepository.swift         // protocol
│       └── UserStateRepository.swift     // protocol
│
├── Data/
│   ├── LocalStoryRepository.swift        // actor, JSON + pagination
│   ├── PersistedUserStateStore.swift     // actor, FileManager + debounce
│   ├── EphemeralUserStateStore.swift     // actor, in-memory fallback (prod-safe)
│   ├── ImageLoader.swift                 // Nuke pipeline configuration
│   ├── ImagePrefetchHandle.swift         // screen-scoped prefetch lifetime
│   └── Resources/
│       └── stories.json
│
├── DesignSystem/
│   ├── Tokens/
│   │   ├── Colors.swift
│   │   ├── Typography.swift
│   │   └── Spacing.swift
│   └── Components/
│       ├── StoryRing.swift
│       ├── StoryAvatar.swift
│       ├── StoryTrayItem.swift           // composes StoryAvatar + label
│       ├── SegmentedProgressBar.swift
│       └── LikeButton.swift
│
└── Core/
    ├── Extensions/
    └── Haptics.swift

StoriesTestTests/
├── Unit/
│   ├── PersistedUserStateStoreTests.swift
│   ├── LocalStoryRepositoryTests.swift
│   ├── StoryListViewModelTests.swift
│   ├── PlaybackControllerTests.swift
│   └── ViewerStateModelTests.swift
├── Snapshot/
│   ├── StoryRingSnapshotTests.swift
│   ├── StoryAvatarSnapshotTests.swift
│   ├── SegmentedProgressBarSnapshotTests.swift
│   ├── LikeButtonSnapshotTests.swift
│   ├── StoryTrayItemSnapshotTests.swift
│   ├── StoryViewerHeaderSnapshotTests.swift
│   ├── StoryViewerPageSnapshotTests.swift
│   ├── StoryListViewSnapshotTests.swift
│   └── __Snapshots__/                    // generated PNGs
├── Integration/
│   └── StoryFlowIntegrationTests.swift
└── TestSupport/
    ├── FakeStoryRepository.swift
    └── InMemoryUserStateStore.swift
```

## Layer responsibilities

### App
Composition root. Builds repositories, stores, ImageLoader. Injects them into the root ViewModel. Configures Nuke once.

### Domain
Pure data and protocols. Zero imports beyond Foundation. No SwiftUI, no Nuke. This is what makes the codebase testable and portable.

### Features
MVVM per feature. View consumes a `@Observable` ViewModel via `@Bindable`. ViewModel is `@MainActor`. ViewModel calls into protocols (StoryRepository, UserStateRepository), never into concrete classes.

### Data
Concrete implementations. Each repository is an `actor` to provide thread-safety by language design rather than convention. Image loading is wrapped, not exposed directly.

### DesignSystem
No business logic. Tokens + reusable components. Independently previewable. Could be extracted to a Swift Package in a real project; not worth the friction in a test.

### Core
Cross-cutting helpers. Haptics, extensions. Keep small.

## Concurrency model

Swift 6 strict concurrency mode enabled. This is deliberate: it forces correctness at compile time and signals senior-level fluency.

```
Repositories          actor, protocols are Sendable
State stores          actor, protocols are Sendable
ViewModels            @MainActor (so `@Observable` properties drive SwiftUI on main)
Models                Sendable (struct + Codable + Hashable)
Image loader          Nuke pipeline configured at app start; prefetch handles are @MainActor
Tasks                 structured concurrency only; no DispatchQueue
Clock                 any Clock<Duration> injected — ContinuousClock in prod, TestClock in tests
Timer                 Task + clock.sleep, never Timer.scheduledTimer, never Task.sleep directly
```

Protocols crossing actor hops are explicitly `Sendable`:

```swift
protocol StoryRepository: Sendable {
    func loadPage(_ pageIndex: Int) async throws -> [Story]
}

protocol UserStateRepository: Sendable {
    func markSeen(itemID: String) async
    func toggleLike(itemID: String) async -> Bool
    func isSeen(_ id: String) async -> Bool
    func isLiked(_ id: String) async -> Bool
    func flushNow() async    // force-flush pending debounce; called on background/dismiss
}
```

ViewModel pattern — the viewer state is split into two collaborators rather than one fat `StoryViewerViewModel`. The split is along the natural fault line: time-driven progress on one side, user-driven navigation/state on the other. Each is testable in isolation; the View binds to both.

```swift
// PlaybackController — owns the timer and the 0...1 progress for the current item.
// Knows nothing about which item is current, who the user is, or how to dismiss.
@MainActor
@Observable
final class PlaybackController {
    private(set) var progress: Double = 0
    private(set) var isPaused = false

    var onItemEnd: (@MainActor () -> Void)?    // wired by ViewerStateModel

    private let clock: any Clock<Duration>
    private let itemDuration: Duration
    private let tickInterval: Duration = .milliseconds(50)   // 20 Hz: matches a smooth progress-bar update without burning CPU; 100 ticks per 5s item
    private var task: Task<Void, Never>?

    init(clock: any Clock<Duration> = ContinuousClock(), itemDuration: Duration = .seconds(5)) { ... }

    func start() { ... }   // resets progress, launches tick task
    func pause()  { isPaused = true }
    func resume() { isPaused = false }
    func reset()  { progress = 0 }   // called on item change
}
```

```swift
// ViewerStateModel — owns the navigation, seen, like, dismiss.
// Drives PlaybackController; reacts to its `onItemEnd` to advance.
@MainActor
@Observable
final class ViewerStateModel {
    private(set) var currentUserIndex: Int
    private(set) var currentItemIndex = 0
    private(set) var isLiked = false
    private(set) var shouldDismiss = false

    let playback: PlaybackController

    private let users: [Story]
    private let stateStore: any UserStateRepository
    private let clock: any Clock<Duration>
    private var seenMarkTask: Task<Void, Never>?

    init(
        users: [Story],
        startUserIndex: Int,
        stateStore: any UserStateRepository,
        clock: any Clock<Duration> = ContinuousClock(),
        playback: PlaybackController? = nil
    ) {
        // build playback if not injected; wire onItemEnd to nextItem()
    }

    func toggleLike()       { ... }       // optimistic update
    func nextItem()         { ... }       // explicit tap-forward also marks seen now
    func previousItem()     { ... }
    func nextUser()         { ... }
    func previousUser()     { ... }
    func dismiss()          { shouldDismiss = true }
    func onItemDidStart()   { ... }       // schedules seenMarkTask after 1.5s
}
```

The seen rule lives entirely in `ViewerStateModel`: on item start, it schedules a 1.5s task via the injected clock; if the item is still current after 1.5s OR if `nextItem()` fires first, it persists `markSeen`. Cancelling the task on item change drops the mark for items the user blew past in <1.5s without explicit forward.

`PlaybackController.task` is the timer. Cancel + restart on each transition. Always cancellation-aware (`try Task.checkCancellation()` between sleeps). Pause flips a flag the tick loop respects without cancelling the task — so resume picks up from the same offset without rebuilding state.

### Clock injection — why it matters

A `Task.sleep`-based timer is non-deterministic in tests: asserting "after 5s, currentItemIndex == 1" forces real-time waits, which makes the suite slow and flaky. Injecting `any Clock<Duration>`:

- Production: `ContinuousClock()` ticks in wall time.
- Tests: a `TestClock` (custom or `swift-clocks`-style) advances on demand. Tests assert "advance the clock by 5s, then expect index == 1" without any real sleep.

This unlocks the `PlaybackController` and `ViewerStateModel` test plans from CLAUDE.md (tick advance, pause/resume preserves progress, scenePhase pause halts and resumes from offset, seen marking honours the 1.5s floor, next/prev item, dismiss-on-end) as fast deterministic unit tests.

## Data flow

```
View
  ↑ observes
@Observable ViewModel  (@MainActor)
  ↓ calls
Repository protocols
  ↓ implements
actor LocalStoryRepository / PersistedUserStateStore
  ↓ uses
FileManager / Bundle / URLCache (via Nuke)
```

User actions:
1. View dispatches an intent (`viewModel.toggleLike()`).
2. ViewModel updates `@Observable` state immediately (optimistic).
3. ViewModel calls into the actor repository (`await store.toggleLike(itemID:)`).
4. Repository persists, eventually flushes to disk via debounce.

## Persistence design

`PersistedUserStateStore` is an actor with the following shape:

```swift
actor PersistedUserStateStore: UserStateRepository {
    private var state: UserState
    private let fileURL: URL
    private var pendingFlush: Task<Void, Never>?

    init(fileURL: URL) async throws {
        // load existing or create empty
    }

    func markSeen(itemID: String) {
        state.seenItemIDs.insert(itemID)
        scheduleFlush()
    }

    func toggleLike(itemID: String) -> Bool {
        let now = !state.likedItemIDs.contains(itemID)
        if now { state.likedItemIDs.insert(itemID) }
        else { state.likedItemIDs.remove(itemID) }
        scheduleFlush()
        return now
    }

    func isSeen(_ id: String) -> Bool { state.seenItemIDs.contains(id) }
    func isLiked(_ id: String) -> Bool { state.likedItemIDs.contains(id) }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        // Snapshot state at flush entry. Between the awaited Task.sleep and
        // here, mutations may have arrived; encoding `self.state` is fine
        // *because we are inside the actor*, but we must not yield (no await)
        // between the snapshot and the disk write to avoid writing a partial
        // mid-mutation state.
        let snapshot = state
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Logger.persistence.error("Flush failed: \(error)")
        }
    }
}
```

Re-entrance discipline:
- `flush` runs on the actor and never `await`s mid-write. The snapshot + atomic write happen within a single actor turn (`JSONEncoder().encode` and `Data.write(to:options:)` are both synchronous), so mutations queued during the flush wait their turn cleanly.
- `pendingFlush` captures `[weak self]` so a deallocated store does not keep its own task alive.
- **No `deinit` flush.** An `actor`'s `deinit` cannot reliably hop back onto its executor to read `state`, and `Task.detached` from `deinit` would race against deallocation. Instead, the View calls `await store.flushNow()` from `.onDisappear` of the root viewer when transitioning back to the list, and `ScenePhaseObserver` calls it on `.background`. The 500 ms debounce window is the documented worst case for state loss on a hard kill. This trade-off is in the *Persistence design* table and the README.

Why an actor:
- Multiple ViewModels read/write concurrently (list and viewer can both query/update).
- Race conditions on `Set<String>` are real and silent.
- An actor makes it impossible by construction.

Why JSON file (not SwiftData / UserDefaults):
- **UserDefaults**: ergonomic but no concurrency guarantees, awkward for collections, no atomic writes.
- **SwiftData**: heavy for `Set<String>`. Has unresolved threading bugs in iOS 17.x. Adds a model layer for no gain.
- **Codable JSON + actor**: precise, fast for our data size (<1KB), trivially testable with a temp directory, atomic via `Data.write(to:options: [.atomic])`.

Why debounce:
- A user opens the viewer, marks seen, scrolls 5 stories: 5 disk writes in 5 seconds is wasteful.
- 500ms debounce coalesces bursts. Trade-off: max 500ms of state loss on app kill. Acceptable.

## Pagination strategy

Spec says "infinite even if data repeats". `LocalStoryRepository`:

```swift
actor LocalStoryRepository: StoryRepository {
    private let baseStories: [Story]   // loaded from JSON once
    private let pageSize = 10

    func loadPage(_ pageIndex: Int) async throws -> [Story] {
        let n = baseStories.count
        guard n > 0 else { return [] }
        return (0..<pageSize).map { i in
            let base = baseStories[(pageIndex * pageSize + i) % n]
            return base.withPageSuffix(pageIndex)   // suffix story.id and item.ids
        }
    }
}
```

ID suffixing is critical: it ensures seen/liked state for `alice-p0` is distinct from `alice-p1`, otherwise marking page-1-Alice seen would mark page-2-Alice seen.

Edge cases the formula covers explicitly:
- `n == 7`, `pageSize == 10`, `pageIndex == 0` → indices `0,1,2,3,4,5,6,0,1,2`. The same user appears twice on page 0 but with the *same* page suffix `-p0`, so seen state is shared within the page (acceptable — repeats only become independent across pages).
- `pageIndex == 1` with `n == 7` → indices `3,4,5,6,0,1,2,3,4,5`, all suffixed `-p1`, fully independent from page 0.
- `n == 0` → empty page, ViewModel surfaces an empty-state instead of looping.

`Story.withPageSuffix(_:)` rewrites both `story.id` (`"alice"` → `"alice-p1"`) and every `StoryItem.id` (`"alice-1"` → `"alice-1-p1"`). Image URLs are *not* re-seeded — the same user must show the same images across pages (CLAUDE.md hard rule on stability).

ViewModel triggers `loadPage(currentPage + 1)` when `currentIndex >= count - 3`. Guard with an `isLoadingMore` flag to prevent double-loads. A failed page load surfaces a non-blocking error and leaves `isLoadingMore = false` so a future scroll retries (see *Error handling*).

## Image loading

`Nuke` is the only runtime dependency. Justification (for the README):

> Nuke handles HTTP image fetching, multi-tier caching (memory + disk), prefetching, and decompression. None of these are the core feature being evaluated. Implementing them by hand would consume time better spent on UX and tests, and would be lower quality than a battle-tested library used by major iOS apps. The alternative `AsyncImage` lacks disk cache, prefetching, and reliable cancellation, making it unfit for a production-grade Stories feature.

Wrapper:

```swift
enum ImageLoader {
    static func configure() {
        // Configure Nuke pipeline once at app start (memory cache size,
        // disk cache TTL, DataLoader timeouts).
    }
}

// Held by ViewModels for the lifetime of a screen; cancelled on deinit.
// Marked @MainActor because Nuke's ImagePrefetcher is @MainActor in Nuke 12+.
@MainActor
final class ImagePrefetchHandle {
    private let prefetcher = ImagePrefetcher()

    func prefetch(_ urls: [URL]) {
        prefetcher.startPrefetching(with: urls)
    }

    func cancel() {
        prefetcher.stopPrefetching()
    }

    deinit {
        // ImagePrefetcher's own deinit cancels in-flight prefetches; no extra
        // call needed here, and we cannot hop to MainActor from deinit anyway.
    }
}
```

Why `@MainActor` and not `Sendable`: Nuke 12 annotates `ImagePrefetcher` as `@MainActor`. Stamping `Sendable` on a wrapper that holds a `@MainActor`-isolated property would either require `@unchecked Sendable` (lying to the compiler) or break compilation under Swift 6. Confining the handle to `MainActor` is the honest choice — and ViewModels are already `@MainActor`, so calls into the handle don't cross actor hops.

Use Nuke's `LazyImage` SwiftUI view directly in the design components. The wrapper exists only to (1) centralize one-shot pipeline configuration and (2) own a prefetch handle whose lifetime is tied to a screen — both are real responsibilities, neither leaks Nuke types into the Domain.

URL strategy: `https://picsum.photos/seed/{stableSeed}/1080/1920` for story content, `/200/200` for avatars. The `seed` param guarantees stability — same URL → same image — which satisfies the spec's "user has the same content every time".

## Error handling & logging

Errors are typed at the domain boundary and never thrown blindly to the View.

```swift
enum StoryError: Error, Sendable {
    case bundleResourceMissing(name: String)
    case decodingFailed(underlying: Error)
    case persistenceUnavailable(underlying: Error)
    case pageOutOfRange
}
```

Strategy:
- **Repositories** throw `StoryError`. They never throw raw `DecodingError` or `CocoaError` to the upper layers.
- **ViewModels** catch and translate into displayable state: a `loadingError: String?` (or a small enum for retryable vs fatal) consumed by the View. ViewModels never re-throw to the View.
- **Views** render a discreet inline error (a 40pt red-tinted row at the bottom of the tray, or an X overlay in the viewer page) with a tap-to-retry. No alert dialogs — they break the immersive feel of Stories.

Logging uses `os.Logger`, one logger per subsystem:

```swift
private let subsystem = Bundle.main.bundleIdentifier ?? "StoriesTest"

extension Logger {
    static let app         = Logger(subsystem: subsystem, category: "app")
    static let viewer      = Logger(subsystem: subsystem, category: "viewer")
    static let list        = Logger(subsystem: subsystem, category: "list")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let images      = Logger(subsystem: subsystem, category: "images")
}
```

Subsystem derived from the candidate's own bundle identifier (e.g. `com.<candidate>.StoriesTest`) — not BeReal's namespace, which would look like bundle-ID squatting in review.

Discipline:
- `.debug` for state transitions (item start, like toggle), stripped from release builds by `Logger`.
- `.error` for caught exceptions and corruption fallbacks. Always log before swallowing.
- No `print`. No third-party logging dependency.
- Log values are non-PII (item IDs are synthetic, URLs are public picsum URLs).

This is the seam where analytics would hook in a real product — a `Tracker` protocol injected next to `Logger`. Out of scope here; mentioned in the README.

## Lifecycle, prefetch & persistence path

### scenePhase

CLAUDE.md hard rule: timer pauses when scene is not `.active`. Wired at the View layer because `@Environment(\.scenePhase)` is a SwiftUI environment value:

```swift
struct StoryViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var state: ViewerStateModel

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                phase == .active ? state.playback.resume() : state.playback.pause()
            }
    }
}
```

The View is the only layer that knows about `scenePhase`, and it drives `playback` directly — `ViewerStateModel` does not need a pass-through `pause()`/`resume()` since `playback` is publicly accessible. Both collaborators stay framework-agnostic for tests.

### Prefetch

`StoryListViewModel` and `ViewerStateModel` each own an `ImagePrefetchHandle` (defined in *Image loading*) for the lifetime of the screen and drive prefetch on state changes:

- **List**: when a page loads, prefetch avatar URLs for the page plus the *first* image of each user's first story item.
- **Viewer**: when the current user changes (TabView swipe), prefetch the next user's first story item URL. When `currentItemIndex` advances within a user, prefetch the next item's URL.

```swift
// Inside ViewerStateModel
private let prefetch = ImagePrefetchHandle()

func nextUser() {
    // ...advance index...
    prefetch.prefetch(urlsForUser(at: currentUserIndex + 1))
}
```

Because `ImagePrefetchHandle` is `@MainActor` and ViewModels are `@MainActor`, calls are direct with no actor hop. Two handles (List + Viewer) running simultaneously on overlapping URLs is harmless: Nuke deduplicates by `ImageRequest` cache key, so the second `startPrefetching` is a no-op for in-flight or cached entries. Each handle still cancels its own outstanding prefetches when its owning ViewModel deallocates, scoping bandwidth to the screen that needed it.

### Persistence file location

State lives in `Application Support/`, *not* `Documents/`:
- `Documents/` is exposed to Files.app and iCloud Document backup — wrong semantics for opaque app state.
- `Caches/` is purgeable by the OS — we'd lose seen/liked state silently.
- `Application Support/` is the documented home for app-private state and persists across launches.

```
~/Library/Application Support/StoriesTest/state.json
```

The directory is created on first launch. The file URL sets `URLResourceValues.isExcludedFromBackup = true`: although `Application Support/` is included in device backups by default, this state is reproducible (a fresh install starts empty and rebuilds organically), so spending iCloud bandwidth on it would be waste.

Corruption recovery: if `JSONDecoder` throws on init, the store logs `.error`, deletes the file, and starts empty. The fallback is preferable to crashing on launch.

## Navigation

```
NavigationView                        ← not used
.fullScreenCover(isPresented:)        ← used for viewer
TabView with .tabViewStyle(.page)     ← used inside viewer for user pagination
```

Rationale:
- The viewer is a modal experience, not a navigable destination. `.fullScreenCover` matches Instagram's behavior (slide up, blocks navigation, dismissed by gesture).
- TabView with page style is the simplest correct way to swipe between users. Custom UIPageViewController is unnecessary at this scope.

## Gestures & failure UI

### Tap zones (1:2 vertical split)

CLAUDE.md hard rule: the viewer page is split into two vertical zones — left third = previous, right two-thirds = next. The asymmetry mirrors Instagram and reflects that *forward* is the dominant action; making it the larger target is a Fitts-law improvement, not a stylistic choice.

```swift
struct ViewerTapZones: View {
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: geo.size.width / 3)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPrevious)
                    .accessibilityLabel("Previous")
                    .accessibilityAddTraits(.isButton)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNext)
                    .accessibilityLabel("Next")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .allowsHitTesting(true)
    }
}
```

The zones live above the image and below interactive UI (header close button, like button) using SwiftUI z-order. They're hidden from VoiceOver as buttons (not as tap zones) so screen-reader users get explicit affordances.

Long-press is a separate `LongPressGesture(minimumDuration: 0.2)` attached to the page; horizontal swipe is handled by the parent `TabView`; vertical swipe-down dismiss is a `DragGesture` on the page with the threshold from `design.md`.

### Image-fail UI

CLAUDE.md hard rule: failed item images render a visible failure frame, not a silent placeholder. The frame is `Surface`-tinted, shows a small icon + caption "Couldn't load this story", and exposes a `Retry` button. While the failure frame is on screen, `PlaybackController` is paused (the user has to act); tap-forward still navigates to the next item.

Wiring:
- `StoryViewerPage` reads load state from Nuke's `LazyImage` callback (`onCompletion`) and forwards `.failed(retry:)` to `ViewerStateModel`.
- `ViewerStateModel` calls `playback.pause()` on entry to the failure state and `playback.resume()` + `playback.reset()` on retry success.
- The retry path nudges Nuke to drop the cached failed response (`pipeline.cache.removeCachedImage(for:)`) before re-requesting, otherwise the cached failure short-circuits the retry.

This is the only place an error is surfaced inside the immersive viewer chrome. Pagination errors and persistence errors stay in the list (see *Error handling*).

## Dependency injection

No container. Constructor injection only. Composition root in `StoriesTestApp.swift`.

`PersistedUserStateStore.init` is `async throws` (it loads or creates the JSON file), so it cannot be called from `App.init`. Pattern: hold the root ViewModel as an optional `@State`, hydrate it from a `.task` on the root View, and show a thin loading state until ready.

```swift
@main
struct StoriesTestApp: App {
    @State private var listViewModel: StoryListViewModel?

    init() {
        ImageLoader.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let vm = listViewModel {
                    StoryListView(viewModel: vm)
                } else {
                    LoadingView()
                }
            }
            .task {
                guard listViewModel == nil else { return }
                await bootstrap()
            }
        }
    }

    private func bootstrap() async {
        let storyRepo = LocalStoryRepository.makeFromBundle()
        let stateStore: any UserStateRepository
        do {
            stateStore = try await PersistedUserStateStore.makeInApplicationSupport()
        } catch {
            Logger.persistence.error("State store init failed: \(error). Falling back to ephemeral.")
            stateStore = EphemeralUserStateStore()
        }
        listViewModel = StoryListViewModel(
            storyRepository: storyRepo,
            userStateStore: stateStore,
            clock: ContinuousClock()
        )
    }
}
```

Notes:
- `LoadingView` is intentionally trivial (black background + spinner). Hydration takes <50ms in practice; the View is only there for correctness, not UX.
- The corruption-recovery path falls back to `EphemeralUserStateStore` (in `Data/`, production-safe) so the app never crashes on a malformed state file. State is lost for the current session only; the persisted store is not rewritten by the ephemeral fallback. `InMemoryUserStateStore` (in `TestSupport/`) is a separate test fake — production code never references it.
- `ContinuousClock` is injected explicitly so tests can substitute a `TestClock` (see *Concurrency model*).

Why no container:
- Fewer than 5 dependencies. A container is more code than the wiring it replaces.
- Reviewers can read composition top-down in 30 seconds.
- Tests inject fakes directly into init. No registration boilerplate.

## Accessibility hooks

Accessibility lives in the View, not the ViewModel — labels and values are localizable strings, the ViewModel exposes the *facts* (`isLiked`, `currentItemIndex`, `itemCount`) and the View composes them into `accessibilityLabel` / `accessibilityValue`. This keeps the ViewModel free of `String(localized:)` calls that would break unit-test purity.

Concretely:
- `LikeButton`: `.accessibilityLabel("Like")`, `.accessibilityValue(isLiked ? "liked" : "not liked")`.
- `StoryTrayItem`: `.accessibilityLabel("\(user.username), \(isFullySeen ? "viewed" : "new")")`, `.accessibilityHint("Opens story")`.
- `SegmentedProgressBar`: hidden from accessibility (`.accessibilityHidden(true)`); the header announces "Item N of M" instead.
- Tap zones in the viewer expose `.accessibilityLabel("Next") / "Previous"` with `.accessibilityAddTraits(.isButton)`.

Reduced motion and Dynamic Type are explicitly out of scope (CLAUDE.md).

## Deep-link entry (out of scope, mentioned)

A real Stories product would accept `bereal://story/{userID}/item/{itemID}` and open the viewer pre-positioned. The architecture supports it cheaply: the viewer ViewModel already takes `(users, startUserIndex, startItemIndex)`. A `URL` handler in `StoriesTestApp` would map the link to those parameters and present the cover. Not implemented for the test; flagged in the README as a deliberate skip.

## Snapshot determinism

Snapshots that include image-loading components (`StoryAvatar`, `StoryTrayItem`, `StoryViewerPage`, `StoryListView`) cannot rely on real network fetches — tests would be flaky and slow.

Strategy:
- Inject a stub image source into Nuke's `ImagePipeline` for the test target only, via a `DataLoader` that returns a fixed in-memory PNG payload for any URL. Configured once in a test bootstrap.
- Snapshot helpers wait one runloop tick after the View appears so `LazyImage` resolves against the stub before the snapshot fires.
- Pin: iPhone 15 Pro, iOS 17.4 simulator, Xcode 15.4. Recorded in the test target's README.

Result: snapshot tests are hermetic, deterministic, and run in <1s each.

## Trade-off summary

| Decision | Chosen | Alternative | Why |
|---|---|---|---|
| Architecture | MVVM + Repository | TCA, Clean Arch | Best ratio of structure to ceremony for this scope |
| State mgmt | `@Observable` | `ObservableObject` | iOS 17 native, no `@Published` boilerplate, signals modern stack |
| Persistence | actor + JSON file | SwiftData, UserDefaults | Thread-safe by construction, fast, testable, right-sized |
| Pagination | local recycling with ID suffixes | network mock | Spec-compliant, no flaky tests |
| Images | Nuke | AsyncImage, custom | Production-grade caching/prefetch without writing it |
| Concurrency | Swift 6 strict | default | Compile-time correctness, senior signal |
| DI | constructor | container (Factory, Resolver) | Right-sized for app of this scope |
| Navigation | `.fullScreenCover` | NavigationStack | Modal semantics match the use case |
| Test framework | XCTest + snapshot-testing | Quick/Nimble, Swift Testing | Standard, familiar, fast feedback |

## What this architecture is NOT trying to be

- A reusable framework for stories. It's a focused implementation.
- A microservices-grade modular monolith. Folders, not Swift Packages, are the boundary.
- A platform-agnostic abstraction. iOS-first, SwiftUI-first.
- A demonstration of every iOS pattern. Show the right ones for the job.
