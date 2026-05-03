import Foundation
import Testing
@testable import Stories

/// End-to-end VM scenario: load list → open user 3 → view 2 items →
/// dismiss → assert seen state. The contract under test is that the list
/// and viewer agree on the persistence boundary.
@Suite("StoryFlow integration", .serialized)
@MainActor
struct StoryFlowIntegrationTests {

    private static func makeStories() -> [Story] {
        (0..<5).map { i in
            let user = User(
                id: "u\(i)",
                stableID: "u\(i)",
                username: "user\(i)",
                avatarURL: URL(string: "https://x/avatar/\(i)")!,
            )
            let items = (0..<3).map { j in
                StoryItem(
                    id: "u\(i)-\(j)",
                    imageURL: URL(string: "https://x/story/\(i)/\(j)")!,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(i * 100 + j)),
                )
            }
            return Story(id: user.id, user: user, items: items)
        }
    }

    @Test("Open user 3, view 2 of 3 items, dismiss, list ring stays partial")
    func openViewTwoItemsDismissAssertSeen() async {
        let stories = Self.makeStories()
        let repo = FakeStoryRepository(mode: .pages([stories]))
        let store = InMemoryUserStateStore()

        let list = StoryListViewModel(
            storyRepository: repo,
            userStateRepository: store,
            prefetcher: nil,
        )
        await list.loadInitial()
        #expect(list.pages.count == 5)
        #expect(list.fullySeenStoryIDs.isEmpty)

        let openedStory = list.pages[3]
        guard let viewer = await list.makeViewerState(startingAt: openedStory) else {
            Issue.record("makeViewerState should resolve the index for a known story")
            return
        }
        #expect(viewer.currentUserIndex == 3)
        #expect(viewer.currentItemIndex == 0)
        await viewer.onAppear()
        viewer.markCurrentItemReady()

        viewer.nextItem()
        viewer.markCurrentItemReady()
        #expect(viewer.currentItemIndex == 1)
        for _ in 0..<8 { await Task.yield() }

        viewer.dismiss()
        #expect(viewer.shouldDismiss == true)
        await viewer.flushPendingPersistence()

        #expect(await store.isSeen("u3-0") == true)
        #expect(await store.isSeen("u3-1") == true)
        #expect(await store.isSeen("u3-2") == false)

        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == false)

        await store.markSeen(itemID: "u3-2")
        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == true)
    }
}
