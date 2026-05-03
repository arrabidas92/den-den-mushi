import SwiftUI
import Nuke
import NukeUI

/// Avatar image with a ring around it. Three internal phases:
/// - **Loading**: pulsing ring + Surface elevated inner.
/// - **Loaded**: image fills the inner circle.
/// - **Failed**: initials glyph on Surface elevated, no haptic, no log spam.
///
/// `ring` is provided by the consumer because the seen/unseen decision lives
/// in the ViewModel — the avatar component itself is dumb. The one piece
/// of behaviour it owns is auto-retry on network return: when the monitor
/// flips back online and our last load failed, we purge Nuke's cached
/// failure and force a refetch — same pattern as `StoryViewerPage`, scaled
/// down because the avatar has no chrome to flicker.
struct StoryAvatar: View {

    let url: URL?
    let initials: String
    let ring: StoryRing.RingState
    let size: CGFloat

    /// Optional because previews and tests can render the avatar without
    /// providing a monitor. Gated on its presence — without it the avatar
    /// behaves exactly as before (initials fallback, no auto-retry).
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    @State private var loadFailed = false
    /// Bumped on each retry to vary the NukeUI request identity so the
    /// fetch is reissued even though the URL is unchanged. Mirrors the
    /// `retryGeneration` mechanism in `StoryViewerPage`.
    @State private var retryGeneration = 0

    init(url: URL?, initials: String, ring: StoryRing.RingState, size: CGFloat = 64) {
        self.url = url
        self.initials = initials
        self.ring = ring
        self.size = size
    }

    var body: some View {
        let innerDiameter = size - 2 * (StoryRing.ringGap + 2) // ring stroke ~2pt + gap
        ZStack {
            inner
                .frame(width: innerDiameter, height: innerDiameter)
                .clipShape(Circle())
            StoryRing(state: ring, size: size)
        }
        .frame(width: size, height: size)
        .onChange(of: networkMonitor?.isOnline ?? true) { _, isOnline in
            guard isOnline, loadFailed, let url else { return }
            ImageLoader.invalidate(url)
            retryGeneration += 1
        }
    }

    @ViewBuilder
    private var inner: some View {
        if let url {
            LazyImage(request: avatarRequest(for: url)) { imageState in
                ZStack {
                    if let image = imageState.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if imageState.error != nil {
                        initialsView
                    } else {
                        Color.surfaceElevated
                    }
                }
                // Outcome tracking lives in the content closure for the
                // same reason as `StoryViewerPage`: NukeUI's `onCompletion`
                // captures stale state across body re-evaluations, while
                // the content closure is re-invoked with the live
                // `LazyImageState` on every pass.
                .task(id: outcome(for: imageState)) {
                    switch outcome(for: imageState) {
                    case .loaded: loadFailed = false
                    case .failed: loadFailed = true
                    case .loading: break
                    }
                }
            }
        } else {
            initialsView
        }
    }

    private enum Outcome: Hashable { case loading, loaded, failed }

    private func outcome(for state: LazyImageState) -> Outcome {
        if state.imageContainer != nil { return .loaded }
        if state.error != nil { return .failed }
        return .loading
    }

    /// Builds the request — vanilla on first load, cache-busting on retry.
    /// Matches `StoryViewerPage.imageRequest()` so behaviour is consistent
    /// across the two places we drive Nuke directly.
    private func avatarRequest(for url: URL) -> ImageRequest {
        if retryGeneration == 0 {
            return ImageRequest(url: url)
        }
        return ImageRequest(
            url: url,
            options: [.reloadIgnoringCachedData],
            userInfo: [.imageIdKey: "\(url.absoluteString)#retry-\(retryGeneration)"],
        )
    }

    private var initialsView: some View {
        ZStack {
            Color.surfaceElevated
            Text(initials)
                .font(.usernameHeader)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

#Preview("Avatar states") {
    HStack(spacing: Spacing.l) {
        StoryAvatar(url: nil, initials: "AM", ring: .unseen, size: 64)
        StoryAvatar(url: nil, initials: "BK", ring: .seen, size: 64)
        StoryAvatar(url: nil, initials: "CR", ring: .loading, size: 64)
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
