import Foundation
import CoreGraphics
import Observation

/// Owns the viewer's navigation, per-item like state, seen marking, and
/// transient gesture state (immersive, drag, heart pop). Drives a
/// `PlaybackController` and reacts to its `onItemEnd` to advance.
///
/// Two design points worth re-stating:
/// - **Optimistic state flips first, persistence follows.** `isLiked` is
///   updated synchronously before the `await` on the store completes, so
///   the UI never feels laggy on a tap. The store is the source of truth
///   on cold-start, not during a session.
/// - **Seen marking is event-driven, not timer-driven.** A 1.5s task is
///   scheduled on item start; `nextItem()` (the explicit forward tap)
///   also marks seen and cancels the task. Items the user blew past in
///   <1.5s without an explicit tap forward stay unseen.
@Observable
final class ViewerStateModel: Identifiable {

    /// Per-instance identity, used by SwiftUI's `.fullScreenCover(item:)`.
    /// A fresh `ViewerStateModel` for the same user is treated as a new
    /// presentation, which is the desired behaviour.
    let id = UUID()

    // MARK: - Navigation

    private(set) var currentUserIndex: Int
    private(set) var currentItemIndex: Int = 0
    private(set) var shouldDismiss = false

    // MARK: - Per-item state

    private(set) var isLiked = false

    // MARK: - Transient gesture state

    private(set) var isImmersive = false
    private(set) var dragOffset: CGFloat = 0
    private(set) var dragProgress: Double = 0
    private(set) var pendingHeartPop: HeartPop?

    // MARK: - Collaborators

    let playback: PlaybackController
    let users: [Story]

    private let stateStore: any UserStateRepository
    private let clock: any Clock<Duration>
    private let prefetcher: ImagePrefetchHandle?
    private let seenThreshold: Duration
    private let heartPopWindow: Duration

    private var seenMarkTask: Task<Void, Never>?
    private var heartPopClearTask: Task<Void, Never>?

    // MARK: - Init

    init(
        users: [Story],
        startUserIndex: Int,
        stateStore: any UserStateRepository,
        clock: any Clock<Duration> = ContinuousClock(),
        playback: PlaybackController? = nil,
        prefetcher: ImagePrefetchHandle? = nil,
        seenThreshold: Duration = .milliseconds(1500),
        heartPopWindow: Duration = .milliseconds(800),
    ) {
        precondition(!users.isEmpty, "ViewerStateModel requires at least one user")
        precondition(users.indices.contains(startUserIndex), "startUserIndex out of range")
        self.users = users
        self.currentUserIndex = startUserIndex
        self.stateStore = stateStore
        self.clock = clock
        self.playback = playback ?? PlaybackController(clock: clock)
        self.prefetcher = prefetcher
        self.seenThreshold = seenThreshold
        self.heartPopWindow = heartPopWindow

        self.playback.onItemEnd = { [weak self] in self?.nextItem() }
    }

    // MARK: - Lifecycle

    /// Called by the View on appear. Resets playback for the start item,
    /// loads its `isLiked` state from the store, schedules the seen task,
    /// and prefetches the next image.
    func onAppear() async {
        await reloadLikedState()
        playback.start()
        onItemDidStart()
        prefetchNext()
    }

    /// Schedules the 1.5s seen task for the current item. Called from
    /// `onAppear` and from every navigation transition.
    func onItemDidStart() {
        seenMarkTask?.cancel()
        let item = currentItem
        seenMarkTask = Task { [clock, stateStore, seenThreshold] in
            do {
                try await clock.sleep(for: seenThreshold)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await stateStore.markSeen(itemID: item.id)
        }
    }

    // MARK: - Convenience accessors

    var currentUser: Story { users[currentUserIndex] }
    var currentItem: StoryItem { currentUser.items[currentItemIndex] }

    // MARK: - Navigation

    /// Tap-forward path. Marks the *current* item seen immediately
    /// (covering the power-skimmer who flicks past a user's items in
    /// under 1.5s) and cancels the pending seen task. Then advances.
    func nextItem() {
        seenMarkTask?.cancel()
        let item = currentItem
        Task { [stateStore] in await stateStore.markSeen(itemID: item.id) }

        if currentItemIndex + 1 < currentUser.items.count {
            currentItemIndex += 1
            restartForNewItem()
        } else if currentUserIndex + 1 < users.count {
            currentUserIndex += 1
            currentItemIndex = 0
            restartForNewItem()
        } else {
            dismiss()
        }
    }

    /// Tap-back path. Does not mark the current item seen — going
    /// backwards is rewinding, not skimming.
    func previousItem() {
        seenMarkTask?.cancel()
        if currentItemIndex > 0 {
            currentItemIndex -= 1
            restartForNewItem()
        } else if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = max(0, users[currentUserIndex].items.count - 1)
            restartForNewItem()
        } else {
            // Already at the very first item — just rewind playback.
            playback.start()
            onItemDidStart()
        }
    }

    /// Horizontal swipe to the next user.
    func nextUser() {
        seenMarkTask?.cancel()
        guard currentUserIndex + 1 < users.count else {
            dismiss()
            return
        }
        currentUserIndex += 1
        currentItemIndex = 0
        restartForNewItem()
    }

