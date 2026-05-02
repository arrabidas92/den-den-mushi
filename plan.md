# plan.md

Implementation plan for the BeReal Stories test. Companion to `architecture.md` and `design.md` — both must be read first; this file translates the validated specs into an ordered, gated build sequence.

## Guiding principles

- **Vertical slices, test-first per phase.** Every phase ships code *and* its tests in the same gate. No "we'll write the tests at the end".
- **Bottom-up on foundations, top-down on features.** Domain → Data → DesignSystem are stable, dependency-free layers built first. StoryList → StoryViewer consume them.
- **Explicit gating.** Each phase ends with a concrete pass condition (green tests, manual demo, or console check). No phase begins until the previous one is green.
- **No throwaway scaffolding.** Anything written has a place in the final deliverable. No "placeholder to replace later".

## Phase 0 — Project bootstrap (~30 min)

**Goal:** an Xcode project that compiles, with tests included, dependencies added, local CI green.

1. Create the Xcode project `Stories` (iOS app, SwiftUI, iOS 18 minimum, Swift 6 strict mode, **Default Actor Isolation = MainActor**).
2. Create the targets: `Stories` (app) and `StoriesTests` (Swift Testing only — no XCTest layer needed once snapshot tests are dropped).
3. Add `Nuke` via SPM (app target only).
4. *(removed: `swift-snapshot-testing` — see CLAUDE.md "Testing strategy" / architecture.md "Visual contract" for the rationale.)*
5. Create the exact folder structure from `architecture.md` § *Folder structure* (empty, with a `.gitkeep` if needed).
6. Configure Xcode coverage **only** for `Domain/` and the ViewModels (`StoryListViewModel`, `ViewerStateModel`, `PlaybackController`) at the scheme level.
7. Add a minimal `stories.json` (5–7 users, 2–4 items each, `picsum.photos/seed/...` URLs) under `Data/Resources/`.

**Gate:** `cmd-B` compiles, `cmd-U` runs the empty suite without error, the project opens in Xcode 16.

## Phase 1 — Domain (~45 min)

**Goal:** immutable models and protocols, imported everywhere downstream.

1. `Domain/Models/User.swift` — `struct User: Sendable, Hashable, Codable` with `id`, `stableID`, `username`, `avatarURL`.
2. `Domain/Models/StoryItem.swift` — `id`, `imageURL`, `createdAt`.
3. `Domain/Models/Story.swift` — `id`, `user: User`, `items: [StoryItem]`. Method `withPageSuffix(_ pageIndex: Int) -> Story`.
4. `Domain/Models/UserState.swift` — `seenItemIDs: Set<String>`, `likedItemIDs: Set<String>`, Codable.
5. `Domain/Models/HeartPop.swift` — `Sendable, Equatable`, `id: UUID`, `location: CGPoint` (import `CoreGraphics`, not SwiftUI).
6. `Domain/Models/StoryError.swift` — the full enum from the architecture.
7. `Domain/Repositories/StoryRepository.swift` — `Sendable` protocol.
8. `Domain/Repositories/UserStateRepository.swift` — `Sendable` protocol with `flushNow()`.

**Gate:** Domain compiles in isolation (verify only `import Foundation` and `import CoreGraphics` — no `SwiftUI`, no `Nuke`).

## Phase 2 — Data layer + tests (~2h)

**Goal:** concrete repositories, reliable persistence, ready to be consumed. Unit tests written **alongside**.

1. `Data/LocalStoryRepository.swift` — actor, loads `stories.json` from the bundle, implements the pagination + suffixing formula.
2. `LocalStoryRepositoryTests.swift` (Swift Testing):
   - JSON parses correctly
   - `loadPage(0)` returns 10 items
   - cross-page ID uniqueness
   - deterministic output
   - edge case `n=0` → empty array, no crash
   - edge case `n < pageSize` (e.g. `n=7`) → wraps correctly, suffix shared intra-page
3. `Data/PersistedUserStateStore.swift` — actor, `Application Support/`, `isExcludedFromBackup`, 500ms debounce, `flushNow()`, corruption recovery.
4. `Data/EphemeralUserStateStore.swift` — in-memory actor (production-safe fallback, not test-only).
5. `PersistedUserStateStoreTests.swift`:
   - seen/like round-trip
   - concurrent writes via `withTaskGroup` (verifies absence of races by construction)
   - debounce coalesces bursts (with `TestClock` or short `Task.sleep`)
   - cross-init survival (recreate a store on the same file)
   - corruption → file deleted, store starts empty
6. `Data/ImageLoader.swift` — `enum` with `static func configure()` (Nuke pipeline: memory cache, disk cache TTL, timeouts).
7. `Data/ImagePrefetchHandle.swift` — `@MainActor final class` (Nuke 12 constraint).
8. `TestSupport/FakeStoryRepository.swift` — programmable pages, injectable errors.
9. `TestSupport/InMemoryUserStateStore.swift` — test-only fake (separate from `EphemeralUserStateStore`).

