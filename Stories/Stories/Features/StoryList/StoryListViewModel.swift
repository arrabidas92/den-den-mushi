import Foundation
import Observation

/// Drives the horizontal stories tray. Holds the paginated list, the
/// fully-seen ring state, and the load-more trigger predicate.
@Observable
final class StoryListViewModel {

    // MARK: - State

    private(set) var pages: [Story] = []

    private(set) var isLoading = false
    private(set) var isLoadingMore = false

    /// Surfaced by the View in two affordances: empty pages → full-tray
    /// retry, non-empty pages → trailing failure cell.
    private(set) var loadingError: StoryError?

    private(set) var fullySeenStoryIDs: Set<String> = []

    /// Mirrored from the persistent store at load time. The viewer dismiss
    /// path unions this with the in-session seen-set so a story whose first
    /// items were seen in a previous session and whose last item was seen
    /// this session still flips the ring synchronously, without waiting on
    /// the debounced disk read.
    private(set) var knownSeenItemIDs: Set<String> = []

    // MARK: - Configuration

    private let pageSize: Int
    private let triggerOffset: Int
    private let storyRepository: StoryRepository
    let userStateRepository: UserStateRepository
    private let prefetcher: ImagePrefetchHandle?

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

    /// Pure: true when the viewport is within `triggerOffset` items of the
    /// end of currently loaded content. Tests hit this without spinning a View.
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

    /// `isLoadingMore` is set synchronously before the first `await` so two
    /// concurrent calls scheduled on the MainActor cannot both reach the
    /// repository.
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

    func refreshFullySeen(for stories: [Story]) async {
        var fullySeen: Set<String> = []
        var seenItems: Set<String> = []
        for story in stories {
            var allSeen = !story.items.isEmpty
            for item in story.items {
                if await userStateRepository.isSeen(item.id) {
                    seenItems.insert(item.id)
                } else {
                    allSeen = false
                }
            }
            if allSeen { fullySeen.insert(story.id) }
        }
        let touched = Set(stories.map(\.id))
        fullySeenStoryIDs = fullySeenStoryIDs.subtracting(touched).union(fullySeen)
        let touchedItemIDs = Set(stories.flatMap { $0.items.map(\.id) })
        knownSeenItemIDs = knownSeenItemIDs.subtracting(touchedItemIDs).union(seenItems)
    }

    func refreshFullySeen(for story: Story) async {
        await refreshFullySeen(for: [story])
    }

    /// Synchronously merges in-session seen item IDs into the fully-seen
    /// ring decision so the ring flips the instant the cover dismisses,
    /// without waiting on the persistence flush race.
    func applySessionSeen(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        knownSeenItemIDs.formUnion(ids)
        var newlyFullySeen: Set<String> = []
        for story in pages where !fullySeenStoryIDs.contains(story.id) {
            let allSeen = !story.items.isEmpty
                && story.items.allSatisfy { knownSeenItemIDs.contains($0.id) }
            if allSeen {
                newlyFullySeen.insert(story.id)
            }
        }
        if !newlyFullySeen.isEmpty {
            fullySeenStoryIDs.formUnion(newlyFullySeen)
        }
    }

    /// Resume rule: start at the first unseen item; if every item is already
    /// seen, restart from the first (Instagram parity).
    func makeViewerState(startingAt story: Story) async -> ViewerStateModel? {
        guard let index = pages.firstIndex(where: { $0.id == story.id }) else { return nil }
        let resumeIndex = await firstUnseenIndex(in: story) ?? 0
        return ViewerStateModel(
            users: pages,
            startUserIndex: index,
            startItemIndex: resumeIndex,
            stateStore: userStateRepository,
            loadMoreUsers: { [weak self] in
                guard let self else { return [] }
                return await self.loadMoreUsersForViewer()
            },
        )
    }

    private func loadMoreUsersForViewer() async -> [Story] {
        let beforeCount = pages.count
        await loadMoreIfNeeded()
        guard pages.count > beforeCount else { return [] }
        return Array(pages[beforeCount..<pages.count])
    }

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
