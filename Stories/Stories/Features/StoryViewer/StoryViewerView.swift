import SwiftUI

/// Modal viewer presented over the tray. Owns the chrome (header, footer,
/// progress bar), the unified drag gesture (axis-locked between
/// horizontal user-pagination and vertical swipe-to-dismiss), and the
/// scenePhase pause hook. Per-page behaviour (image, tap zones, long-press,
/// double-tap) lives in `StoryViewerPage`.
///
/// Why a single unified DragGesture: nesting a vertical drag on each page
/// underneath a horizontal drag on the pager produced a race where the
/// inner gesture would steal a partly-horizontal swipe — the user's
/// intended user-pagination swipe ended up doing nothing. One gesture at
/// the top, axis-locked at first engagement, removes the ambiguity and
/// keeps the page free to handle taps, double-taps, and long-press.
struct StoryViewerView: View {

    @Bindable var state: ViewerStateModel
    /// Source-side namespace from the tray. Used by
    /// `.navigationTransition(.zoom(sourceID:in:))` so the avatar morphs
    /// into the viewer header on present.
    let transitionNamespace: Namespace.ID
    /// Fired the instant `state.shouldDismiss` flips to `true`, *before*
    /// the cover starts its close animation. The tray applies the
    /// in-session seen-set here so the avatar's ring resolves to its
    /// final state on the same frame the matched zoom-out begins —
    /// invoking on `.onDisappear` (which fires after the animation) made
    /// the ring visibly flip a few frames *after* the cover landed.
    /// Receives the *current* user (which may differ from the one the
    /// viewer was opened on if the reader swiped horizontally between
    /// users) so the tray can refresh that ring and scroll the matching
    /// cell on screen as the zoom-out target.
    /// The closure is `Sendable`-friendly (no captured Views).
    var onDismiss: ((Story) -> Void)? = nil
    /// Fired whenever the reader's *current* user changes (initial open
    /// and every horizontal swipe). The tray uses this to keep the
    /// matching `matchedTransitionSource` cell mounted and centred while
    /// the cover is on screen, so a later dismiss collapses onto a live
    /// anchor instead of a recycled LazyHStack slot.
    var onCurrentUserChange: ((Story) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Live horizontal drag offset for the user-pagination swipe. Local
    /// to the View — once committed, it animates back to 0 and the
    /// `currentUserIndex` on the model has advanced.
    @State private var horizontalDrag: CGFloat = 0
    /// Lock the dominant axis at first engagement so a near-diagonal drag
    /// is unambiguous. `nil` until the gesture engages (past
    /// `dragMinimumDistance`), then pinned for the rest of the gesture.
    @State private var lockedAxis: DragAxis?
    // Note on `.navigationTransition(.zoom(sourceID:))` below: we read the
    // current user's stableID directly from `state` instead of pinning it
    // to the opening user via `@State`. iOS 18 reads `sourceID` lazily at
    // dismiss time, so updating a `@State` in `onChange(of: shouldDismiss)`
    // does *not* take effect — the cover collapses to whatever ID the
    // transition was last bound to. Re-binding on every swipe was avoided
    // earlier over flicker concerns on the chrome (close/like/header), but
    // the chrome subtree is already insulated by `.animation(nil, value:
    // currentUserIndex)`, so the re-bind no longer manifests visually.

    /// Translation past which the user-pagination swipe commits to the
    /// next/previous user (a quarter of the container width).
    private static let userSwipeCommitFraction: CGFloat = 0.25
    private static let userSwipeVelocityThreshold: CGFloat = 500
    /// Minimum drag distance before the unified gesture engages. Set above
    /// zero so a pure tap (translation == 0) never enters the drag path —
    /// otherwise SwiftUI's gesture arbitration steals the tap away from the
    /// child `ViewerTapZones`.
    private static let dragMinimumDistance: CGFloat = 10

    private enum DragAxis { case horizontal, vertical }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background is *outside* the dismiss-card transform: it
                // stays full-bleed and only fades, while image+chrome
                // translate and scale together.
                background
                // Image + chrome translate and scale together as a single
                // dismiss card so the chrome stays glued to the image during
                // a swipe-down. Earlier this was applied to a ZStack wrapping
                // both subtrees — but the snap-back `.spring` animation on
                // `dragOffset/dragProgress` was an *ambient* parent animation
                // and propagated into the chrome subtree, animating the scrim
                // gradients, close button, and like icon (visible flicker).
                // Applying the same transform to each subtree independently
                // keeps the visual coupling but isolates the parent
                // transaction, so a body re-eval triggered by a drag tick
                // never reaches the chrome's gradient/icon diff path.
                pagedStack(containerSize: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(y: state.dragOffset)
                    .scaleEffect(1.0 - CGFloat(state.dragProgress) * 0.15, anchor: .top)
                // Scrims are rendered as their own subtree, *outside* the
                // chrome's immersive opacity toggle. They stay mounted and
                // fully opaque on every state change — long-press, tap
                // forward, item swap, user swap. Why: previously the scrims
                // sat as `.background` of the header/footer inside
                // `ViewerChrome` and inherited the chrome's `opacity` on
                // `isImmersive`, plus the structural diff when the footer
                // toggled on `isCurrentItemFailed`. Both produced visible
                // scrim flicker. Pulling them out to a stable, always-on
                // subtree removes both ambient-animation paths in one move.
                ViewerScrims()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(y: state.dragOffset)
                    .scaleEffect(1.0 - CGFloat(state.dragProgress) * 0.15, anchor: .top)
                ViewerChrome(
                    user: state.currentUser.user,
                    timestamp: state.currentItem.createdAt,
                    itemCount: state.currentUser.items.count,
                    currentItemIndex: state.currentItemIndex,
                    isLiked: state.isLiked,
                    isImmersive: state.isImmersive,
                    isCurrentItemFailed: state.isCurrentItemFailed,
                    playback: state.playback,
                    reduceMotion: reduceMotion,
                    onClose: state.dismiss,
                    onToggleLike: state.toggleLike,
                )
                .allowsHitTesting(!state.isImmersive)
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(y: state.dragOffset)
                .scaleEffect(1.0 - CGFloat(state.dragProgress) * 0.15, anchor: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Pages are laid out as one wide HStack offset behind the
            // viewport; without clipping, neighbour pages bleed past the
            // active page and read as ghost edges on either side.
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(unifiedDragGesture(containerSize: geo.size))
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationTransition(.zoom(sourceID: state.currentUser.user.stableID, in: transitionNamespace))
        .task {
            onCurrentUserChange?(state.currentUser)
            await state.onAppear()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                state.playback.resume()
            } else {
                state.playback.pause()
            }
        }
        .onChange(of: state.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                Haptics.dismiss()
                // Notify the tray *before* requesting dismissal so the
                // optimistic ring update is committed in the same
                // transaction that drives the matched zoom-out.
                onDismiss?(state.currentUser)
                dismiss()
            }
        }
        .onChange(of: state.currentUserIndex) { _, _ in
            Haptics.userChange()
            onCurrentUserChange?(state.currentUser)
        }
        .onDisappear {
            // Flush persistence on the way out so seen/like for the last
            // session reach disk before the user backgrounds the app.
            // fire-and-forget — the View is being torn down.
            Task { await state.flushPendingPersistence() }
        }
    }