**Gate:** all Data tests green; Domain + Data coverage ≥ 80% on the critical paths.

## Phase 3 — DesignSystem (tokens + components) (~1h30)

**Goal:** complete visual kit, previewable in Xcode. No dependency on ViewModels.

1. `DesignSystem/Tokens/Colors.swift` — extension `Color` with every token from `design.md`.
2. `DesignSystem/Tokens/Typography.swift` — extension `Font` with the 6 named styles.
3. `DesignSystem/Tokens/Spacing.swift` — `enum Spacing { static let xs = 4 ... }`.
4. `DesignSystem/Tokens/Motion.swift` — `enum Motion` with `.fast`, `.standard`, `.slow`, `.itemPlay`, `.skeletonPulse`, returning `Animation`. Honour `accessibilityReduceMotion` (collapse to 0).
5. `DesignSystem/Tokens/TrayDensity.swift` — `enum`, environment value.
6. `DesignSystem/Components/StoryRing.swift` — states `.seen|.unseen|.loading`. Preview.
7. `DesignSystem/Components/StoryAvatar.swift` — uses Nuke's `LazyImage` + `StoryRing`. States: loading, loaded, failed (initials). Preview.
8. `DesignSystem/Components/SegmentedProgressBar.swift` — pure rendering. Preview with 1, 3, 5 segments.
9. `DesignSystem/Components/LikeButton.swift` — heart, internal spring + haptic on tap. Preview.
10. `DesignSystem/Components/StoryTrayItem.swift` — `StoryTrayItemState` enum, density. Preview with all 3 states.
11. `Core/Haptics.swift` — minimal UIKit wrapper.
12. **`#Preview` matrix** — every component file ships at least one `#Preview` block exercising its full state set (`.unseen | .seen | .loading` for the ring, `.notLiked | .liked` for the like button, `.loaded | .loading | .failed` for the tray item, etc.). This replaces the snapshot suite originally planned here; rationale lives in CLAUDE.md "Testing strategy" and architecture.md "Visual contract".

**Gate:** every component appears in previews with its variants and renders correctly in dark mode in Xcode's preview canvas.

## Phase 4 — StoryList feature (~2h)

**Goal:** working tray, paginated, viewer not yet wired.

1. `Features/StoryList/StoryListViewModel.swift`:
   - `pages: [Story]`, `isLoading`, `isLoadingMore`, `loadingError`
   - `loadInitial()`, `loadMoreIfNeeded()` with an `isLoadingMore` guard
   - `shouldLoadMore(contentOffset:contentSize:containerSize:) -> Bool` (pure, testable)
   - prefetch avatars + first item via `ImagePrefetchHandle`
   - reads `isSeen` from the store to compute `isFullySeen` per story
2. `StoryListViewModelTests.swift`:
   - `shouldLoadMore` across geometric states (before N-3, at N-3, past)
   - no double-load (two concurrent calls → a single page loaded)
   - retryable error state (`isLoadingMore` flips back to false, retry possible)
   - initial state → skeleton
3. `Features/StoryList/StoryListView.swift`:
   - `ScrollView(.horizontal)` + `LazyHStack` of `StoryTrayItem`
   - skeleton tray on initial state
   - `.onScrollGeometryChange(for: Bool.self)` → `viewModel.shouldLoadMore(...)`
   - trailing skeleton when `isLoadingMore`, trailing failure on error
   - `@Namespace` for `matchedTransitionSource`
4. *(removed: snapshot suite dropped — list states are exercised via `#Preview` in `StoryListView.swift`.)*

**Gate:** the app shows the tray, scrolls, loads pages 1/2/3, displays the skeleton during load, retry works on error (force an error in `FakeStoryRepository` to verify visually). Tests green.

## Phase 5 — StoryViewer: Playback + ViewerStateModel (~2h30)

**Goal:** viewer engine fully tested before any View is written.

1. `Features/StoryViewer/PlaybackController.swift`:
   - `@Observable`, `progress`, `isPaused`, `onItemEnd`
   - `start()`, `pause()`, `resume()`, `reset()`
   - `Task` loop + `clock.sleep(for: tickInterval)`, cancellation-aware
   - pause = a flag respected by the loop, never cancels the Task
2. `PlaybackControllerTests.swift` (with `TestClock`):
   - tick advances `progress` linearly
   - pause halts advancement, resume picks up from offset
   - reset returns to 0
   - `onItemEnd` fires at 1.0
   - clean cancel on deinit
3. `Features/StoryViewer/ViewerStateModel.swift` (the full surface from the architecture):
   - navigation: `nextItem/previousItem/nextUser/previousUser/dismiss`
   - seen marking: 1.5s task + tap-forward branch
   - optimistic like + idempotent `doubleTapLike`
   - immersive: `beginImmersive/endImmersive` synced with playback
   - drag: `updateDrag/endDrag/shouldCommitDismiss` (pure)
   - `pendingHeartPop` cleared via `clock.sleep`
   - prefetch next
