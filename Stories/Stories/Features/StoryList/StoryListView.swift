import SwiftUI

/// Horizontal stories tray. Owns the layout but no business logic — the
/// pagination predicate lives on `StoryListViewModel.shouldLoadMore`,
/// which this View calls from `.onScrollGeometryChange`.
///
/// The `@Namespace` is exposed for the future viewer transition
/// (`.matchedTransitionSource(id:in:)` → `.navigationTransition(.zoom)`);
/// Phase 6 wires the destination side. We attach the source here now so
/// every tray cell already advertises a transition anchor.
struct StoryListView: View {

    @Bindable var viewModel: StoryListViewModel
    @Environment(\.trayDensity) private var density
    @Namespace private var transitionNamespace

    /// Optional override for tap handling (used by previews to avoid
    /// presenting a real viewer). Nil in production — the View presents
    /// `StoryViewerView` via `.fullScreenCover` itself.
    var onSelect: ((Story) -> Void)? = nil

    @State private var presentedViewerState: ViewerStateModel?
    @State private var presentedStory: Story?

    private static let skeletonCount = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: density.itemSpacing) {
                        content
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                }
                .scrollClipDisabled()
                .frame(height: StoryTrayItem.avatarSize + 2 * Spacing.m + Spacing.s + 16)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    viewModel.shouldLoadMore(
                        contentOffset: geo.contentOffset.x,
                        contentSize: geo.contentSize.width,
                        containerSize: geo.containerSize.width,
                    )
                } action: { _, nearEnd in
                    guard nearEnd else { return }
                    Task { await viewModel.loadMoreIfNeeded() }
                }
                .fullScreenCover(item: $presentedViewerState) { state in
                    StoryViewerView(
                        state: state,
                        transitionNamespace: transitionNamespace,
                        onDismiss: { currentStory in
                            // Fires *before* the cover starts closing —
                            // apply the in-session seen set synchronously
                            // so the tray's ring is already in its final
                            // state on the first frame of the matched
                            // zoom-out. The cell is already centred (the
                            // tray follows `state.currentUserIndex` via
                            // `onCurrentUserChange` below), so the
                            // zoom-out lands on a live, on-screen cell.
                            presentedStory = nil
                            viewModel.applySessionSeen(state.sessionSeenItemIDs)
                            Task { await viewModel.refreshFullySeen(for: currentStory) }
                        },
                        onCurrentUserChange: { story in
                            // The tray is hidden behind the cover, so
                            // scrolling here is invisible — but it
                            // guarantees the LazyHStack has the matching
                            // cell mounted and centred by the time the
                            // matched-zoom dismiss reads its anchor. A
                            // cell scrolled off-screen has no
                            // matchedTransitionSource, which collapses
                            // the animation onto a stale frame.
                            proxy.scrollTo(story.id, anchor: .center)
                        },
                    )
                }
            }
            Divider()
                .background(Color.surfaceElevated.opacity(0.4))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.background)
        .task {
            await viewModel.loadInitial()
        }
    }

    private func handleTap(_ story: Story) {
        if let onSelect {
            onSelect(story)
            return
        }
        // Warm the haptic engine on the *opening* tap, not on viewer
        // appearance. The zoom transition gives us ~0.3s of headroom
        // before the user can reach the like button — calling prewarm
        // from `.task` inside the viewer is racy with a fast first tap
        // and reintroduces the cold-start hang on the first like.
        Haptics.prewarm()
        Task {
            guard let state = await viewModel.makeViewerState(startingAt: story) else { return }
            presentedStory = story
            presentedViewerState = state
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.pages.isEmpty {
            ForEach(0..<Self.skeletonCount, id: \.self) { _ in
                StoryTrayItem(state: .loading, density: density)
            }
        } else if viewModel.pages.isEmpty, viewModel.loadingError != nil {
            StoryTrayItem(
                state: .failed(retry: { Task { await viewModel.loadInitial() } }),
                density: density,
            )
        } else {
            ForEach(viewModel.pages) { story in
                StoryTrayItem(
                    state: .loaded(
                        user: story.user,
                        isFullySeen: viewModel.fullySeenStoryIDs.contains(story.id),
                    ),
                    density: density,
                    onTap: { handleTap(story) },
                )
                .matchedTransitionSource(id: story.user.stableID, in: transitionNamespace)
            }
            trailingCell
        }
    }

    @ViewBuilder
    private var trailingCell: some View {
        if viewModel.isLoadingMore {
            StoryTrayItem(state: .loading, density: density)
        } else if viewModel.loadingError != nil, !viewModel.pages.isEmpty {
            StoryTrayItem(
                state: .failed(retry: { Task { await viewModel.loadMoreIfNeeded() } }),
                density: density,
            )
        }
    }
}

// MARK: - Previews

#Preview("Loaded — mixed seen state") {
    let stories = (0..<6).map { i in
        let user = User(
            id: "u\(i)",
            stableID: "u\(i)",
            username: "user\(i).demo",
            avatarURL: URL(string: "https://picsum.photos/seed/u\(i)/200/200")!,
        )
        let item = StoryItem(
            id: "u\(i)-1",
            imageURL: URL(string: "https://picsum.photos/seed/u\(i)-1/1080/1920")!,
            createdAt: Date(),
        )
        return Story(id: user.id, user: user, items: [item])
    }
    let repo = PreviewStoryRepository(pages: [stories])
    let store = EphemeralUserStateStore()
    let vm = StoryListViewModel(
        storyRepository: repo,
        userStateRepository: store,
        prefetcher: nil,
    )
    return StoryListView(viewModel: vm)
        .frame(height: 110)
        .background(Color.background)
        .preferredColorScheme(.dark)
}

#Preview("Initial loading skeleton") {
    let repo = PreviewStoryRepository(pages: [[]])
    let vm = StoryListViewModel(
        storyRepository: repo,
        userStateRepository: EphemeralUserStateStore(),
        prefetcher: nil,
    )
    // The .task hasn't fired yet in the preview canvas; flip the flag
    // manually so the skeleton row renders without any async work.
    Task { @MainActor in await vm.loadInitial() }
    return StoryListView(viewModel: vm)
        .frame(height: 110)
        .background(Color.background)
        .preferredColorScheme(.dark)
}

/// Preview-only fake. The fully featured fake (`FakeStoryRepository`,
/// with error injection and call counting) lives in the test target and
/// is therefore unavailable to app-target previews.
private actor PreviewStoryRepository: StoryRepository {

    private let pages: [[Story]]

    init(pages: [[Story]]) { self.pages = pages }

    func loadPage(_ pageIndex: Int) async throws -> [Story] {
        guard pages.indices.contains(pageIndex) else { throw StoryError.pageOutOfRange }
        return pages[pageIndex]
    }
}
