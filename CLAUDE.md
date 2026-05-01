# CLAUDE.md

Project context for AI-assisted development on the BeReal Senior iOS technical test.

For detailed design system, see `design.md`. For architecture and folder structure, see `architecture.md`.

## Mission

Build an Instagram Stories-like feature for a BeReal technical assessment. The product reproduces familiar Instagram UX patterns with a BeReal aesthetic (raw, dark, no gradients). Evaluation prioritizes UX polish, code quality, architecture, and **test coverage** over feature breadth.

## Hard rules

- **Language**: Swift 5.10+, SwiftUI primary. UIKit only when SwiftUI is genuinely insufficient.
- **iOS target**: 17.0 minimum. Use `@Observable`, `Observation` framework, `@Bindable`. Do NOT use `ObservableObject` / `@Published`.
- **Concurrency**: Swift 6 strict mode enabled. Everything is `Sendable` or explicitly marked. Repositories and stores are `actor`s. ViewModels are `@MainActor`.
- **External libraries**: only `Nuke` (image loading) and `swift-snapshot-testing` (test target only). Any other dependency must be justified to the user before adding.
- **Persistence**: `actor` + Codable JSON via `FileManager`. No SwiftData, no UserDefaults for state, no Core Data.
- **No business logic in Views**. Views read from `@Observable` view models and dispatch intents.
- **No singletons**. Dependencies passed via init.
- **No force-unwraps** outside of previews and tests. No implicitly unwrapped optionals.

## Product behavior (non-negotiable)

- A user's story content is **stable across sessions** (same images for same user). Use `picsum.photos/seed/{stableSeed}/{w}/{h}`.
- **Seen state is per StoryItem**, not per Story. A story is "fully seen" when all items are seen. Ring reflects fully-seen state.
- **Seen mark is set when an item starts playing**, not when it completes (matches Instagram behavior).
- **Like is per StoryItem**. Optimistic UI: state flips instantly, persistence happens after.
- **Pagination**: 10 users per page, triggered when scrolling reaches index N-3. Recycles the local JSON with suffixed IDs (`alice-p1`, `alice-p2`...).
- **Auto-advance**: 5s per item. Tap right = next, tap left = previous. Long-press = pause. Swipe horizontal = next/prev user. Swipe down = dismiss.
- **Background pause**: timer pauses when scenePhase is not `.active`.

## Testing strategy

Testing is a first-class concern, not a final step. Tests are written **alongside** the code they cover.

### Unit tests (XCTest)

**Must test**:
- `PersistedUserStateStore`: round-trip, concurrent writes, debounce, survival across re-init.
- `LocalStoryRepository`: page count, ID uniqueness across pages, deterministic output, JSON parse.
- `StoryViewerViewModel`: all state transitions (next/prev item, next/prev user, dismiss on end), seen marking on item start, optimistic like, pause/resume preserves progress.
- `StoryListViewModel`: pagination triggers at N-3, no double-load, error states.

**Not tested** (mention in README):
- Pure View layouts (covered by snapshots).
- Nuke wrapper internals (trust the library).
- SwiftUI animation timings (out of scope).

### Snapshot tests (swift-snapshot-testing)

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
- Matched geometry effect avatar → viewer header
- Interactive swipe-down dismiss (binary swipe is enough)
- Custom transition between users (default page transition used)
- Long-press hides full UI (just pauses)
- Animated heart pop on double-tap
- "Send message" footer field

Kept (low cost, high perceived quality):
- ScenePhase pause
- Image preloading via Nuke prefetch
- Crossfade on seen ring transition
- Haptics on like
- Tap zones for next/previous

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