4. `ViewerStateModelTests.swift` (parametrized wherever possible):
   - next/prev item, next/prev user transitions (incl. boundaries)
   - dismiss at the end of the last user
   - `@Test(arguments:)` 1.5s rule: 0.5s/1.4s/1.5s/3.0s + tap-forward branch
   - optimistic like: state flips before `await store.toggleLike` completes
   - `shouldCommitDismiss` matrix (translation, velocity, container)
   - `updateDrag` pause + snap-back resume
   - `doubleTapLike` idempotent (already liked stays liked, pop refires)
   - `beginImmersive/endImmersive` ↔ `playback.isPaused` lockstep
   - `pendingHeartPop` cleared after the animation window (advance the clock)

**Gate:** viewer engine fully tested, 100% of the seen-rule + dismiss + double-tap branches covered. No View written yet at this point.

## Phase 6 — StoryViewer: Views + gestures (~3h)

**Goal:** assemble the viewer on top of the validated engine.

1. `Components/StoryViewerHeader.swift` (with `#Preview` for recent / old timestamp variants).
2. `Components/StoryViewerFooter.swift` (LikeButton + optionally a disabled/skipped input field).
3. `Components/StoryViewerPage.swift`:
   - `LazyImage` Nuke with `onCompletion` → `.failed(retry:)`
   - failure frame (Surface, glyph, caption, Retry)
   - 1:2 tap zones (`ViewerTapZones`)
   - long-press → `beginImmersive/endImmersive`, conflict resolution > 8pt
   - double-tap → `doubleTapLike`, heart-pop overlay
   - drag-down → `updateDrag/endDrag`, scale + opacity bound to `dragProgress`
   - chrome conditionally opacified by `isImmersive`
4. `StoryViewerView.swift`:
   - paged `HStack` + horizontal `DragGesture` for user nav (parallax + scale + opacity per `design.md`)
   - axis lock at 12pt
   - `SegmentedProgressBar` bound to `playback.progress`
   - `.onChange(of: scenePhase)` → `playback.pause/resume`
   - `.onDisappear` → `await store.flushNow()`
   - `.navigationTransition(.zoom(sourceID:in:))`
5. Wiring `.fullScreenCover` from `StoryListView` on item tap.
6. *(removed: viewer-page snapshot test dropped — full viewer is exercised via `#Preview` in `StoryViewerView.swift`.)*

**Gate:** full manual demo — zoom open transition, auto-advance, tap forward/back, long-press chrome hide, double-tap heart, interactive swipe-down dismiss, horizontal user swipe, scenePhase pause (Home → return), seen/like persistence (kill app → relaunch).

## Phase 7 — Composition root + integration (~45 min)

1. `App/StoriesApp.swift` per the architecture's exact pattern: optional `@State` ViewModel, `.task` bootstrap, `EphemeralUserStateStore` fallback.
2. `LoadingView` (24pt ProgressView on Background).
3. `Logger` extension in `Core/`.
4. `Integration/StoryFlowIntegrationTests.swift`: load list → open user 3 → view 2 items → dismiss → assert seen.

**Gate:** the app boots cleanly, the integration test passes.

## Phase 8 — Polish, README, final verifications (~1h30)

1. Verify coverage **per target** (Domain ≥ 80%, ViewModels ≥ 80%) — surface in the README.
2. README: *Polish skipped* section, dependency justifications, pinned Xcode/simulator version, run instructions.
3. Accessibility pass: labels/values on all interactive elements (cf. architecture § *Accessibility hooks*).
4. Reduced-motion pass: force the toggle, verify `Motion` collapse, instant ring transitions.
5. Manual haptics pass on device if available.
6. Clean `git log` — squash where needed.

**Final gate:** `cmd-U` all green, app runs in the simulator, README up to date.

## Total estimate

~14h of focused work. Fits in 2 dense sessions or 3 normal ones. Phase 5 (engine tested before any View) is the pivot: if it derails there, everything downstream collapses — hence the strict gate.

## Identified risks

- **`onScrollGeometryChange` + horizontal `LazyHStack`.** API is stable but the `nearEnd` derivation may fire too early depending on `itemExtent`. Plan B documented: fall back to the last `StoryTrayItem.onAppear` if the API misbehaves in practice.
- **`.navigationTransition(.zoom)` outside `NavigationStack`.** Combination with `.fullScreenCover` is supported but worth verifying early (phase 6); if KO, fall back to `matchedGeometryEffect` (~30 extra lines, accepted as a documented trade-off).
- *(snapshot risk removed alongside the snapshot suite itself — `#Preview`-driven visual review has no determinism prerequisites.)*