    // MARK: - Background

    private var background: some View {
        // The viewer canvas itself is opaque black; the *outer*
        // background opacity (above) is what the matched-transition
        // dismiss interpolates against.
        Color.background
            .opacity(1.0 - state.dragProgress)
            .ignoresSafeArea()
    }

    // MARK: - Paged stack

    private func pagedStack(containerSize: CGSize) -> some View {
        let width = containerSize.width
        let baseOffset = -CGFloat(state.currentUserIndex) * width + horizontalDrag
        return HStack(spacing: 0) {
            // `id: \.offset` instead of the story id: pagination intentionally
            // repeats users within a page (CLAUDE.md: "intra-page dedup is
            // acceptable"), so two slots can share the same Story.id. The
            // ForEach key must be the slot index, not the element identity,
            // otherwise SwiftUI logs "ID X occurs multiple times" and picks
            // an arbitrary view to render — which is what causes the random
            // page-content swap during user changes.
            ForEach(Array(state.users.enumerated()), id: \.offset) { index, story in
                StoryViewerPage(
                    state: state,
                    item: page(for: story, isActive: index == state.currentUserIndex),
                    isActive: index == state.currentUserIndex,
                )
                .frame(width: width, height: containerSize.height)
                // Clip each page to its own frame *before* applying the
                // parallax scale — `aspectRatio(.fill)` on the image
                // overflows the LazyImage box, and without a per-page clip
                // the overflow bleeds onto the neighbouring page during a
                // horizontal drag (you see the next image creeping into
                // the active page).
                .clipped()
                // Adjacent pages render with a parallax tint *only during
                // a horizontal drag*. We don't fade them on a vertical
                // dismiss drag — neighbours stay flat behind the active
                // page so the dismiss reads as one card lifting away.
                .scaleEffect(scale(for: index, dragX: horizontalDrag, width: width))
                .opacity(opacity(for: index, dragX: horizontalDrag, width: width))
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: baseOffset)
        // No implicit animation on user-index changes — the swipe path
        // animates `horizontalDrag` explicitly and flips the index with
        // `disablesAnimations: true`. Without this, SwiftUI tries to
        // crossfade the page content during the index swap, which reads
        // as a flicker on the chrome (header/footer/progress bar) and
        // produces "Invalid sample" warnings when the implicit timeline
        // collides with our manual one.
        .animation(nil, value: state.currentUserIndex)
        .animation(nil, value: state.currentItemIndex)
        // The 50 ms playback tick observed by the chrome (progress bar)
        // can otherwise get swept into a parent transaction and cause a
        // sub-frame redraw of the LazyImage tree, which reads as a
        // flicker on every tick.
        .animation(nil, value: state.playback.progress)
    }

    /// Picks the item to render for `story`. The active page renders the
    /// user's *current* item; inactive pages render their first item so
    /// the parallax preview during the swipe is meaningful but not
    /// stateful.
    private func page(for story: Story, isActive: Bool) -> StoryItem {
        if isActive { return state.currentItem }
        return story.items.first ?? state.currentItem
    }

    // MARK: - Unified drag gesture

    /// Single drag gesture that arbitrates between horizontal user-pagination
    /// and vertical swipe-to-dismiss. The minimum distance keeps pure taps
    /// out of the drag path; axis lock fires on first engagement and is
    /// stable for the rest of the gesture — diagonal drags resolve cleanly
    /// to one axis instead of jittering between horizontal pager offset and
    /// vertical dismiss offset.
    private func unifiedDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: Self.dragMinimumDistance)
            .onChanged { value in
                if lockedAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    lockedAxis = dx >= dy ? .horizontal : .vertical
                }
                // We use `withAnimation(.linear(duration: 0))` rather than
                // `withTransaction { disablesAnimations = true }` here. They
                // sound equivalent but they aren't: `disablesAnimations`
                // only blocks *new* animations from being attached to the
                // mutation, it does *not* cancel an animation already in
                // flight on the same property. After a snap-back from a
                // previous gesture (`withAnimation(snapBack) { ... }`)
                // CoreAnimation may still be interpolating `horizontalDrag`
                // toward 0 when the next drag begins. A naked mutation then
                // produces an out-of-order sample (time 0 arriving after
                // time 0.0166s), which is exactly the "Invalid sample
                // AnimatablePair<…> with time … > last time …" warning.
                // A zero-duration animation *replaces* the in-flight
                // animation on the property and snaps to the new value on
                // the same frame — which is what we actually want.
                withAnimation(.linear(duration: 0)) {
                    switch lockedAxis {
                    case .horizontal:
                        horizontalDrag = clampedHorizontal(value.translation.width, containerWidth: containerSize.width)
                    case .vertical:
                        state.updateDrag(translationY: value.translation.height, containerHeight: containerSize.height)
                    case .none:
                        return
                    }
                }
            }
            .onEnded { value in
                defer { lockedAxis = nil }
                switch lockedAxis {
                case .horizontal:
                    endHorizontalDrag(value: value, containerWidth: containerSize.width)
                case .vertical:
                    endVerticalDrag(value: value, containerHeight: containerSize.height)
                case .none:
                    return
                }
            }
    }

    private func endHorizontalDrag(value: DragGesture.Value, containerWidth: CGFloat) {
        let projectedDelta = value.predictedEndTranslation.width - value.translation.width
        let velocityX = projectedDelta / 0.25
        let commitsForward = value.translation.width < -containerWidth * Self.userSwipeCommitFraction
            || velocityX < -Self.userSwipeVelocityThreshold
        let commitsBackward = value.translation.width > containerWidth * Self.userSwipeCommitFraction
            || velocityX > Self.userSwipeVelocityThreshold
        let snapBack: Animation = reduceMotion
            ? .linear(duration: 0)
            : .spring(response: 0.45, dampingFraction: 0.85)

        // Commit path: animate the drag to a *full-page* offset matching the
        // direction of travel, *then* swap the user index and reset the drag
        // to zero in the same transaction. Without this two-step, the index
        // flip is instantaneous (offset jumps by ±width) while `horizontalDrag`
        // is still mid-snap — the user sees a one-frame tear that reads as
        // the new page being cropped on the wrong side.
        let canGoForward = state.currentUserIndex + 1 < state.users.count
        let canGoBackward = state.currentUserIndex > 0
        if commitsForward, canGoForward {
            withAnimation(snapBack) {
                horizontalDrag = -containerWidth
            } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    state.nextUser()
                    horizontalDrag = 0
                }
            }
        } else if commitsBackward, canGoBackward {
            withAnimation(snapBack) {
                horizontalDrag = containerWidth
            } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    state.previousUser()
                    horizontalDrag = 0
                }
            }
        } else {
            // Boundary or non-committing drag: snap back to the current page
            // without changing the index. `nextUser()` at the last user
            // would dismiss; we honour that path explicitly so the animated
            // commit doesn't fight the dismiss transition.
            withAnimation(snapBack) {
                horizontalDrag = 0
            }
            if commitsForward { state.nextUser() }
        }
    }

    private func endVerticalDrag(value: DragGesture.Value, containerHeight: CGFloat) {
        guard state.dragOffset != 0 || value.translation.height != 0 else { return }
        let projectedDelta = value.predictedEndTranslation.height - value.translation.height
        let velocityY = projectedDelta / 0.25
        if state.shouldCommitDismiss(
            translationY: value.translation.height,
            velocityY: velocityY,
            containerHeight: containerHeight,
        ) {
            state.endDrag(
                translationY: value.translation.height,
                velocityY: velocityY,
                containerHeight: containerHeight,
            )
        } else {
            // Snap-back animates the released drag values; we let the
            // model reset its drag offsets and then animate the View
            // through the resulting state change.
            let snapBack: Animation = reduceMotion
                ? .linear(duration: 0)
                : .spring(response: 0.4, dampingFraction: 0.85)
            withAnimation(snapBack) {
                state.endDrag(
                    translationY: value.translation.height,
                    velocityY: velocityY,
                    containerHeight: containerHeight,
                )
            }
        }
    }

    /// Rubber-band the drag past the boundaries — we still let the user
    /// drag past the first/last user, but with a reduced 0.3x gain so
    /// the limit feels physical.
    private func clampedHorizontal(_ raw: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let atFirst = state.currentUserIndex == 0 && raw > 0
        let atLast = state.currentUserIndex == state.users.count - 1 && raw < 0
        if atFirst || atLast {
            return raw * 0.3
        }
        return raw
    }

    // MARK: - Adjacent-page parallax

    /// Adjacent pages scale from 0.96 → 1.0 as they approach the centre,
    /// matching the design spec's parallax envelope.
    private func scale(for index: Int, dragX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        let distanceFromCenter = abs(CGFloat(index - state.currentUserIndex) - dragX / -width)
        let clamped = min(distanceFromCenter, 1)
        return 1.0 - clamped * 0.04   // 1.0 → 0.96
    }

    /// Adjacent pages fade to 0.6 at full distance (design.md: incoming
    /// page rises from 0.6 → 1.0 as it centres).
    private func opacity(for index: Int, dragX: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 1 }
        let distanceFromCenter = abs(CGFloat(index - state.currentUserIndex) - dragX / -width)
        let clamped = min(Double(distanceFromCenter), 1)
        return 1.0 - clamped * 0.4   // 1.0 → 0.6
    }

}

