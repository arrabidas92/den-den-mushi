import SwiftUI
import Nuke
import NukeUI

/// Avatar image with a ring around it (loading / loaded / failed). The
/// `ring` decision is owned by the ViewModel; this component handles only
/// the image fetch and an auto-retry when the network comes back.
struct StoryAvatar: View {

    let url: URL?
    let initials: String
    let ring: StoryRing.RingState
    let size: CGFloat

    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    @State private var loadFailed = false
    @State private var retryGeneration = 0

    init(url: URL?, initials: String, ring: StoryRing.RingState, size: CGFloat = 64) {
        self.url = url
        self.initials = initials
        self.ring = ring
        self.size = size
    }

    var body: some View {
        let innerDiameter = size - 2 * (StoryRing.ringGap + 2)
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
                // Same rationale as `StoryViewerPage`: NukeUI's
                // `onCompletion` captures stale state across body re-evals.
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
