import SwiftUI
import Nuke
import NukeUI

/// One full-bleed page of the viewer — image (or failure frame), tap
/// zones, long-press immersive. Knows about the *current* item only;
/// horizontal user navigation and swipe-down dismiss live one level up
/// in `StoryViewerView` so a single arbitrated drag gesture handles both
/// axes.
struct StoryViewerPage: View {

    @Bindable var state: ViewerStateModel
    let item: StoryItem
    /// Set by `StoryViewerView` based on the user-pagination index — only
    /// the foreground page handles gestures. Adjacent (parallax-offset)
    /// pages render the image alone.
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Optional because previews and tests can render the page without
    /// providing a monitor. In production it's injected at the app root.
    /// Auto-retry logic is gated on its presence.
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    /// Per-page failure flag for the failure frame, tap-zone hit-testing,
    /// and the long-press guard. The model carries an equivalent flag
    /// (`isCurrentItemFailed`) for the *active* page only — that one drives
    /// the chrome (footer hidden when failed). Adjacent pages keep their
    /// failure local to avoid contaminating the active item's state.
    @State private var loadFailed = false
    /// True while a Retry is in flight — the failure frame stays mounted
    /// (so the icon/text don't flicker out and back in), and the button
    /// swaps to a small spinner. Cleared on either outcome of the retry:
    /// a successful render dismisses the whole failure frame; a fresh
    /// failure flips this back to false so the button is tappable again.
    @State private var isRetrying = false
    /// Bumped on each Retry to force `LazyImage` to refetch even when the
    /// URL is unchanged. Without this, NukeUI may short-circuit on its
    /// internal request identity even after `ImageLoader.invalidate`
    /// purges the cache — the `.id(...)` modifier guarantees a hard
    /// re-mount of the LazyImage subtree per attempt.
    @State private var retryGeneration = 0
    /// Item id that the page has *successfully rendered*, regardless of
    /// whether the page was active at the time. When the page later
    /// becomes active (user swipes onto it) and this id matches the
    /// current item, we fire `markItemReady` immediately — covers the
    /// case where an adjacent page's auto-retry completed in the
    /// background before the swipe and `.task(id:)` therefore had no
    /// outcome change to react to.
    @State private var loadedItemID: String?
    /// Last successfully rendered image for this page, kept across URL
    /// retargets so a cache miss on the new item doesn't expose the
    /// parent's black background for the duration of the disk/network
    /// fetch. Cleared on a hard view-identity change (different page slot
    /// — handled by SwiftUI's `@State` reset semantics).
    @State private var lastImage: Image?

    /// Empirical: a long-press whose finger has moved more than this far
    /// is no longer a press. SwiftUI's `maximumDistance` parameter handles
    /// the cancellation natively.
    private static let longPressMaxMovement: CGFloat = 8
    /// Hold duration before immersive engages. Matches Instagram's
    /// perceptual feel — short enough that a deliberate hold reveals the
    /// image quickly, long enough that any tap-forward / tap-back / swipe
    /// completes well below the threshold and never even begins the
    /// transition. The previous `onPressingChanged` API armed at
    /// touch-down, which produced a flash on every tap (begin then
    /// immediate cancel). The new `LongPressGesture.onEnded` arms only
    /// *after* the duration elapses, so taps and swipes never enter
    /// immersive at all.
    private static let longPressMinimumDuration: Double = 0.3

