import SwiftUI

struct StoryViewerView: View {

    @Bindable var state: ViewerStateModel
    let transitionNamespace: Namespace.ID
    var onDismiss: ((Story) -> Void)? = nil
    var onCurrentUserChange: ((Story) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var horizontalDrag: CGFloat = 0
    @State private var lockedAxis: DragAxis?

    private static let userSwipeCommitFraction: CGFloat = 0.25
    private static let userSwipeVelocityThreshold: CGFloat = 500
    // Above 0 so a pure tap (translation == 0) never enters the drag path —
    // otherwise SwiftUI's gesture arbitration steals the tap from `ViewerTapZones`.
    private static let dragMinimumDistance: CGFloat = 10

    private enum DragAxis { case horizontal, vertical }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                pagedStack(containerSize: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(y: state.dragOffset)
                    .scaleEffect(1.0 - CGFloat(state.dragProgress) * 0.15, anchor: .top)
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
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(unifiedDragGesture(containerSize: geo.size))
        }
        .ignoresSafeArea(edges: .horizontal)
        // iOS 18 reads `sourceID` lazily at dismiss time, so binding to a `@State`
        // pinned at open does not take effect — the cover collapses to whatever
        // ID the transition was last bound to.
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
                onDismiss?(state.currentUser)
                dismiss()
            }
        }
        .onChange(of: state.currentUserIndex) { _, _ in
            Haptics.userChange()
            onCurrentUserChange?(state.currentUser)
        }
        .onDisappear {
            Task { await state.flushPendingPersistence() }
        }
    }

    // MARK: - Background

    private var background: some View {
        Color.background
            .opacity(1.0 - state.dragProgress)
            .ignoresSafeArea()
    }

    // MARK: - Paged stack

    private func pagedStack(containerSize: CGSize) -> some View {
        let width = containerSize.width
        let baseOffset = -CGFloat(state.currentUserIndex) * width + horizontalDrag
        return HStack(spacing: 0) {
            // Slot index, not story id: pagination intentionally repeats users
            // within a page, so two slots can share the same Story.id.
            ForEach(Array(state.users.enumerated()), id: \.offset) { index, story in
                StoryViewerPage(
                    state: state,
                    item: page(for: story, isActive: index == state.currentUserIndex),
                    isActive: index == state.currentUserIndex,
                )
                .frame(width: width, height: containerSize.height)
                .clipped()
                .scaleEffect(scale(for: index, dragX: horizontalDrag, width: width))
                .opacity(opacity(for: index, dragX: horizontalDrag, width: width))
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: baseOffset)
        .animation(nil, value: state.currentUserIndex)
        .animation(nil, value: state.currentItemIndex)
        .animation(nil, value: state.playback.progress)
    }

    private func page(for story: Story, isActive: Bool) -> StoryItem {
        if isActive { return state.currentItem }
        return story.items.first ?? state.currentItem
    }

    // MARK: - Unified drag gesture

    private func unifiedDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: Self.dragMinimumDistance)
            .onChanged { value in
                if lockedAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    lockedAxis = dx >= dy ? .horizontal : .vertical
                }
                // `linear(duration: 0)` rather than `disablesAnimations`: the
                // latter only blocks new animations, it does not cancel one
                // already in flight on the same property — leftover snap-back
                // interpolation collides with the next drag and produces
                // "Invalid sample" warnings.
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

        let canGoForward = state.currentUserIndex + 1 < state.users.count
        let canGoBackward = state.currentUserIndex > 0
        if commitsForward, canGoForward {
            // Two-step (animate to ±width, then swap index + reset to 0 in a
            // single transaction) so the index flip and the offset reset land
            // on the same frame — otherwise the new page is cropped on the
            // wrong side for one frame.
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

    private func clampedHorizontal(_ raw: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let atFirst = state.currentUserIndex == 0 && raw > 0
        let atLast = state.currentUserIndex == state.users.count - 1 && raw < 0
        if atFirst || atLast {
            return raw * 0.3
        }
        return raw
    }

    // MARK: - Adjacent-page parallax

    private func scale(for index: Int, dragX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        let distanceFromCenter = abs(CGFloat(index - state.currentUserIndex) - dragX / -width)
        let clamped = min(distanceFromCenter, 1)
        return 1.0 - clamped * 0.04
    }

    private func opacity(for index: Int, dragX: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 1 }
        let distanceFromCenter = abs(CGFloat(index - state.currentUserIndex) - dragX / -width)
        let clamped = min(Double(distanceFromCenter), 1)
        return 1.0 - clamped * 0.4
    }

}

// MARK: - Chrome

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
            // Scoped `.transaction(value:)` so only `isImmersive` flips animate
            // here — parent transactions (drag tick, user-swipe spring) reach
            // this with `value` unchanged and don't attach an animation.
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

// Sibling subtree of the chrome (not `.background` of header/footer): the
// chrome fades on `isImmersive` and the footer toggles on
// `isCurrentItemFailed`; if the scrims rode along they would inherit both
// transitions and flicker on every long-press, tap-forward, and load failure.
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

    private static let scrimHeight: CGFloat = 180

    // `static let` so the value is constructed once per process and SwiftUI
    // never sees a fresh `LinearGradient` instance on body re-eval.
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

// Reading `playback.progress` here scopes Observation to the bar alone —
// the surrounding chrome stays diff-stable on the 50 ms tick.
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
