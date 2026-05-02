import SwiftUI
import NukeUI

/// One full-bleed page of the viewer — image (or failure frame), tap
/// zones, long-press immersive, double-tap heart pop. Knows about the
/// *current* item only; horizontal user navigation and swipe-down dismiss
/// live one level up in `StoryViewerView` so a single arbitrated drag
/// gesture handles both axes.
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
        ZStack {
            imageLayer

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

    // MARK: - Gestures

    /// `onPressingChanged` fires `true` once the press has held for
    /// `minimumDuration` without the finger moving more than
    /// `maximumDistance`, and fires `false` on lift-off *or* on
    /// cancellation (the finger crossed the 8pt threshold). Both branches
    /// route through `endImmersive`, so a press-cancelled-by-drag exits
    /// immersive cleanly and the parent's drag gesture takes over.
    private func handleLongPressChange(_ pressing: Bool) {
        guard isActive, !loadFailed else { return }
        if pressing {
            state.beginImmersive()
        } else if state.isImmersive {
            state.endImmersive()
        }
    }

    // MARK: - Double-tap heart pop

    private func handleDoubleTap() {
        guard isActive, !loadFailed else { return }
        Haptics.like()
        state.doubleTapLike(at: .zero)
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
