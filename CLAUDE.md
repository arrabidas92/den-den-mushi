# CLAUDE.md

Project context for AI-assisted development on the BeReal Senior iOS technical test.

For detailed design system, see `design.md`. For architecture and folder structure, see `architecture.md`.

## Mission

Build an Instagram Stories-like feature for a BeReal technical assessment. The product reproduces familiar Instagram UX patterns with a BeReal aesthetic (raw, dark, no gradients). Evaluation prioritizes UX polish, code quality, architecture, and **test coverage** over feature breadth.

## Hard rules

- **Language**: Swift 5.10+, SwiftUI primary. UIKit only when SwiftUI is genuinely insufficient.
- **iOS target**: 18.0 minimum. Use `@Observable`, `Observation` framework, `@Bindable`. Do NOT use `ObservableObject` / `@Published`. iOS 18 unlocks three APIs we use directly: `.matchedTransitionSource` + `.navigationTransition(.zoom)` for the tray-avatar→viewer transition, `onScrollGeometryChange` for the pagination N-3 trigger, and the relaxed `@MainActor`-by-default View isolation under Swift 6 strict concurrency. Targeting 17 in 2026 with no compensating reason is a stale-template signal in senior review.
- **Concurrency**: Swift 6 strict mode enabled. Everything is `Sendable` or explicitly marked. Repositories and stores are `actor`s. ViewModels are `@MainActor`.
- **External libraries**: only `Nuke` (image loading) and `swift-snapshot-testing` (test target only). Any other dependency must be justified to the user before adding.
- **Persistence**: `actor` + Codable JSON via `FileManager`. No SwiftData, no UserDefaults for state, no Core Data.
- **No business logic in Views**. Views read from `@Observable` view models and dispatch intents.
- **No singletons**. Dependencies passed via init.
- **No force-unwraps** outside of previews and tests. No implicitly unwrapped optionals.

## Product behavior (non-negotiable)

- A user's story content is **stable across sessions** (same images for same user). Use `picsum.photos/seed/{stableSeed}/{w}/{h}`.
- **Seen state is per StoryItem**, not per Story. A story is "fully seen" when all items are seen. Ring reflects fully-seen state.
- **Seen-marking rule.** An item is marked seen in two cases only: the user watched it for at least **1.5 seconds**, or the user explicitly tapped forward to the next item before that threshold. Opening a story and dismissing it in under 1.5s with no forward tap **does not mark it seen** — otherwise the ring would flip to "viewed" with zero content actually shown, which reads as a bug. The 1.5s floor matches the perceptual threshold for "I actually had time to see something"; the explicit-tap path covers power-skimmers who fly through a single user's stories and whose intent to advance we honour.
- **Like is per StoryItem**. Optimistic UI: state flips instantly, persistence happens after.
- **Pagination**: 10 users per page, triggered when scrolling reaches index N-3. Use `onScrollGeometryChange(for: Bool.self)` to derive a "near end" flag from `contentOffset` / `contentSize` / `containerSize`; expose the threshold as a pure function on `StoryListViewModel` so it is unit-testable without a View. Recycles the local JSON with suffixed IDs (`alice-p1`, `alice-p2`...).
- **Auto-advance**: 5s per item. Tap zones split **1:2 vertically** (left third = previous, right two-thirds = next, mirroring Instagram — forward is the dominant action). Long-press = pause. Swipe horizontal = next/prev user. Swipe down = dismiss.
- **Background pause**: timer pauses when scenePhase is not `.active`.
- **Image fail is visible**: failed item images render a `Surface`-tinted frame with a small icon, "Couldn't load this story" caption, and a `Retry` button. Auto-advance pauses on the failure frame; tap-forward still works. No haptic, no alert.

## Testing strategy

Testing is a first-class concern, not a final step. Tests are written **alongside** the code they cover.

### Unit & integration tests (Swift Testing)

Unit and integration tests use **Swift Testing**, not XCTest. Swift Testing has been stable since Xcode 16 (Sept 2024); in 2026 it is Apple's recommended path forward and XCTest is in maintenance. Three reasons it fits this project specifically:

- **Async-native** — `await` directly inside `@Test` functions, no `XCTestExpectation`/`wait(for:)` dance. Our `Clock<Duration>`-driven `PlaybackController` and `ViewerStateModel` tests assert with plain `await clock.advance(by:)`.
- **Parametrized tests first-class** — `@Test(arguments:)` collapses the seen-mark threshold matrix (0.5s/1.4s/1.5s/3.0s) to a single test rather than four near-duplicate methods.
- **`#expect` / `#require` show the actual expression** in failure output, instead of XCTest's stringified left/right operands.