    /// Horizontal swipe to the previous user. Falls back to a no-op
    /// rewind on the first user (matches Instagram's edge behaviour).
    func previousUser() {
        seenMarkTask?.cancel()
        if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = 0
            restartForNewItem()
        } else {
            currentItemIndex = 0
            playback.start()
            onItemDidStart()
        }
    }

    func dismiss() {
        seenMarkTask?.cancel()
        heartPopClearTask?.cancel()
        playback.stop()
        shouldDismiss = true
    }

    /// Forces the underlying state store to flush its debounce window
    /// to disk. Called from the View's `.onDisappear` so the session's
    /// seen/like writes reach disk before the viewer is torn down — a
    /// 500 ms debounce window otherwise lets a fast dismiss outrun the
    /// next scheduled flush.
    func flushPendingPersistence() async {
        await stateStore.flushNow()
    }

    private func restartForNewItem() {
        playback.start()
        Task { await reloadLikedState() }
        onItemDidStart()
        prefetchNext()
    }

    private func reloadLikedState() async {
        let id = currentItem.id
        isLiked = await stateStore.isLiked(id)
    }

    // MARK: - Like

    /// Footer button tap. Optimistic flip, then persist. The flip is
    /// synchronous so the heart fills before the actor hop completes.
    func toggleLike() {
        let id = currentItem.id
        isLiked.toggle()
        Task { [stateStore] in
            _ = await stateStore.toggleLike(itemID: id)
        }
    }

    /// Double-tap on the image. Idempotent toward "liked": if already
    /// liked, the heart-pop overlay still fires (so the gesture always
    /// feels responsive) but the persisted state is not toggled off.
    /// A second double-tap on an unliked item never un-likes.
    func doubleTapLike(at point: CGPoint) {
        // Always re-fire the visual pop — schedule a new HeartPop every
        // call. The View binds to `pendingHeartPop` and animates each
        // distinct ID, so back-to-back double-taps yield distinct overlays.
        let pop = HeartPop(id: UUID(), location: point)
        pendingHeartPop = pop
        scheduleHeartPopClear(matching: pop.id)

        guard !isLiked else { return }
        let id = currentItem.id
        isLiked = true
        Task { [stateStore] in
            _ = await stateStore.toggleLike(itemID: id)
        }
    }

    private func scheduleHeartPopClear(matching popID: UUID) {
        heartPopClearTask?.cancel()
        heartPopClearTask = Task { [weak self, clock, heartPopWindow] in
            do {
                try await clock.sleep(for: heartPopWindow)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                if self.pendingHeartPop?.id == popID {
                    self.pendingHeartPop = nil
                }
            }
        }
    }

    // MARK: - Immersive (long-press)

    func beginImmersive() {
        isImmersive = true
        playback.pause()
    }

    func endImmersive() {
        isImmersive = false
        playback.resume()
    }

    // MARK: - Drag (swipe-down dismiss)

    /// Updates `dragOffset` and `dragProgress` from a continuous gesture.
    /// Pauses playback on the first non-zero translation; the View binds
    /// to `dragProgress` for scale + opacity. Upward translation is
    /// rubber-banded to 30% of input (matches design.md).
    func updateDrag(translationY: CGFloat, containerHeight: CGFloat) {
        if translationY != 0, !playback.isPaused, dragOffset == 0 {
            playback.pause()
        }
        let effective: CGFloat = translationY < 0 ? translationY * 0.3 : translationY
        dragOffset = effective
        let h = max(containerHeight, 1)
        dragProgress = min(1.0, max(0.0, Double(effective / h)))
    }

    /// Decides between commit (sets `shouldDismiss`) and snap-back
    /// (resets drag state and resumes playback). Both branches are
    /// pure state mutations; the View animates both.
    func endDrag(translationY: CGFloat, velocityY: CGFloat, containerHeight: CGFloat) {
        if shouldCommitDismiss(
            translationY: translationY,
            velocityY: velocityY,
            containerHeight: containerHeight,
        ) {
            dismiss()
        } else {
            dragOffset = 0
            dragProgress = 0
            playback.resume()
        }
    }

    /// Pure predicate: commit dismiss when the translation exceeds 30%
    /// of the container height OR the downward velocity exceeds 800pt/s.
    /// Matches the thresholds in `design.md`.
    func shouldCommitDismiss(
        translationY: CGFloat,
        velocityY: CGFloat,
        containerHeight: CGFloat,
    ) -> Bool {
        let h = max(containerHeight, 1)
        let translationFraction = translationY / h
        return translationFraction > 0.30 || velocityY > 800
    }

    // MARK: - Prefetch

    private func prefetchNext() {
        guard let prefetcher else { return }
        var urls: [URL] = []
        // Next item in the current user.
        if currentItemIndex + 1 < currentUser.items.count {
            urls.append(currentUser.items[currentItemIndex + 1].imageURL)
        }
        // First item of the next user.
        if currentUserIndex + 1 < users.count,
           let firstNext = users[currentUserIndex + 1].items.first {
            urls.append(firstNext.imageURL)
        }
        prefetcher.prefetch(urls)
    }
}
