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
    @State private var loadFailed = false
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
    private static let longPressMinimumDuration: Double = 0.2

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
            // Black-flash on tap-forward fix:
            // 1. No `.id(item.id)` on the LazyImage — re-keying tears down
            //    the previous render and forces a placeholder frame even on
            //    a memory-cache hit.
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
            ZStack {
                lastImage?
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                LazyImage(url: item.imageURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        Color.surface
                    } else {
                        Color.clear
                    }
                }
                .onCompletion { result in
                    switch result {
                    case .success(let response):
                        lastImage = Image(uiImage: response.image)
                    case .failure:
                        handleLoadFailure()
                    }
                }
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
