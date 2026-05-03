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

    @Test("Open user 3, view 2 of 3 items, dismiss, list ring stays partial")
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

        // 2. Open user at index 3 — `onAppear` is what the View calls
        //    in production; we invoke it directly because no View hosts
        //    this viewer in an integration test. Seen marking now waits
        //    on a `markCurrentItemReady()` signal from the View (fired
        //    when LazyImage resolves successfully) — without it, an
        //    offline open must not mark anything seen. We simulate the
        //    image-loaded path here.
        let openedStory = list.pages[3]
        guard let viewer = await list.makeViewerState(startingAt: openedStory) else {
            Issue.record("makeViewerState should resolve the index for a known story")
            return
        }
        #expect(viewer.currentUserIndex == 3)
        #expect(viewer.currentItemIndex == 0)
        await viewer.onAppear()
        viewer.markCurrentItemReady()

        // 3. Advance to item 1 — marks u3-1 seen once *its* image
        //    renders. Stop there so item 2 remains unseen for the
        //    partial-ring assertion below.
        viewer.nextItem()
        viewer.markCurrentItemReady()
        #expect(viewer.currentItemIndex == 1)
        // Allow the detached `Task { await stateStore.markSeen(...) }`
        // dispatched on item ready to reach the actor.
        for _ in 0..<8 { await Task.yield() }

        // 4. Dismiss without advancing further.
        viewer.dismiss()
        #expect(viewer.shouldDismiss == true)
        await viewer.flushPendingPersistence()

        // 5. Assert the store recorded the two viewed items only.
        #expect(await store.isSeen("u3-0") == true)
        #expect(await store.isSeen("u3-1") == true)
        #expect(await store.isSeen("u3-2") == false)

        // 6. List re-reads the store on dismiss; the ring stays partial.
        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == false)

        // 7. Cover the closing branch: marking the last item seen flips
        //    the ring to fully-seen on the next refresh.
        await store.markSeen(itemID: "u3-2")
        await list.refreshFullySeen(for: openedStory)
        #expect(list.fullySeenStoryIDs.contains(openedStory.id) == true)
    }
}