// MARK: - Chrome

/// Header + footer + progress bar, isolated from the parent so the 50 ms
/// `playback.progress` tick redraws only the segmented bar — not the
/// username, timestamp, close button or like icon. SwiftUI propagates an
/// `@Observable` mutation up to the smallest view that reads it; reading
/// `progress` inside `ProgressBarBinding` keeps the chrome subtree
/// stable while the bar continues to fill smoothly.
private struct ViewerChrome: View {

    let user: User
    let timestamp: Date
    let itemCount: Int
    let currentItemIndex: Int
    let isLiked: Bool
    let isImmersive: Bool
    let isCurrentItemFailed: Bool
    let playback: PlaybackController
    let reduceMotion: Bool
    let onClose: () -> Void
    let onToggleLike: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header subtree: immersive opacity is applied here, scoped via
            // `.transaction(value: isImmersive)` so the fade only animates
            // when `isImmersive` itself flips. Parent transactions (the
            // user-swipe spring, the drag tick) reach this with `value`
            // unchanged → no animation attaches → no flash on the close
            // icon during tap-forward or user-swipe.
            VStack(spacing: Spacing.s) {
                ProgressBarBinding(
                    count: itemCount,
                    currentIndex: currentItemIndex,
                    playback: playback,
                )
                .padding(.horizontal, Spacing.l)
                StoryViewerHeader(
                    user: user,
                    timestamp: timestamp,
                    onClose: onClose,
                )
            }
            .padding(.top, Spacing.s)
            .opacity(isImmersive ? 0 : 1)
            .transaction(value: isImmersive) { tx in
                tx.animation = Motion.fastAnimation(reduceMotion: reduceMotion)
            }

