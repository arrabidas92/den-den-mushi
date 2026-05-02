import Foundation
import Testing
@testable import Stories

@Suite("StoryListViewModel")
@MainActor
struct StoryListViewModelTests {

    // MARK: - Helpers

    private static func makeStories(_ count: Int) -> [Story] {
        (0..<count).map { i in
            let user = User(
                id: "u\(i)",
                stableID: "u\(i)",
                username: "user\(i)",
                avatarURL: URL(string: "https://x/avatar/\(i)")!,
            )
            let items = (0..<2).map { j in
                StoryItem(
                    id: "u\(i)-\(j)",
                    imageURL: URL(string: "https://x/story/\(i)/\(j)")!,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(i * 10 + j)),
                )
            }
            return Story(id: user.id, user: user, items: items)
        }
    }

    private static func makeVM(
        pages: [[Story]],
        store: InMemoryUserStateStore = InMemoryUserStateStore(),
    ) -> (StoryListViewModel, FakeStoryRepository, InMemoryUserStateStore) {
        let repo = FakeStoryRepository(mode: .pages(pages))
        let vm = StoryListViewModel(
            storyRepository: repo,
            userStateRepository: store,
            prefetcher: nil,
            pageSize: pages.first?.count ?? 10,
            triggerOffset: 3,
        )
        return (vm, repo, store)
    }

    // MARK: - shouldLoadMore (pure)

    @Test("returns false when content fits the container (no scroll)")
    func shouldLoadMoreNoScroll() {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(5)])
        // Even before any pages load, contentSize <= containerSize → false.
        #expect(vm.shouldLoadMore(contentOffset: 0, contentSize: 100, containerSize: 200) == false)
    }

    @Test("returns false when no pages have been loaded yet")
    func shouldLoadMoreNoPages() {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(5)])
        #expect(vm.shouldLoadMore(contentOffset: 0, contentSize: 1000, containerSize: 300) == false)
    }

    @Test("returns false at the start of a freshly loaded page")
    func shouldLoadMoreAtStart() async {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(10)])
        await vm.loadInitial()
        // 10 items, contentSize 1000 → itemExtent = 100. distanceToEnd at
        // offset 0 is 1000 - 300 = 700; trigger threshold is 3 * 100 = 300.
        #expect(vm.shouldLoadMore(contentOffset: 0, contentSize: 1000, containerSize: 300) == false)
    }

    @Test("returns true when within triggerOffset items of the end")
    func shouldLoadMoreNearEnd() async {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(10)])
        await vm.loadInitial()
        // distanceToEnd = 1000 - (599 + 300) = 101 < 300 → true.
        #expect(vm.shouldLoadMore(contentOffset: 599, contentSize: 1000, containerSize: 300) == true)
    }

    @Test("returns false exactly at the N-3 threshold boundary")
    func shouldLoadMoreAtBoundary() async {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(10)])
        await vm.loadInitial()
        // distanceToEnd = 300 == itemExtent * triggerOffset → strict less-than → false.
        #expect(vm.shouldLoadMore(contentOffset: 400, contentSize: 1000, containerSize: 300) == false)
    }

    // MARK: - loadInitial

    @Test("initial state shows no pages and no error")
    func initialState() {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(3)])
        #expect(vm.pages.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.isLoadingMore == false)
        #expect(vm.loadingError == nil)
    }

    @Test("loadInitial populates pages and clears the loading flag")
    func loadInitialPopulates() async {
        let (vm, _, _) = Self.makeVM(pages: [Self.makeStories(4)])
        await vm.loadInitial()
        #expect(vm.pages.count == 4)
        #expect(vm.isLoading == false)
        #expect(vm.loadingError == nil)
    }

    @Test("loadInitial twice does not re-fetch when already populated")
    func loadInitialIdempotent() async {
        let (vm, repo, _) = Self.makeVM(pages: [Self.makeStories(4)])
        await vm.loadInitial()
        await vm.loadInitial()
        let calls = await repo.loadCallCount
        #expect(calls == 1)
    }

    @Test("loadInitial surfaces errors and stays retryable")
    func loadInitialError() async {
        let (vm, repo, _) = Self.makeVM(pages: [Self.makeStories(4)])
        await repo.injectError(.persistenceUnavailable(underlying: NSError(domain: "x", code: 1)), forPage: 0)
        await vm.loadInitial()
        #expect(vm.pages.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.loadingError != nil)

        // Recover and retry.
        await repo.clearError(forPage: 0)
        await vm.loadInitial()
        #expect(vm.pages.count == 4)
        #expect(vm.loadingError == nil)
    }

    // MARK: - loadMoreIfNeeded

    @Test("loadMoreIfNeeded appends the next page")
    func loadMoreAppends() async {
        let p0 = Self.makeStories(3)
        let p1 = Self.makeStories(3).map { $0.withPageSuffix(1) }
        let (vm, _, _) = Self.makeVM(pages: [p0, p1])
        await vm.loadInitial()
        await vm.loadMoreIfNeeded()
        #expect(vm.pages.count == 6)
        // p1 IDs are suffixed.
        #expect(vm.pages.last?.id.hasSuffix("-p1") == true)
    }

    @Test("two concurrent loadMoreIfNeeded calls fire only one fetch")
    func loadMoreNoDoubleLoad() async {
        let p0 = Self.makeStories(3)
        let p1 = Self.makeStories(3).map { $0.withPageSuffix(1) }
        let (vm, repo, _) = Self.makeVM(pages: [p0, p1])
        await vm.loadInitial()
        let initialCalls = await repo.loadCallCount

        async let a: Void = vm.loadMoreIfNeeded()
        async let b: Void = vm.loadMoreIfNeeded()
        _ = await (a, b)

        let calls = await repo.loadCallCount
        // Exactly one extra call beyond the initial load.
        #expect(calls - initialCalls == 1)
        #expect(vm.pages.count == 6)
    }

    @Test("loadMoreIfNeeded error leaves isLoadingMore false and is retryable")
    func loadMoreErrorRetryable() async {
        let p0 = Self.makeStories(3)
        let p1 = Self.makeStories(3).map { $0.withPageSuffix(1) }
        let (vm, repo, _) = Self.makeVM(pages: [p0, p1])
        await vm.loadInitial()
        await repo.injectError(.pageOutOfRange, forPage: 1)
        await vm.loadMoreIfNeeded()
        #expect(vm.isLoadingMore == false)
        #expect(vm.loadingError != nil)
        #expect(vm.pages.count == 3)

        await repo.clearError(forPage: 1)
        await vm.loadMoreIfNeeded()
        #expect(vm.pages.count == 6)
        #expect(vm.loadingError == nil)
    }

    @Test("loadMoreIfNeeded does nothing when no initial page is loaded")
    func loadMoreBeforeInitial() async {
        let (vm, repo, _) = Self.makeVM(pages: [Self.makeStories(3)])
        await vm.loadMoreIfNeeded()
        let calls = await repo.loadCallCount
        #expect(calls == 0)
        #expect(vm.pages.isEmpty)
    }

    // MARK: - Fully-seen ring derivation

    @Test("fullySeenStoryIDs reflects the store's seen set after load")
    func fullySeenAfterLoad() async {
        let stories = Self.makeStories(2)
        let store = InMemoryUserStateStore()
        // Mark every item of story u0 as seen; leave u1 partial.
        for item in stories[0].items { await store.markSeen(itemID: item.id) }
        await store.markSeen(itemID: stories[1].items[0].id)

        let (vm, _, _) = Self.makeVM(pages: [stories], store: store)
        await vm.loadInitial()
        #expect(vm.fullySeenStoryIDs.contains("u0"))
        #expect(vm.fullySeenStoryIDs.contains("u1") == false)
    }

    @Test("refreshFullySeen updates a single story without touching others")
    func refreshSingleStory() async {
        let stories = Self.makeStories(2)
        let store = InMemoryUserStateStore()
        for item in stories[0].items { await store.markSeen(itemID: item.id) }

        let (vm, _, _) = Self.makeVM(pages: [stories], store: store)
        await vm.loadInitial()
        #expect(vm.fullySeenStoryIDs == ["u0"])

        // Now mark u1 fully seen and refresh just that story.
        for item in stories[1].items { await store.markSeen(itemID: item.id) }
        await vm.refreshFullySeen(for: stories[1])
        #expect(vm.fullySeenStoryIDs == ["u0", "u1"])
    }
}