    var body: some View {
        ZStack {
            imageLayer

            if isActive {
                ViewerTapZones(
                    onPrevious: state.previousItem,
                    onNext: state.nextItem,
                )
                .allowsHitTesting(!loadFailed && !state.isImmersive)
            }
        }
        .contentShape(Rectangle())
        // Long-press to enter immersive mode (chrome hides). The gesture
        // fires `onEnded` once the press has held for `minimumDuration`
        // *and* has not moved more than `maximumDistance` — so a tap
        // (release before the duration) and a swipe (drag past the
        // distance) both fail the gesture without ever entering immersive.
        // This is intentionally different from the previous
        // `onPressingChanged` approach: that callback fires `true` at
        // touch-down, which made every tap briefly arm immersive and
        // produce a chrome flash.
        //
        // Exit is handled by a simultaneous zero-distance `DragGesture`
        // whose `onEnded` fires on touch-up *regardless* of whether the
        // long-press succeeded. We only call `endImmersive` if we
        // actually entered immersive (`state.isImmersive == true`),
        // otherwise a plain tap would call endImmersive on a state that
        // isn't immersive — the model's `endImmersive` would still
        // resume playback, which would interfere with the tap-forward
        // path that just stopped/reset playback.
        .gesture(immersiveGesture)
        // Auto-retry when the network comes back. This fires for *every*
        // page (active or not), so an adjacent page that failed during the
        // outage retries silently in the background — by the time the user
        // swipes onto it, the image is already loaded. Mirrors Instagram's
        // "you don't have to keep tapping Retry on every story" behaviour.
        .onChange(of: networkMonitor?.isOnline ?? true) { _, isOnline in
            guard isOnline, loadFailed, !isRetrying else { return }
            retryLoad()
        }
        // Reset retry-related state when the page is reused for a different
        // item (active page navigates within a user). Without this,
        // `retryGeneration > 0` would leak across items and force every
        // subsequent fetch to bypass the cache, costing a network round-trip
        // per tap-forward.
        .onChange(of: item.id) { _, _ in
            retryGeneration = 0
            isRetrying = false
            loadFailed = false
            loadedItemID = nil
        }
        // When the page becomes active and its image is already loaded,
        // arm playback immediately. Covers the auto-retry-during-outage
        // case: an adjacent page may have finished its retry while we
        // were still on a different user, so by the time the reader
        // swipes onto it `.task(id:)` has no outcome change to fire on
        // and `markItemReady` would otherwise never be called.
        .onChange(of: isActive) { _, nowActive in
            guard nowActive, let id = loadedItemID, id == item.id else { return }
            state.markItemReady(itemID: id)
        }
    }

    // MARK: - Image outcome

    /// Identity used by `.task(id:)` to fire side-effects (mark seen,
    /// mark failed) exactly once per (item, outcome) tuple. Pairing the
    /// item id with the outcome ensures a stale identity from a previous
    /// item can never collide with the current one.
    private enum ImageOutcome: Hashable {
        case loading(itemID: String)
        case loaded(itemID: String)
        case failed(itemID: String)

        static func from(state: LazyImageState, itemID: String) -> ImageOutcome {
            if state.imageContainer != nil { return .loaded(itemID: itemID) }
            if state.error != nil { return .failed(itemID: itemID) }
            return .loading(itemID: itemID)
        }
    }

    // MARK: - Image request

    /// Builds the NukeUI request for the current item. On a fresh load
    /// (`retryGeneration == 0`) this is a vanilla URL request — Nuke is
    /// free to hit memory or disk cache. On Retry (`retryGeneration > 0`)
    /// we set `.reloadIgnoringCachedData` and override the cache image-id
    /// per attempt so Nuke treats each retry as a fresh request and
    /// reissues the fetch. Pairs with `ImageLoader.invalidate(...)` in
    /// `retryLoad` which already purged the cache entries.
    private func imageRequest() -> ImageRequest {
        if retryGeneration == 0 {
            return ImageRequest(url: item.imageURL)
        }
        return ImageRequest(
            url: item.imageURL,
            options: [.reloadIgnoringCachedData],
            userInfo: [.imageIdKey: "\(item.imageURL.absoluteString)#retry-\(retryGeneration)"],
        )
    }

    // MARK: - Image layer

