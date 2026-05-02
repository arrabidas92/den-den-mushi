import Foundation
import Testing
@testable import Stories

/// End-to-end VM scenario: load list → open user 3 → view 2 items →
/// dismiss → assert seen state. No UI; the list and viewer ViewModels
/// share an `InMemoryUserStateStore` and a `FakeStoryRepository`, so the
/// test exercises the same boundary the View layer would in production.
///
/// The contract under test isn't any single ViewModel — it's that the
/// list and viewer agree on the persistence boundary: marks made inside
/// the viewer are visible to the list when it recomputes its
/// `fullySeenStoryIDs`.
@Suite("StoryFlow integration", .serialized)
@MainActor
struct StoryFlowIntegrationTests {

    /// Builds 5 users × 3 items each. The fake repository serves all five
    /// in a single page so `loadInitial()` is enough to populate the tray.
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

    @Test("Open user 3, mark 2 items seen via tap-forward, dismiss, list reflects seen state")
    func openViewTwoItemsDismissAssertSeen() async {
        let stories = Self.makeStories()
        let repo = FakeStoryRepository(mode: .pages([stories]))
        let store = InMemoryUserStateStore()

        // 1. Load the list.
        let list = StoryListViewModel(
            storyRepository: repo,
            userStateRepository: store,
            prefetcher: nil,
        )
        await list.loadInitial()
        #expect(list.pages.count == 5)
        #expect(list.fullySeenStoryIDs.isEmpty)

        // 2. Open user at index 3.
        let openedStory = list.pages[3]
        guard let viewer = list.makeViewerState(startingAt: openedStory) else {
            Issue.record("makeViewerState should resolve the index for a known story")
            return
        }
        #expect(viewer.currentUserIndex == 3)
        #expect(viewer.currentItemIndex == 0)

        // 3. View 2 items via explicit tap-forward (the path that marks
        //    seen synchronously, no clock dependency).
        viewer.nextItem()   // item 0 -> 1, marks u3-0 seen
        viewer.nextItem()   // item 1 -> 2, marks u3-1 seen
        #expect(viewer.currentItemIndex == 2)
        // Allow the detached `Task { await stateStore.markSeen(...) }`
        // dispatched by `nextItem()` to reach the actor.
        await Task.yield()
        await Task.yield()

        // 4. Dismiss.
        viewer.dismiss()
        #expect(viewer.shouldDismiss == true)
        await viewer.flushPendingPersistence()

        // 5. Assert the store recorded both seen items.
        #expect(await store.isSeen("u3-0") == true)
        #expect(await store.isSeen("u3-1") == true)
        #expect(await store.isSeen("u3-2") == false)

        // 6. The list re-reads the store on dismiss; verify the ring
        //    state stays "not fully seen" (only 2 of 3 items viewed).
        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == false)

        // 7. Cover the closing branch: marking the last item seen flips
        //    the ring to fully-seen on the next refresh.
        await store.markSeen(itemID: "u3-2")
        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == true)
    }
}
