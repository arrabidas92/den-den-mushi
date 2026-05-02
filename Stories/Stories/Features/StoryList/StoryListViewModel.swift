import Foundation
import Observation

/// Drives the horizontal stories tray. Holds the paginated list, the
/// fully-seen ring state, and the load-more trigger predicate.
///
/// MainActor isolation is inherited from the module default (see
/// `architecture.md` § *Concurrency model*); annotating it here would be
/// noise. Tests run on the MainActor for the same reason.
@Observable
final class StoryListViewModel {

    // MARK: - State

    /// Concatenation of every page loaded so far, in order. The View renders
    /// this directly; pagination appends without ever mutating earlier
    /// entries (preserves diff identity for the LazyHStack).
    private(set) var pages: [Story] = []

    /// True only during the very first `loadInitial()` call. Drives the
    /// skeleton tray. Distinct from `isLoadingMore` so the View can show
    /// different affordances (full skeleton vs. trailing skeleton cell).
    private(set) var isLoading = false

    /// True while a page > 0 is in flight. The `shouldLoadMore` flag set by
    /// the View must be ignored while this is true to avoid double-loads.
    private(set) var isLoadingMore = false

    /// Last error raised by either `loadInitial` or `loadMoreIfNeeded`.
    /// The View surfaces this in two distinct affordances:
    /// - empty pages → full-tray retry (initial failure)
    /// - non-empty pages → trailing failure cell with a retry button
    private(set) var loadingError: StoryError?

    /// Set of story IDs whose every item is in the seen-set. Recomputed
    /// after each successful page load. Membership drives the ring's
    /// seen/unseen rendering inside `StoryTrayItem`.
    private(set) var fullySeenStoryIDs: Set<String> = []

    // MARK: - Configuration

    private let pageSize: Int
    private let triggerOffset: Int
    private let storyRepository: StoryRepository
    let userStateRepository: UserStateRepository
    private let prefetcher: ImagePrefetchHandle?

    /// Tracks the next page index to fetch. Incremented only on success so
    /// a failed load can be retried by re-firing the same trigger.
    private var nextPageToLoad = 0

    // MARK: - Init

    init(
        storyRepository: StoryRepository,
        userStateRepository: UserStateRepository,
        prefetcher: ImagePrefetchHandle? = nil,
        pageSize: Int = 10,
        triggerOffset: Int = 3,
    ) {
        self.storyRepository = storyRepository
        self.userStateRepository = userStateRepository
        self.prefetcher = prefetcher
        self.pageSize = pageSize
        self.triggerOffset = triggerOffset
    }

    // MARK: - Pagination predicate

    /// Pure: true when the visible viewport is within `triggerOffset`
    /// items of the end of currently loaded content. Inputs are forwarded
    /// straight from `ScrollGeometry`; tests hit this without spinning a View.
    func shouldLoadMore(
        contentOffset: CGFloat,
        contentSize: CGFloat,
        containerSize: CGFloat,
    ) -> Bool {
        guard contentSize > containerSize else { return false }
        guard !pages.isEmpty else { return false }
        let itemExtent = contentSize / CGFloat(pages.count)
        let distanceToEnd = contentSize - (contentOffset + containerSize)
        return distanceToEnd < itemExtent * CGFloat(triggerOffset)
    }

    // MARK: - Loading

    /// Loads the first page. Subsequent calls while a load is already in
    /// flight are ignored — the existing one will complete and update state.
    func loadInitial() async {
        guard !isLoading, pages.isEmpty else { return }
        isLoading = true
        loadingError = nil
        defer { isLoading = false }

        do {
            let page = try await storyRepository.loadPage(0)
            pages = page
            nextPageToLoad = 1
            await refreshFullySeen(for: page)
            prefetchAssets(for: page)
        } catch let error as StoryError {
            loadingError = error
        } catch {
            loadingError = .persistenceUnavailable(underlying: error)
        }
    }