Choosing XCTest in 2026 with a Swift 6 strict project would read as a stale-template signal in senior review, in the same way that targeting iOS 17 would.

**Must test**:
- `PersistedUserStateStore`: round-trip, concurrent writes, debounce, survival across re-init.
- `LocalStoryRepository`: page count, ID uniqueness across pages, deterministic output, JSON parse.
- `PlaybackController`: tick advance, pause/resume preserves progress, restart on item change resets to 0, scenePhase pause halts ticks and resumes from same offset.
- `ViewerStateModel`: all state transitions (next/prev item, next/prev user, dismiss on end), seen marking fires only after 1.5s OR on explicit next-tap, optimistic like flips state before persistence completes.
- `StoryListViewModel`: pagination triggers at N-3 (test the pure `shouldLoadMore(contentOffset:contentSize:containerSize:)` function — the View only forwards geometry from `onScrollGeometryChange`), no double-load, error states.

**Not tested** (mention in README):
- Pure View layouts (covered by snapshots).
- Nuke wrapper internals (trust the library).
- SwiftUI animation timings (out of scope).

### Snapshot tests (XCTest + swift-snapshot-testing)

Snapshots stay on **XCTest**. `swift-snapshot-testing` v1.x is built around `XCTestCase` — a Swift Testing companion exists but the diff/failure output is rougher and the integration is less smooth in 2026. Eight snapshot files vs. fighting the tooling: not worth it. Hybrid is the standard choice for serious iOS projects in 2026 — new logic in Swift Testing, snapshots on XCTest.

Pin device: iPhone 15 Pro. Pin Xcode/simulator version in README. Dark mode only.

**Snapshotted**:
- `StoryRing` — seen / unseen / loading, multiple sizes
- `StoryAvatar` — seen / unseen / loading / image-fail fallback
- `SegmentedProgressBar` — 1, 3, 5 segments × progress 0/50/100 × currentIndex variations
- `LikeButton` — liked / not liked
- `StoryTrayItem` — seen / unseen / long username / short username
- `StoryViewerHeader` — recent / old timestamp
- `StoryViewerPage` — single integration snapshot of the full viewer page
- `StoryListView` — full list with mixed seen/unseen states

**Not snapshotted**: transient animation states, network-dependent screens.

### Integration test (light)

One end-to-end VM scenario: load list → open user 3 → view 2 items → dismiss → assert seen state. In-memory repositories, no UI.

### Coverage target

Aim for ~80% on Domain + ViewModels. View code is intentionally uncovered.

### Test doubles

Hand-written fakes (`FakeStoryRepository`, `InMemoryUserStateStore`) in test target. No mocking framework.

## Polish explicitly skipped (documented in README)

Traded for test coverage:
- Interactive swipe-down dismiss (binary swipe is enough)
- Custom transition between users (default page transition used)
- Long-press hides full UI (just pauses)
- Animated heart pop on double-tap
- "Send message" footer field
- Crossfade on seen ring transition (instant swap is fine and one less thing to test)

Kept (low cost, high perceived quality):
- **Zoom transition tray avatar → viewer header** via `.matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom(sourceID:in:))` (iOS 18 native). The single transition reviewers feel most. Native API replaces the iOS 17 `matchedGeometryEffect` workaround — fewer artefacts on dismiss, less custom code, and it is the same primitive Photos.app uses.
- ScenePhase pause
- Image preloading via Nuke prefetch
- Reduced-motion support (auto-advancing content without it is a senior-submission red flag; ~30 min via the `Motion` tokens in `design.md`)
- Haptics on like
- Tap zones for next/previous (1:2 vertical split)

## Code style

- 4-space indent, no tabs.
- Trailing commas in multiline collections.
- `// MARK:` sections in files >100 lines.
- Type inference preferred when type is obvious.
- Prefer `guard` over nested `if`.
- All public types have a brief doc comment explaining intent, not implementation.
- SwiftUI previews for every reusable component, with seen/unseen variants.

## What NOT to do

- Do not add NavigationStack for the viewer presentation. Use `.fullScreenCover`.
- Do not implement a cube transition between users.
- Do not bundle images as assets. URLs only.
- Do not use `AsyncImage` for story images. Use Nuke.
- Do not use `Timer.scheduledTimer`. Use `Task` + `try await Task.sleep(for:)`.
- Do not implement features beyond the spec.
- Do not write a test that just re-asserts what the type system already enforces.
- Do not snapshot states that depend on network or animation timing.

## When in doubt

Ask. The user is a senior iOS engineer with 8 years of experience. Prefer clarifying questions over assumptions when a design choice has trade-offs.
