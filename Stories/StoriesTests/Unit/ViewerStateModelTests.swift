import Foundation
import CoreGraphics
import Testing
@testable import Stories

@Suite("ViewerStateModel", .serialized)
@MainActor
struct ViewerStateModelTests {

    // MARK: - Fixtures

    private static func makeUsers(_ counts: [Int]) -> [Story] {
        counts.enumerated().map { (i, itemCount) in
            let user = User(
                id: "u\(i)",
                stableID: "u\(i)",
                username: "user\(i)",
                avatarURL: URL(string: "https://x/avatar/\(i)")!,
            )
            let items = (0..<itemCount).map { j in
                StoryItem(
                    id: "u\(i)-\(j)",
                    imageURL: URL(string: "https://x/story/\(i)/\(j)")!,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(i * 100 + j)),
                )
            }
            return Story(id: user.id, user: user, items: items)
        }
    }

    private static func makeModel(
        users: [Story],
        startUserIndex: Int = 0,
        store: InMemoryUserStateStore = InMemoryUserStateStore(),
        clock: TestClock = TestClock(),
    ) -> (ViewerStateModel, InMemoryUserStateStore, TestClock) {
        let model = ViewerStateModel(
            users: users,
            startUserIndex: startUserIndex,
            stateStore: store,
            clock: clock,
            playback: PlaybackController(clock: clock, itemDuration: .seconds(5), tickInterval: .milliseconds(100)),
            prefetcher: nil,
        )
        return (model, store, clock)
    }

    // MARK: - Navigation

    @Test("nextItem advances within a user")
    func nextItemWithinUser() {
        let users = Self.makeUsers([3, 2])
        let (model, _, _) = Self.makeModel(users: users)
        #expect(model.currentItemIndex == 0)
        model.nextItem()
        #expect(model.currentUserIndex == 0)
        #expect(model.currentItemIndex == 1)
    }

    @Test("nextItem at end of user advances to the next user, item 0")
    func nextItemCrossesUser() {
        let users = Self.makeUsers([2, 3])
        let (model, _, _) = Self.makeModel(users: users)
        model.nextItem()        // 0,1
        model.nextItem()        // 1,0
        #expect(model.currentUserIndex == 1)
        #expect(model.currentItemIndex == 0)
    }

    @Test("nextItem at end of last user dismisses")
    func nextItemDismissesAtEnd() {
        let users = Self.makeUsers([2])
        let (model, _, _) = Self.makeModel(users: users)
        model.nextItem()        // 0,1
        model.nextItem()        // dismiss
        #expect(model.shouldDismiss)
    }

    @Test("previousItem rewinds within a user")
    func previousItemWithinUser() {
        let users = Self.makeUsers([3])
        let (model, _, _) = Self.makeModel(users: users)
        model.nextItem()
        model.nextItem()
        #expect(model.currentItemIndex == 2)
        model.previousItem()
        #expect(model.currentItemIndex == 1)
    }

    @Test("previousItem at item 0 rewinds to previous user's last item")
    func previousItemCrossesUserBackward() {
        let users = Self.makeUsers([2, 3])
        let (model, _, _) = Self.makeModel(users: users, startUserIndex: 1)
        #expect(model.currentItemIndex == 0)
        model.previousItem()
        #expect(model.currentUserIndex == 0)
        #expect(model.currentItemIndex == 1)   // user 0 has 2 items → last = 1
    }

    @Test("previousItem at the very first item is a no-op rewind, not dismiss")
    func previousItemAtBoundaryNoDismiss() {
        let users = Self.makeUsers([2])
        let (model, _, _) = Self.makeModel(users: users)
        model.previousItem()
        #expect(model.shouldDismiss == false)
        #expect(model.currentUserIndex == 0)
        #expect(model.currentItemIndex == 0)
    }

    @Test("nextUser jumps to the next user, item 0")
    func nextUser() {
        let users = Self.makeUsers([3, 2])
        let (model, _, _) = Self.makeModel(users: users)
        model.nextItem()
        model.nextUser()
        #expect(model.currentUserIndex == 1)
        #expect(model.currentItemIndex == 0)
    }

    @Test("nextUser at the last user dismisses")
    func nextUserDismissesAtEnd() {
        let users = Self.makeUsers([2, 2])
        let (model, _, _) = Self.makeModel(users: users, startUserIndex: 1)
        model.nextUser()
        #expect(model.shouldDismiss)
    }

    @Test("previousUser jumps to the previous user, item 0")
    func previousUser() {
        let users = Self.makeUsers([2, 3, 1])
        let (model, _, _) = Self.makeModel(users: users, startUserIndex: 2)
        model.previousUser()
        #expect(model.currentUserIndex == 1)
        #expect(model.currentItemIndex == 0)
    }

    // MARK: - End-of-loaded-list pagination

    @Test("nextItem at end fetches more users via loadMoreUsers and advances instead of dismissing")
    func nextItemPaginatesBeforeDismiss() async {
        let users = Self.makeUsers([1])
        let extras = Self.makeUsers([2]).map { story -> Story in
            // Rename the appended user so we can assert we landed on it.
            let newUser = User(
                id: "extra",
                stableID: "extra",
                username: "extra",
                avatarURL: story.user.avatarURL,
            )
            return Story(id: "extra", user: newUser, items: story.items)
        }
        let store = InMemoryUserStateStore()
        let clock = TestClock()
        let model = ViewerStateModel(
            users: users,
            startUserIndex: 0,
            stateStore: store,
            clock: clock,
            playback: PlaybackController(clock: clock, itemDuration: .seconds(5), tickInterval: .milliseconds(100)),
            prefetcher: nil,
            loadMoreUsers: { extras },
        )
        model.nextItem()                          // would dismiss without the hook
        for _ in 0..<8 { await Task.yield() }
        #expect(model.shouldDismiss == false)
        #expect(model.users.count == 2)
        #expect(model.currentUserIndex == 1)
        #expect(model.currentItemIndex == 0)
        #expect(model.currentUser.id == "extra")
    }

    @Test("nextItem at end dismisses when loadMoreUsers returns no users")
    func nextItemDismissesWhenNoMore() async {
        let users = Self.makeUsers([1])
        let store = InMemoryUserStateStore()
        let clock = TestClock()
        let model = ViewerStateModel(
            users: users,
            startUserIndex: 0,
            stateStore: store,
            clock: clock,
            playback: PlaybackController(clock: clock, itemDuration: .seconds(5), tickInterval: .milliseconds(100)),
            prefetcher: nil,
            loadMoreUsers: { [] },
        )
        model.nextItem()
        for _ in 0..<8 { await Task.yield() }
        #expect(model.shouldDismiss)
    }

    @Test("nextUser at end fetches more users via loadMoreUsers and advances instead of dismissing")
    func nextUserPaginatesBeforeDismiss() async {
        let users = Self.makeUsers([2])
        let extras = Self.makeUsers([1])
        let store = InMemoryUserStateStore()
        let clock = TestClock()
        let model = ViewerStateModel(
            users: users,
            startUserIndex: 0,
            stateStore: store,
            clock: clock,
            playback: PlaybackController(clock: clock, itemDuration: .seconds(5), tickInterval: .milliseconds(100)),
            prefetcher: nil,
            loadMoreUsers: { extras },
        )
        model.nextUser()
        for _ in 0..<8 { await Task.yield() }
        #expect(model.shouldDismiss == false)
        #expect(model.users.count == 2)
        #expect(model.currentUserIndex == 1)
        #expect(model.currentItemIndex == 0)
    }

    // MARK: - Seen marking (immediate on item start)

    @Test("a story whose image renders is marked seen immediately")
    func seenOnImageReady() async {
        let users = Self.makeUsers([2])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        for _ in 0..<8 { await Task.yield() }
        let seen = await store.isSeen("u0-0")
        #expect(seen)
    }

    @Test("ready signal exposes the seen item via sessionSeenItemIDs synchronously")
    func sessionSeenSynchronous() async {
        let users = Self.makeUsers([2])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        // Synchronous: no actor hop required to see the in-session set.
        #expect(model.sessionSeenItemIDs.contains("u0-0"))
    }

    @Test("nextItem marks the new item seen once its image is ready, not just the previous one")
    func nextItemMarksNewItem() async {
        let users = Self.makeUsers([3])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        model.nextItem()
        model.markCurrentItemReady()
        for _ in 0..<8 { await Task.yield() }
        #expect(await store.isSeen("u0-0"))
        #expect(await store.isSeen("u0-1"))
        #expect(model.sessionSeenItemIDs.contains("u0-1"))
    }

    // MARK: - Offline / image-load gating
    //
    // Bug: in airplane mode the playback timer used to start on `onAppear`,
    // and `onItemDidStart` synchronously inserted the item into the seen
    // set + persisted it. The story ring would flip to "fully seen" without
    // the user ever seeing pixels. The gating contract: nothing happens
    // until the View signals `markCurrentItemReady()` (i.e. the LazyImage
    // resolved with `.success`).

    @Test("without ready signal, no item is marked seen")
    func offlineDoesNotMarkSeen() async {
        let users = Self.makeUsers([3])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        for _ in 0..<8 { await Task.yield() }
        #expect(model.sessionSeenItemIDs.isEmpty)
        #expect(await store.isSeen("u0-0") == false)
    }

    @Test("without ready signal, the playback timer does not advance")
    func offlineTimerDoesNotTick() async {
        let users = Self.makeUsers([2])
        let (model, _, clock) = Self.makeModel(users: users)
        await model.onAppear()
        // Plenty of time for a 5s item — but the timer was never armed.
        await clock.advance(by: .milliseconds(10_000))
        #expect(model.playback.progress == 0)
        #expect(model.currentItemIndex == 0)
        #expect(model.shouldDismiss == false)
    }

    @Test("ready signal is idempotent per item")
    func readySignalIdempotent() async {
        let users = Self.makeUsers([1])
        let (model, _, clock) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        await clock.advance(by: .milliseconds(200))
        let snapshot = model.playback.progress
        // A second ready call (e.g. NukeUI re-firing onCompletion on a
        // refresh) must not restart the timer — that would reset progress
        // to 0 and re-mark the item seen.
        model.markCurrentItemReady()
        await clock.advance(by: .milliseconds(100))
        #expect(model.playback.progress > snapshot)
    }

    @Test("a new item armed for ready resets the per-item latch")
    func readyLatchResetsAcrossItems() async {
        let users = Self.makeUsers([2])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        model.nextItem()
        // Without firing ready for u0-1, it must stay unseen even though
        // u0-0 was successfully marked.
        for _ in 0..<8 { await Task.yield() }
        #expect(await store.isSeen("u0-0"))
        #expect(await store.isSeen("u0-1") == false)
    }

    // MARK: - Image-load failure

    @Test("markCurrentItemFailed flips isCurrentItemFailed and pauses playback")
    func failureFlipsFlagAndPauses() async {
        let users = Self.makeUsers([2])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        #expect(model.playback.isPaused == false)
        model.markCurrentItemFailed()
        #expect(model.isCurrentItemFailed == true)
        #expect(model.playback.isPaused == true)
    }

    @Test("retryCurrentItem keeps isCurrentItemFailed true — footer must not flash visible during refetch")
    func retryKeepsFailureUntilConfirmedRender() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemFailed()
        #expect(model.isCurrentItemFailed == true)
        model.retryCurrentItem()
        // Stays true: clearing on Retry would let the footer flash on screen,
        // then disappear again if the refetch refails.
        #expect(model.isCurrentItemFailed == true)
    }

    @Test("a successful render after a failure clears isCurrentItemFailed")
    func successAfterFailureClearsFlag() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemFailed()
        model.retryCurrentItem()
        model.markCurrentItemReady()
        #expect(model.isCurrentItemFailed == false)
    }

    @Test("navigating to a new item resets isCurrentItemFailed")
    func failureResetsOnNextItem() async {
        let users = Self.makeUsers([2])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemFailed()
        #expect(model.isCurrentItemFailed == true)
        model.nextItem()
        #expect(model.isCurrentItemFailed == false)
    }

    @Test("navigating to a new user resets isCurrentItemFailed")
    func failureResetsOnNextUser() async {
        let users = Self.makeUsers([2, 2])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemFailed()
        model.nextUser()
        #expect(model.isCurrentItemFailed == false)
    }

    // MARK: - Like

    @Test("toggleLike flips state synchronously, before persistence completes")
    func toggleLikeOptimistic() async {
        let users = Self.makeUsers([1])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        #expect(model.isLiked == false)
        model.toggleLike()
        // Synchronous flip — no `await` between the call and this assertion.
        #expect(model.isLiked == true)
        // Persistence eventually catches up.
        for _ in 0..<8 { await Task.yield() }
        let storedLike = await store.isLiked("u0-0")
        #expect(storedLike)
    }

    @Test("toggleLike a second time un-likes")
    func toggleLikeUntoggles() async {
        let users = Self.makeUsers([1])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.toggleLike()
        for _ in 0..<8 { await Task.yield() }
        model.toggleLike()
        for _ in 0..<8 { await Task.yield() }
        #expect(model.isLiked == false)
        let storedLike = await store.isLiked("u0-0")
        #expect(storedLike == false)
    }

    // MARK: - Immersive

    @Test("beginImmersive pauses playback; endImmersive resumes")
    func immersiveLockstep() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        #expect(model.playback.isPaused == false)
        model.beginImmersive()
        #expect(model.isImmersive == true)
        #expect(model.playback.isPaused == true)
        model.endImmersive()
        #expect(model.isImmersive == false)
        #expect(model.playback.isPaused == false)
    }

    // MARK: - Drag / dismiss

    @Test("shouldCommitDismiss is true past the 30% translation threshold")
    func commitOnTranslation() {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        // 240/800 = 0.30 → strict `>` boundary → false.
        #expect(model.shouldCommitDismiss(translationY: 240, velocityY: 0, containerHeight: 800) == false)
        // 245/800 = 0.30625 → past threshold → true.
        #expect(model.shouldCommitDismiss(translationY: 245, velocityY: 0, containerHeight: 800) == true)
        // 400/800 = 0.50 → way past threshold → true.
        #expect(model.shouldCommitDismiss(translationY: 400, velocityY: 0, containerHeight: 800) == true)
    }

    @Test("shouldCommitDismiss is true past the 800pt/s velocity threshold")
    func commitOnVelocity() {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        #expect(model.shouldCommitDismiss(translationY: 50, velocityY: 800, containerHeight: 800) == false)
        #expect(model.shouldCommitDismiss(translationY: 50, velocityY: 801, containerHeight: 800) == true)
    }

    @Test("shouldCommitDismiss is false for an upward (negative) drag")
    func noCommitOnUpward() {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        #expect(model.shouldCommitDismiss(translationY: -500, velocityY: -2000, containerHeight: 800) == false)
    }

    @Test("updateDrag pauses playback on first non-zero translation")
    func updateDragPauses() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        #expect(model.playback.isPaused == false)
        model.updateDrag(translationY: 10, containerHeight: 800)
        #expect(model.playback.isPaused == true)
        #expect(model.dragOffset == 10)
    }

    @Test("endDrag below threshold snaps back, resumes playback, clears drag")
    func endDragSnapBack() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        model.updateDrag(translationY: 50, containerHeight: 800)
        #expect(model.playback.isPaused == true)
        model.endDrag(translationY: 50, velocityY: 0, containerHeight: 800)
        #expect(model.dragOffset == 0)
        #expect(model.dragProgress == 0)
        #expect(model.playback.isPaused == false)
        #expect(model.shouldDismiss == false)
    }

    @Test("endDrag past threshold commits dismiss")
    func endDragCommit() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        model.updateDrag(translationY: 400, containerHeight: 800)
        model.endDrag(translationY: 400, velocityY: 0, containerHeight: 800)
        #expect(model.shouldDismiss == true)
    }

    @Test("upward drag is rubber-banded to 30% of input")
    func upwardRubberBand() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        model.updateDrag(translationY: -100, containerHeight: 800)
        #expect(abs(model.dragOffset - (-30)) < 0.001)
        // dragProgress is clamped to 0...1 for downward — upward stays at 0.
        #expect(model.dragProgress == 0)
    }

    // MARK: - onItemEnd wiring

    @Test("playback.onItemEnd advances to the next item")
    func onItemEndAdvances() async {
        let users = Self.makeUsers([2])
        let (model, _, clock) = Self.makeModel(users: users)
        await model.onAppear()
        model.markCurrentItemReady()
        // 5s item, 100ms tick → reaching 1.0 needs 5s.
        await clock.advance(by: .milliseconds(5100))
        #expect(model.currentItemIndex == 1)
    }
}
