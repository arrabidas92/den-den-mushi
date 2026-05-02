import SwiftUI

/// Modal viewer presented over the tray. Owns the chrome (header, footer,
/// progress bar), the user-pagination drag, the scenePhase pause hook,
/// and the swipe-down dismiss visual envelope (background fade). Per-page
/// behaviour (image, tap zones, long-press, double-tap, vertical drag)
/// lives in `StoryViewerPage`.
///
/// The View owns *no* business logic — every state mutation routes
/// through `ViewerStateModel`. The thresholds and indices for the
/// horizontal-swipe commit are local UI state because they describe an
/// in-flight drag, not durable state.
struct StoryViewerView: View {

    @Bindable var state: ViewerStateModel
    /// Source-side namespace from the tray. Used by
    /// `.navigationTransition(.zoom(sourceID:in:))` so the avatar morphs
    /// into the viewer header on present.
    let transitionNamespace: Namespace.ID
    /// Fired after `.onDisappear` so the parent (StoryListView) can
    /// refresh the rings of users whose seen state changed during the
    /// session. The closure is `Sendable`-friendly (no captured Views).
    var onDismiss: (() -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Live horizontal drag offset for the user-pagination swipe. Local
    /// to the View — once committed, it animates back to 0 and the
    /// `currentUserIndex` on the model has advanced.
    @State private var horizontalDrag: CGFloat = 0
    /// Lock the dominant axis at first engagement so a near-diagonal drag
    /// is unambiguous. `nil` until the first 12pt of translation, then
    /// pinned for the rest of the gesture.
    @State private var lockedAxis: DragAxis?

    /// Translation past which the user-pagination swipe commits to the
    /// next/previous user (a quarter of the container width).
    private static let userSwipeCommitFraction: CGFloat = 0.25
    private static let userSwipeVelocityThreshold: CGFloat = 500
    private static let axisLockTranslation: CGFloat = 12

    private enum DragAxis { case horizontal, vertical }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                pagedStack(containerSize: geo.size)
                    .gesture(horizontalDragGesture(containerWidth: geo.size.width))
                chrome
                    .opacity(state.isImmersive ? 0 : 1)
                    .animation(Motion.fastAnimation(reduceMotion: reduceMotion), value: state.isImmersive)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.background.opacity(1.0 - state.dragProgress))
        .ignoresSafeArea(edges: .horizontal)
        .navigationTransition(.zoom(sourceID: state.currentUser.user.stableID, in: transitionNamespace))
        .task { await state.onAppear() }
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
                dismiss()
            }
        }
        .onChange(of: state.currentUserIndex) { _, _ in
            Haptics.userChange()
        }
        .onDisappear {
            // Flush persistence on the way out so seen/like for the last
            // session reach disk before the user backgrounds the app.
            // fire-and-forget — the View is being torn down.
            Task { await state.flushPendingPersistence() }
            onDismiss?()
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
            ForEach(Array(state.users.enumerated()), id: \.element.id) { index, story in
                StoryViewerPage(
                    state: state,
                    item: page(for: story, isActive: index == state.currentUserIndex),
                    isActive: index == state.currentUserIndex,
                )
                .frame(width: width, height: containerSize.height)
                .scaleEffect(scale(for: index, dragX: horizontalDrag, width: width))
                .opacity(opacity(for: index, dragX: horizontalDrag, width: width))
                .offset(y: index == state.currentUserIndex ? state.dragOffset : 0)
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: baseOffset)
        .scaleEffect(1.0 - CGFloat(state.dragProgress) * 0.15)
    }

    /// Picks the item to render for `story`. The active page renders the
    /// user's *current* item; inactive pages render their first item so
    /// the parallax preview during the swipe is meaningful but not
    /// stateful.
    private func page(for story: Story, isActive: Bool) -> StoryItem {
        if isActive { return state.currentItem }
        return story.items.first ?? state.currentItem
    }

    // MARK: - Horizontal drag gesture (user pagination)

    private func horizontalDragGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if lockedAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard max(dx, dy) >= Self.axisLockTranslation else { return }
                    lockedAxis = dx >= dy ? .horizontal : .vertical
                }
                guard lockedAxis == .horizontal else { return }
                horizontalDrag = clampedHorizontal(value.translation.width, containerWidth: containerWidth)
            }
            .onEnded { value in
                defer { lockedAxis = nil }
                guard lockedAxis == .horizontal else { return }
                let projectedDelta = value.predictedEndTranslation.width - value.translation.width
                let velocityX = projectedDelta / 0.25
                let commitsForward = value.translation.width < -containerWidth * Self.userSwipeCommitFraction
                    || velocityX < -Self.userSwipeVelocityThreshold
                let commitsBackward = value.translation.width > containerWidth * Self.userSwipeCommitFraction
                    || velocityX > Self.userSwipeVelocityThreshold
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    horizontalDrag = 0
                }
                if commitsForward {
                    state.nextUser()
                } else if commitsBackward {
                    state.previousUser()
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

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.s) {
                SegmentedProgressBar(
                    count: state.currentUser.items.count,
                    currentIndex: state.currentItemIndex,
                    progress: state.playback.progress,
                )
                .padding(.horizontal, Spacing.l)
                StoryViewerHeader(
                    user: state.currentUser.user,
                    timestamp: state.currentItem.createdAt,
                    onClose: state.dismiss,
                )
            }
            .padding(.top, Spacing.s)
            Spacer()
            StoryViewerFooter(isLiked: state.isLiked, onToggleLike: state.toggleLike)
                .padding(.bottom, Spacing.s)
        }
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

