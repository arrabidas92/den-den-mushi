import SwiftUI
import Nuke
import NukeUI

struct StoryViewerPage: View {

    @Bindable var state: ViewerStateModel
    let item: StoryItem
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?

    @State private var loadFailed = false
    @State private var isRetrying = false
    // Bumped on each Retry to force `LazyImage` to refetch even when the URL
    // is unchanged — NukeUI may short-circuit on its internal request identity
    // even after `ImageLoader.invalidate` purges the cache.
    @State private var retryGeneration = 0
    // Item id the page has *successfully rendered*, regardless of active
    // state. When the page later becomes active and this id matches the
    // current item, fire `markItemReady` immediately — covers the case where
    // an adjacent page's auto-retry completed in the background before the
    // swipe and `.task(id:)` had no outcome change to react to.
    @State private var loadedItemID: String?
    // Last successfully rendered image, kept across URL retargets so a cache
    // miss on the new item doesn't expose the parent's black background for
    // the duration of the disk/network fetch.
    @State private var lastImage: Image?

    private static let longPressMaxMovement: CGFloat = 8
    // Short enough that a deliberate hold reveals the image quickly, long
    // enough that any tap / swipe completes well below the threshold and
    // never even begins immersive.
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
        .gesture(immersiveGesture)
        // Fires for every page (active or not), so an adjacent page that
        // failed during the outage retries silently in the background.
        .onChange(of: networkMonitor?.isOnline ?? true) { _, isOnline in
            guard isOnline, loadFailed, !isRetrying else { return }
            retryLoad()
        }
        // Reset retry-related state when the page is reused for a different
        // item — without this `retryGeneration > 0` would leak across items
        // and force every subsequent fetch to bypass the cache.
        .onChange(of: item.id) { _, _ in
            retryGeneration = 0
            isRetrying = false
            loadFailed = false
            loadedItemID = nil
        }
        // Auto-retry-during-outage case: an adjacent page may have finished
        // its retry while we were on a different user, so by the time the
        // reader swipes onto it `.task(id:)` has no outcome change to fire.
        .onChange(of: isActive) { _, nowActive in
            guard nowActive, let id = loadedItemID, id == item.id else { return }
            state.markItemReady(itemID: id)
        }
    }

    // MARK: - Image outcome

    // Pairs item id with outcome so a stale identity from a previous item
    // can never collide with the current one.
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
        // same coordinate space rather than being mutually exclusive `if/else`
        // branches, otherwise the failure chrome flickers on Retry because
        // the failure frame is dismounted the moment `loadFailed` flips, then
        // re-mounted ms later when the retry refails.
        ZStack {
            // `lastImage` keeps the previously rendered image on screen when
            // NukeUI retargets to a new URL — on a cache miss the previous
            // image stays visible until the fetch resolves rather than
            // exposing the parent's black background.
            lastImage?
                .resizable()
                .aspectRatio(contentMode: .fill)
            // We drive seen/failed signalling from the *content closure* not
            // `.onCompletion`: NukeUI's `LazyImageView` retains the
            // `onCompletion` closure from its first `onAppear` and does not
            // propagate updates across SwiftUI body re-eval, so a closure
            // capturing `item.id` goes stale the moment the page slot is
            // reused for a different item.
            LazyImage(request: imageRequest()) { imageState in
                ZStack {
                    if let image = imageState.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .task(id: ImageOutcome.from(state: imageState, itemID: item.id)) {
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

    // LongPressGesture fires `.onEnded` only after the duration has elapsed
    // and the finger has stayed within `maximumDistance` — taps and swipes
    // both fail without ever calling `beginImmersive`. The simultaneous
    // zero-distance DragGesture is the only reliable way to detect touch-up
    // regardless of whether the long-press succeeded.
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
        // `loadFailed` is intentionally *not* cleared here — success in the
        // content closure is what dismisses the failure frame, otherwise the
        // icon + text + button flicker on every Retry.
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