            Spacer()

            StoryViewerFooter(isLiked: isLiked, onToggleLike: onToggleLike)
                .padding(.bottom, Spacing.s)
                .opacity(isCurrentItemFailed ? 0 : 1)
                .allowsHitTesting(!isCurrentItemFailed)
                .transaction(value: isCurrentItemFailed) { tx in
                    tx.animation = nil
                }
                .opacity(isImmersive ? 0 : 1)
                .transaction(value: isImmersive) { tx in
                    tx.animation = Motion.fastAnimation(reduceMotion: reduceMotion)
                }
        }
    }
}

// MARK: - Scrims

/// Permanent legibility scrims, rendered as a sibling subtree of the chrome
/// rather than as `.background` of the header/footer. Why split them out:
/// the chrome fades on `isImmersive` (long-press) and the footer toggles on
/// `isCurrentItemFailed`. When the scrims rode along inside the chrome they
/// inherited both transitions, producing visible scrim flicker on every
/// long-press, tap-forward, and load failure. Keeping them in their own
/// always-mounted, always-opaque subtree means no parent state change
/// diffs the gradient — the scrims are visually constant for the entire
/// viewer session.
///
/// Functional, not decorative: the design.md "no gradients" rule targets
/// the BeReal aesthetic (rings, canvas), but a legibility scrim is the same
/// primitive Instagram uses and is invisible on dark images.
private struct ViewerScrims: View {

