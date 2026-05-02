import SwiftUI
import NukeUI

/// One full-bleed page of the viewer — image (or failure frame), tap
/// zones, long-press immersive, double-tap heart pop, swipe-down dismiss.
/// Knows about the *current* item only; horizontal user navigation lives
/// one level up in `StoryViewerView`.
///
/// Why everything here and not split into more components:
/// - `LazyImage` is the only place we observe load failure, so the
///   pause-on-failure path must live here.
/// - The swipe-down `DragGesture` and the long-press must arbitrate
///   against each other on the same hit-test region; splitting them
///   into sibling Views would force an axis-locking gesture proxy
///   that adds more code than the file saves.
/// - The heart-pop overlay must read its location in the same coordinate
///   space the right tap zone reports, so they share a single
///   `GeometryReader`.
struct StoryViewerPage: View {

    @Bindable var state: ViewerStateModel
    let item: StoryItem
    /// Set by `StoryViewerView` based on the user-pagination index — only
    /// the foreground page handles gestures and renders the heart-pop
    /// overlay. Adjacent (parallax-offset) pages render the image alone.
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadFailed = false
    @State private var heartPopAnimationProgress: HeartPopProgress = .hidden

    /// Empirical: a long-press whose finger has moved more than this far
    /// is no longer a press. SwiftUI's `maximumDistance` parameter handles
    /// the cancellation natively.
    private static let longPressMaxMovement: CGFloat = 8
    private static let longPressMinimumDuration: Double = 0.2
    private static let heartPopSize: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            ZStack {
                imageLayer
                    .scaleEffect(imageScale)
                    .opacity(imageOpacity)

                if isActive {
                    ViewerTapZones(
                        onPrevious: state.previousItem,
                        onNext: state.nextItem,
                        onDoubleTap: handleDoubleTap,
                    )
                    .allowsHitTesting(!loadFailed && !state.isImmersive)

                    heartPopOverlay
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: Self.longPressMinimumDuration,
                maximumDistance: Self.longPressMaxMovement,
                perform: {},
                onPressingChanged: handleLongPressChange,
            )
            .simultaneousGesture(dragGesture(containerHeight: geo.size.height))
        }
    }

    // MARK: - Image layer

    @ViewBuilder
    private var imageLayer: some View {
        if loadFailed {
            failureFrame
        } else {
            LazyImage(url: item.imageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    Color.surface
                } else {
                    Color.surface
                }
            }
            .onCompletion { result in
                if case .failure = result { handleLoadFailure() }
            }
            .clipped()
        }
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
                Button(action: retryLoad) {
                    Text("Retry")
                        .font(.body15)
                        .foregroundStyle(Color.textPrimary.opacity(0.7))
                        .frame(minWidth: 88, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry loading story")
            }
        }
    }

    // MARK: - Image transforms

    private var imageScale: CGFloat {
        // 1.0 → 0.85 with drag progress (design.md). Reduced motion still
        // tracks the drag — only the post-commit animation is collapsed.
        1.0 - CGFloat(state.dragProgress) * 0.15
    }

    private var imageOpacity: Double {
        // The page's own opacity stays at 1.0; the *background* fade lives
        // on `StoryViewerView` and is what the user perceives. Image
        // opacity is held at 1.0 so the frame keeps its weight while the
        // user is dragging.
        1.0
    }

    // MARK: - Gestures

    /// `onPressingChanged` fires `true` once the press has held for
    /// `minimumDuration` without the finger moving more than
    /// `maximumDistance`, and fires `false` on lift-off *or* on
    /// cancellation (the finger crossed the 8pt threshold). Both branches
    /// route through `endImmersive`, so a press-cancelled-by-drag exits
    /// immersive cleanly and the swipe-down `DragGesture` takes over.
    private func handleLongPressChange(_ pressing: Bool) {
        guard isActive, !loadFailed else { return }
        if pressing {
            state.beginImmersive()
        } else if state.isImmersive {
            state.endImmersive()
        }
    }

    private func dragGesture(containerHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Vertical-only — let the parent (StoryViewerView) own
                // horizontal user-pagination drag. We refuse to engage
                // until the gesture is unambiguously vertical.
                guard isActive, !loadFailed else { return }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state.updateDrag(translationY: value.translation.height, containerHeight: containerHeight)
            }
            .onEnded { value in
                guard isActive, !loadFailed else { return }
                guard state.dragOffset != 0 else { return }
                // SwiftUI's DragGesture doesn't expose velocity directly;
                // `predictedEndTranslation` is the deceleration target ~0.25s
                // out, so dividing the delta by that window approximates
                // the on-release pt/s velocity well enough for the
                // 800pt/s threshold check.
                let projectedDelta = value.predictedEndTranslation.height - value.translation.height
                let velocityY = projectedDelta / 0.25
                state.endDrag(
                    translationY: value.translation.height,
                    velocityY: velocityY,
                    containerHeight: containerHeight,
                )
            }
    }

    // MARK: - Double-tap heart pop

    private func handleDoubleTap(at location: CGPoint) {
        guard isActive, !loadFailed else { return }
        Haptics.like()
        state.doubleTapLike(at: location)
    }

    @ViewBuilder
    private var heartPopOverlay: some View {
        if let pop = state.pendingHeartPop {
            Image(systemName: "heart.fill")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.heartPopSize, height: Self.heartPopSize)
                .foregroundStyle(Color.accentLike)
                .scaleEffect(heartPopAnimationProgress.scale)
                .opacity(heartPopAnimationProgress.opacity)
                .position(pop.location)
                .allowsHitTesting(false)
                // Re-key on `pop.id` so back-to-back pops animate distinctly.
                .id(pop.id)
                .onAppear { animateHeartPop() }
        }
    }

    private func animateHeartPop() {
        guard !reduceMotion else {
            heartPopAnimationProgress = .visible
            return
        }
        heartPopAnimationProgress = .hidden
        withAnimation(Motion.heartPopSpring) {
            heartPopAnimationProgress = .peak
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(Motion.heartPopSpring) {
                heartPopAnimationProgress = .visible
            }
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeOut(duration: Motion.standard.seconds)) {
                heartPopAnimationProgress = .hidden
            }
        }
    }

    // MARK: - Failure handling

    private func handleLoadFailure() {
        guard !loadFailed else { return }
        loadFailed = true
        state.playback.pause()
    }

    private func retryLoad() {
        ImageLoader.invalidate(item.imageURL)
        loadFailed = false
        state.playback.reset()
        state.playback.resume()
    }

    // MARK: - Heart-pop animation phases

    /// Three discrete phases driven by the spring + delay sequence.
    /// Naming the phases keeps the animateHeartPop body readable.
    private enum HeartPopProgress: Equatable {
        case hidden
        case peak     // scale 1.4 + opacity 1
        case visible  // scale 1.0 + opacity 1

        var scale: CGFloat {
            switch self {
            case .hidden:  return 0
            case .peak:    return 1.4
            case .visible: return 1.0
            }
        }

        var opacity: Double {
            switch self {
            case .hidden: return 0
            case .peak, .visible: return 1
            }
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