    private var imageLayer: some View {
        // Single ZStack always mounted — failure frame and image share the
        // same coordinate space rather than being mutually exclusive
        // branches in an `if/else`. Why: an `if/else` flickers the failure
        // chrome (icon, text, button) out and back in on Retry because the
        // failure frame is dismounted the moment `loadFailed` flips to
        // false, then re-mounted milliseconds later when the retry refails.
        // Stacking instead lets the LazyImage cover the failure frame on
        // success, while a retry-in-flight keeps the failure frame visible
        // underneath until we know the outcome — Instagram's pattern.
        ZStack {
            // Black-flash on tap-forward fix:
            // 1. No `.id(item.id)` on the LazyImage by default — re-keying
            //    tears down the previous render and forces a placeholder
            //    frame even on a memory-cache hit. We only re-key on Retry
            //    (`retryGeneration`) to force a refetch.
            // 2. `lastImage` keeps the previously rendered image on screen
            //    when NukeUI retargets to a new URL. On a memory-cache hit
            //    `state.image` is non-nil within a frame and the swap is
            //    invisible; on a cache miss (user power-skims past the
            //    prefetch window, or memory-cache eviction) the previous
            //    image stays visible until the disk/network fetch resolves
            //    rather than exposing the parent's black background.
            // 3. `Color.clear` in the no-image branch — when there is genuinely
            //    no image to show (first item, no prior render), we don't
            //    paint an explicit black fill that would override anything
            //    NukeUI is still drawing under us.
            lastImage?
                .resizable()
                .aspectRatio(contentMode: .fill)
            // `LazyImage(request:)` rather than `(url:)` so we can vary
            // the cache policy on Retry without re-mounting the view.
            // Earlier we used `.id(retryGeneration)` to force a refetch,
            // but `.id` introduces an identity boundary that re-fires
            // tap-forward placeholder flashes and can drop the
            // `onCompletion` callback for the active item — visible as
            // the progress bar not arming after a successful retry.
            // Bumping the request via `retryGeneration` only changes the
            // request identity *inside* NukeUI; the SwiftUI view stays
            // mounted, the diff stays clean, and the completion fires
            // for the right item.
            // We drive seen/failed signalling from the *content closure*
            // rather than `.onCompletion`. NukeUI's `LazyImageView` retains
            // the `onCompletion` closure from its first `onAppear` and does
            // not propagate updates across SwiftUI body re-evaluations, so
            // a closure that captures `item.id` (or `isActive`) goes stale
            // the moment the page slot is reused for a different item —
            // visible as the progress bar never arming after a tap-forward
            // because the stale closure compares against the *previous*
            // item's id.
            //
            // The content closure on the other hand *is* re-invoked with
            // the live `LazyImageState` on every body pass, so its captures
            // (item.id, the model) are always the current ones.
            LazyImage(request: imageRequest()) { imageState in
                ZStack {
                    if let image = imageState.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Both `error` and the in-flight states render
                        // Color.clear so the failure frame underneath
                        // stays visible without a transient grey wash.
                        Color.clear
                    }
                }
                .task(id: ImageOutcome.from(state: imageState, itemID: item.id)) {
                    // `task(id:)` cancels and restarts whenever the outcome
                    // identity changes. Idempotent calls into the model
                    // are fine — `markItemReady` and `markCurrentItemFailed`
                    // are both guarded against duplicates.
                    if let uiImage = imageState.imageContainer?.image {
                        lastImage = Image(uiImage: uiImage)
                        loadedItemID = item.id
                        loadFailed = false
                        isRetrying = false
                        state.markItemReady(itemID: item.id)
                    } else if imageState.error != nil {
                        handleLoadFailure()
                    }
                }
            }

            if loadFailed {
                failureFrame
            }
        }
        .clipped()
    }

    private var failureFrame: some View {
        ZStack {
            Color.surface
            VStack(spacing: Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color.textTertiary)
                Text("Couldn't load this story")
                    .font(.timestamp)
                    .foregroundStyle(Color.textSecondary)
                // Button swaps to a spinner during the refetch — icon and
                // text stay put. The fixed `minWidth`/`minHeight` keeps the
                // VStack layout stable across the swap so nothing shifts
                // beneath the spinner.
                Button(action: retryLoad) {
                    Group {
                        if isRetrying {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color.textPrimary.opacity(0.7))
                        } else {
                            Text("Retry")
                                .font(.body15)
                                .foregroundStyle(Color.textPrimary.opacity(0.7))
                        }
                    }
                    .frame(minWidth: 88, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .accessibilityLabel(isRetrying ? "Retrying" : "Retry loading story")
            }
        }
    }

    // MARK: - Gestures

    /// Composite gesture that arms immersive on a held press and disarms
    /// on touch-up. Two pieces, run simultaneously:
    ///
    /// - `LongPressGesture` fires `.onEnded` exactly once, *after* the
    ///   minimum duration has elapsed and the finger has stayed within
    ///   `maximumDistance`. Taps (released early) and swipes (moved far)
    ///   both fail the gesture and never call `beginImmersive`.
    /// - `DragGesture(minimumDistance: 0)` is the only reliable way in
    ///   SwiftUI to detect touch-up regardless of whether the long-press
    ///   succeeded. Its `.onEnded` fires on every release and we use it
    ///   to exit immersive — guarded on `state.isImmersive` so a plain
    ///   tap doesn't call `endImmersive` on a non-immersive state (which
    ///   would resume playback and fight the tap-forward path).
    ///
    /// Gated on `isActive && !loadFailed` so adjacent (parallax) pages
    /// and the failure frame don't engage immersive.
    private var immersiveGesture: some Gesture {
        let press = LongPressGesture(
            minimumDuration: Self.longPressMinimumDuration,
            maximumDistance: Self.longPressMaxMovement,
        )
        .onEnded { _ in
            guard isActive, !loadFailed else { return }
            state.beginImmersive()
        }
        let release = DragGesture(minimumDistance: 0)
            .onEnded { _ in
                guard state.isImmersive else { return }
                state.endImmersive()
            }
        return press.simultaneously(with: release)
    }

    // MARK: - Failure handling

    private func handleLoadFailure() {
        // Always reset the spinner — even if `loadFailed` was already true,
        // an in-flight retry just landed and the button must become tappable
        // again. Without this, a refailed retry leaves the spinner spinning.
        isRetrying = false
        guard !loadFailed else { return }
        loadFailed = true
        if isActive {
            state.markCurrentItemFailed()
        }
    }

    private func retryLoad() {
        guard !isRetrying else { return }
        isRetrying = true
        ImageLoader.invalidate(item.imageURL)
        // Bump the LazyImage identity so NukeUI reissues the request. The
        // failure frame stays mounted (loadFailed is *not* cleared here) —
        // success in `onCompletion` is what dismisses it. This is the fix
        // for the "icon + text + button flicker" on Retry: the user sees
        // the button swap to a spinner, then either the image fades in or
        // the spinner becomes a button again.
        retryGeneration += 1
        if isActive {
            state.retryCurrentItem()
        }
    }
}

// MARK: - Previews

#Preview("Loaded image") {
    let user = User(
        id: "alice",
        stableID: "alice",
        username: "alice.demo",
        avatarURL: URL(string: "https://picsum.photos/seed/alice/200/200")!,
    )
    let item = StoryItem(
        id: "alice-1",
        imageURL: URL(string: "https://picsum.photos/seed/alice-1/1080/1920")!,
        createdAt: Date(),
    )
    let story = Story(id: user.id, user: user, items: [item])
    let state = ViewerStateModel(
        users: [story],
        startUserIndex: 0,
        stateStore: EphemeralUserStateStore(),
    )
    return StoryViewerPage(state: state, item: item)
        .background(Color.background)
        .preferredColorScheme(.dark)
}
