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

    // MARK: - Seen rule (1.5s)

    @Test("seen task does NOT mark seen when dwell is under 1.5s and user dismisses")
    func seenSubThresholdNoMark() async {
        let users = Self.makeUsers([2])
        let (model, store, clock) = Self.makeModel(users: users)
        await model.onAppear()
        // Simulate the user staring for under 1.5s, then dismiss.
        await clock.advance(by: .milliseconds(1400))
        model.dismiss()
        // Even if the seenMark task fires later, it has been cancelled.
        await clock.advance(by: .milliseconds(500))
        let seenCount = await store.markSeenCallCount
        #expect(seenCount == 0)
    }

    @Test("seen task marks seen at exactly 1.5s")
    func seenAtThresholdMarks() async {
        let users = Self.makeUsers([2])
        let (model, store, clock) = Self.makeModel(users: users)
        await model.onAppear()
        await clock.advance(by: .milliseconds(1500))
        let seen = await store.isSeen("u0-0")
        #expect(seen)
    }

    @Test("seen task marks seen at 3s (well past threshold)")
    func seenWellPastThreshold() async {
        let users = Self.makeUsers([2])
        let (model, store, clock) = Self.makeModel(users: users)
        await model.onAppear()
        await clock.advance(by: .seconds(3))
        let seen = await store.isSeen("u0-0")
        #expect(seen)
    }

    @Test("explicit nextItem before 1.5s still marks the previous item seen")
    func tapForwardMarksSeen() async {
        let users = Self.makeUsers([2])
        let (model, store, clock) = Self.makeModel(users: users)
        await model.onAppear()
        await clock.advance(by: .milliseconds(500))
        model.nextItem()
        // Allow the detached `Task { await store.markSeen(...) }` to drain.
        await clock.advance(by: .milliseconds(50))
        for _ in 0..<8 { await Task.yield() }
        let seen = await store.isSeen("u0-0")
        #expect(seen)
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

    @Test("doubleTapLike sets liked, fires heart pop")
    func doubleTapLikeSetsLiked() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
        model.doubleTapLike(at: CGPoint(x: 100, y: 200))
        #expect(model.isLiked == true)
        #expect(model.pendingHeartPop != nil)
        #expect(model.pendingHeartPop?.location == CGPoint(x: 100, y: 200))
    }

    @Test("doubleTapLike on an already-liked item stays liked, refires the pop")
    func doubleTapLikeIdempotent() async {
        let users = Self.makeUsers([1])
        let (model, store, _) = Self.makeModel(users: users)
        await model.onAppear()

        model.doubleTapLike(at: CGPoint(x: 100, y: 200))
        for _ in 0..<8 { await Task.yield() }
        let firstID = model.pendingHeartPop?.id

        // Second double-tap on a liked item: stays liked, distinct pop.
        model.doubleTapLike(at: CGPoint(x: 50, y: 100))
        #expect(model.isLiked == true)
        #expect(model.pendingHeartPop?.id != firstID)

        // Persistence: only the first call ever toggled.
        let toggleCount = await store.toggleLikeCallCount
        #expect(toggleCount == 1)
    }

    @Test("pendingHeartPop is cleared after the animation window")
    func heartPopClearsAfterWindow() async {
        let users = Self.makeUsers([1])
        let (model, _, clock) = Self.makeModel(users: users)
        await model.onAppear()
        model.doubleTapLike(at: .zero)
        #expect(model.pendingHeartPop != nil)
        await clock.advance(by: .milliseconds(800))
        // The clear hops to MainActor inside the task; drain.
        for _ in 0..<16 { await Task.yield() }
        #expect(model.pendingHeartPop == nil)
    }

    // MARK: - Immersive

    @Test("beginImmersive pauses playback; endImmersive resumes")
    func immersiveLockstep() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
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
        model.updateDrag(translationY: 400, containerHeight: 800)
        model.endDrag(translationY: 400, velocityY: 0, containerHeight: 800)
        #expect(model.shouldDismiss == true)
    }

    @Test("upward drag is rubber-banded to 30% of input")
    func upwardRubberBand() async {
        let users = Self.makeUsers([1])
        let (model, _, _) = Self.makeModel(users: users)
        await model.onAppear()
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
        // 5s item, 100ms tick → reaching 1.0 needs 5s.
        await clock.advance(by: .milliseconds(5100))
        #expect(model.currentItemIndex == 1)
    }
}
