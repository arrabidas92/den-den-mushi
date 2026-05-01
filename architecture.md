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
│   │   ├── StoryListViewModel.swift
│   │   └── Components/
│   │       └── StoryTrayItem.swift       // (could move to DesignSystem if reused)
│   │
│   └── StoryViewer/
│       ├── StoryViewerView.swift
│       ├── StoryViewerViewModel.swift
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
│   ├── ImageLoader.swift                 // thin Nuke wrapper
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
│   └── StoryViewerViewModelTests.swift
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
Repositories          actor
State stores          actor
ViewModels            @MainActor (so `@Observable` properties drive SwiftUI on main)
Models                Sendable (struct + Codable + Hashable)
Image loader          actor wrapping Nuke (Nuke is already Sendable-safe in 12+)
Tasks                 structured concurrency only; no DispatchQueue
Timer                 Task + Task.sleep, never Timer.scheduledTimer
```

ViewModel pattern:

```swift
@MainActor
@Observable
final class StoryViewerViewModel {
    private(set) var currentItemIndex = 0
    private(set) var progress: Double = 0
    private(set) var isLiked = false

    private let stateStore: any UserStateRepository
    private var playbackTask: Task<Void, Never>?

    init(stateStore: any UserStateRepository, ...) { ... }

    func start() { ... }                  // launches playbackTask
    func toggleLike() { ... }             // optimistic update
    func nextItem() { ... }
    // etc.
}
```

The `playbackTask` is the timer. Cancel + restart on each transition. Always cancellation-aware (`Task.checkCancellation()` between sleeps).

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
        pendingFlush = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() { /* write JSON to fileURL */ }
}
```

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
        // Compute slice across the base list, suffix IDs to ensure uniqueness
        // page 0: stories 0..9 (suffix "-p0")
        // page 1: stories 10..19 mod base.count (suffix "-p1")
        // etc.
    }
}
```

ID suffixing is critical: it ensures seen/liked state for `alice-p0` is distinct from `alice-p1`, otherwise marking page-1-Alice seen would mark page-2-Alice seen.

ViewModel triggers `loadPage(currentPage + 1)` when `currentIndex >= count - 3`. Guard with an `isLoadingMore` flag to prevent double-loads.

## Image loading

`Nuke` is the only runtime dependency. Justification (for the README):

> Nuke handles HTTP image fetching, multi-tier caching (memory + disk), prefetching, and decompression. None of these are the core feature being evaluated. Implementing them by hand would consume time better spent on UX and tests, and would be lower quality than a battle-tested library used by major iOS apps. The alternative `AsyncImage` lacks disk cache, prefetching, and reliable cancellation, making it unfit for a production-grade Stories feature.

Wrapper:

```swift
enum ImageLoader {
    static func configure() {
        // Configure Nuke pipeline once at app start
    }

    static func prefetch(urls: [URL]) { ... }
}
```

Use Nuke's `LazyImage` SwiftUI view directly in the design components. The wrapper is only for prefetch and configuration.

URL strategy: `https://picsum.photos/seed/{stableSeed}/1080/1920` for story content, `/200/200` for avatars. The `seed` param guarantees stability — same URL → same image — which satisfies the spec's "user has the same content every time".

## Navigation

```
NavigationView                        ← not used
.fullScreenCover(isPresented:)        ← used for viewer
TabView with .tabViewStyle(.page)     ← used inside viewer for user pagination
```

Rationale:
- The viewer is a modal experience, not a navigable destination. `.fullScreenCover` matches Instagram's behavior (slide up, blocks navigation, dismissed by gesture).
- TabView with page style is the simplest correct way to swipe between users. Custom UIPageViewController is unnecessary at this scope.

## Dependency injection

No container. Constructor injection only. Composition root in `StoriesTestApp.swift`:

```swift
@main
struct StoriesTestApp: App {
    @State private var listViewModel: StoryListViewModel

    init() {
        let storyRepo = LocalStoryRepository.makeFromBundle()
        let stateStore = PersistedUserStateStore.makeInDocuments()
        let vm = StoryListViewModel(
            storyRepository: storyRepo,
            userStateStore: stateStore
        )
        _listViewModel = State(initialValue: vm)
        ImageLoader.configure()
    }

    var body: some Scene {
        WindowGroup {
            StoryListView(viewModel: listViewModel)
        }
    }
}
```

Why no container:
- Fewer than 5 dependencies. A container is more code than the wiring it replaces.
- Reviewers can read composition top-down in 30 seconds.
- Tests inject fakes directly into init. No registration boilerplate.

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