    /// Loads the next page. The `isLoadingMore` flag is set synchronously
    /// before the first `await`, so two concurrent calls scheduled on the
    /// MainActor cannot both reach the repository — the second observes
    /// the flag and bails.
    func loadMoreIfNeeded() async {
        guard !isLoading, !isLoadingMore else { return }
        guard !pages.isEmpty else { return }
        isLoadingMore = true
        loadingError = nil
        defer { isLoadingMore = false }

        let pageIndex = nextPageToLoad
        do {
            let page = try await storyRepository.loadPage(pageIndex)
            pages.append(contentsOf: page)
            nextPageToLoad = pageIndex + 1
            await refreshFullySeen(for: page)
            prefetchAssets(for: page)
        } catch let error as StoryError {
            loadingError = error
        } catch {
            loadingError = .persistenceUnavailable(underlying: error)
        }
    }

    /// Re-checks the seen status for the given stories and merges the
    /// result into `fullySeenStoryIDs`. Called after each successful load
    /// and exposed for the viewer to refresh the tray on dismiss.
    func refreshFullySeen(for stories: [Story]) async {
        var fullySeen: Set<String> = []
        for story in stories {
            var allSeen = !story.items.isEmpty
            for item in story.items {
                if await userStateRepository.isSeen(item.id) == false {
                    allSeen = false
                    break
                }
            }
            if allSeen { fullySeen.insert(story.id) }
        }
        // Merge: keep prior decisions for stories not in this batch,
        // overwrite for those that are.
        let touched = Set(stories.map(\.id))
        fullySeenStoryIDs = fullySeenStoryIDs.subtracting(touched).union(fullySeen)
    }

    /// Convenience for callers (e.g. the viewer dismiss path) that hold a
    /// `Story` reference and want to refresh that single ring without
    /// passing the whole array.
    func refreshFullySeen(for story: Story) async {
        await refreshFullySeen(for: [story])
    }

    /// Synchronously merges an in-memory set of seen item IDs into the
    /// fully-seen ring decision. Used by the viewer dismiss path so the
    /// ring flips from unseen to seen the instant the cover dismisses,
    /// without waiting on the persistence flush race.
    func applySessionSeen(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var newlyFullySeen: Set<String> = []
        for story in pages where !fullySeenStoryIDs.contains(story.id) {
            let allSeen = !story.items.isEmpty
                && story.items.allSatisfy { ids.contains($0.id) || fullySeenStoryIDs.contains(story.id) }
            // The `fullySeenStoryIDs.contains` short-circuit above is a
            // safeguard if a partial in-session seen-set is merged twice.
            if allSeen {
                newlyFullySeen.insert(story.id)
            }
        }
        if !newlyFullySeen.isEmpty {
            fullySeenStoryIDs.formUnion(newlyFullySeen)
        }
    }

    /// Builds a viewer state model anchored at the given story. The
    /// viewer paginates over *all* loaded users so a horizontal swipe
    /// crosses page boundaries seamlessly.
    ///
    /// Resume rule: if some items are unseen, start at the first unseen
    /// item; if every item is already seen, start at the first item
    /// (Instagram parity — re-watching from the start, not the last seen).
    func makeViewerState(startingAt story: Story) async -> ViewerStateModel? {
        guard let index = pages.firstIndex(where: { $0.id == story.id }) else { return nil }
        let resumeIndex = await firstUnseenIndex(in: story) ?? 0
        return ViewerStateModel(
            users: pages,
            startUserIndex: index,
            startItemIndex: resumeIndex,
            stateStore: userStateRepository,
        )
    }

    /// Returns the index of the first unseen item in `story`, or `nil`
    /// when every item is already seen.
    private func firstUnseenIndex(in story: Story) async -> Int? {
        for (index, item) in story.items.enumerated() {
            if await userStateRepository.isSeen(item.id) == false {
                return index
            }
        }
        return nil
    }

    // MARK: - Prefetch

    private func prefetchAssets(for stories: [Story]) {
        guard let prefetcher else { return }
        var urls: [URL] = []
        urls.reserveCapacity(stories.count * 2)
        for story in stories {
            urls.append(story.user.avatarURL)
            if let firstItem = story.items.first {
                urls.append(firstItem.imageURL)
            }
        }
        prefetcher.prefetch(urls)
    }
}