    var body: some View {
        VStack(spacing: 0) {
            Self.topGradient
                .frame(height: Self.scrimHeight)
                .ignoresSafeArea(edges: .top)
            Spacer()
            Self.bottomGradient
                .frame(height: Self.scrimHeight)
                .ignoresSafeArea(edges: .bottom)
        }
        .allowsHitTesting(false)
    }

    // Curve choice: a three-stop gradient (dense / mid / clear) holds opacity
    // through the band where the text actually sits, then drops to zero in
    // the lower half. A two-stop linear ramp made the fall-off start
    // immediately at the top — the timestamp ended up sitting on ~30% black
    // even though the top edge was 65%, which is exactly where legibility
    // breaks against a bright sky.
    private static let scrimHeight: CGFloat = 180

    // Stored as `static let` so the gradient value is constructed exactly
    // once per process and SwiftUI never sees a fresh `LinearGradient`
    // instance on body re-evaluation.
    private static let topGradient = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0.65), location: 0.0),
            .init(color: Color.black.opacity(0.45), location: 0.5),
            .init(color: Color.black.opacity(0.0),  location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom,
    )

    private static let bottomGradient = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0.0),  location: 0.0),
            .init(color: Color.black.opacity(0.45), location: 0.5),
            .init(color: Color.black.opacity(0.65), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom,
    )
}

/// Thin wrapper that reads `playback.progress` so the Observation tracking
/// is scoped to the progress bar alone — the surrounding `ViewerChrome`
/// does not subscribe to the 50 ms tick and stays diff-stable.
private struct ProgressBarBinding: View {

    let count: Int
    let currentIndex: Int
    let playback: PlaybackController

    var body: some View {
        SegmentedProgressBar(
            count: count,
            currentIndex: currentIndex,
            progress: playback.progress,
        )
    }
}

// MARK: - Preview

private struct StoryViewerPreviewHost: View {
    @Namespace var ns
    let state: ViewerStateModel
    var body: some View {
        StoryViewerView(state: state, transitionNamespace: ns)
    }
}

#Preview("Viewer over single user") {
    let user = User(
        id: "alice",
        stableID: "alice",
        username: "alice.demo",
        avatarURL: URL(string: "https://picsum.photos/seed/alice/200/200")!,
    )
    let items = (1...3).map { i in
        StoryItem(
            id: "alice-\(i)",
            imageURL: URL(string: "https://picsum.photos/seed/alice-\(i)/1080/1920")!,
            createdAt: Date().addingTimeInterval(Double(-i) * 600),
        )
    }
    let story = Story(id: user.id, user: user, items: items)
    let state = ViewerStateModel(
        users: [story],
        startUserIndex: 0,
        stateStore: EphemeralUserStateStore(),
    )
    return StoryViewerPreviewHost(state: state)
        .preferredColorScheme(.dark)
}

