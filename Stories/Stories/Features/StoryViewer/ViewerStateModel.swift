import Foundation
import CoreGraphics
import Observation

/// Owns the viewer's navigation, per-item like state, seen marking, and
/// transient gesture state (immersive, drag, heart pop).
///
/// Optimistic state flips first, persistence follows: `isLiked` updates
/// synchronously before the store await completes, so the UI never feels
/// laggy on tap. The store is the source of truth on cold-start, not during
/// a session.
@Observable
final class ViewerStateModel: Identifiable {

    let id = UUID()

    // MARK: - Navigation

    private(set) var currentUserIndex: Int
    private(set) var currentItemIndex: Int = 0
    private(set) var shouldDismiss = false

    // MARK: - Per-item state

    // In-memory like state for *every item of the current user*, preloaded
    // when the user becomes active — so `isLiked` resolves synchronously on
    // tap-forward without the one-frame stale-then-correct flicker that an
    // actor hop would produce.
    private var likedItemIDsForCurrentUser: Set<String> = []

    var isLiked: Bool { likedItemIDsForCurrentUser.contains(currentItem.id) }

    // Populated synchronously in `onItemDidStart` so the list-side
    // `refreshFullySeen` can reflect new state instantly on dismiss without
    // racing the debounced disk write.
    private(set) var sessionSeenItemIDs: Set<String> = []

    // Latch so a re-entrant NukeUI completion (cache hit + later refresh)
    // does not restart the 5s timer mid-watch.
    private var readyItemID: String?

    private(set) var isCurrentItemFailed = false

    // MARK: - Transient gesture state

    private(set) var isImmersive = false
    private(set) var dragOffset: CGFloat = 0
    private(set) var dragProgress: Double = 0

    // MARK: - Collaborators

    let playback: PlaybackController
    private(set) var users: [Story]

    private let stateStore: any UserStateRepository
    private let clock: any Clock<Duration>
    private let prefetcher: ImagePrefetchHandle?
    private let loadMoreUsers: (@MainActor () async -> [Story])?
    private var isLoadingMoreUsers = false

    // MARK: - Init

    init(
        users: [Story],
        startUserIndex: Int,
        startItemIndex: Int = 0,
        stateStore: any UserStateRepository,
        clock: any Clock<Duration> = ContinuousClock(),
        playback: PlaybackController? = nil,
        prefetcher: ImagePrefetchHandle? = nil,
        loadMoreUsers: (@MainActor () async -> [Story])? = nil,
    ) {
        precondition(!users.isEmpty, "ViewerStateModel requires at least one user")
        precondition(users.indices.contains(startUserIndex), "startUserIndex out of range")
        let safeItemIndex = users[startUserIndex].items.indices.contains(startItemIndex) ? startItemIndex : 0
        self.users = users
        self.currentUserIndex = startUserIndex
        self.currentItemIndex = safeItemIndex
        self.stateStore = stateStore
        self.clock = clock
        self.playback = playback ?? PlaybackController(clock: clock)
        self.prefetcher = prefetcher
        self.loadMoreUsers = loadMoreUsers

        self.playback.onItemEnd = { [weak self] in self?.nextItem() }
    }

    // MARK: - Lifecycle

    /// Preloads the like-set and prefetches the next image, but does **not**
    /// start playback or mark the current item seen — both wait for
    /// `markItemReady`, which the View calls once the image actually renders.
    /// Offline / failed loads therefore never tick the timer and never flip
    /// the seen ring.
    func onAppear() async {
        await reloadLikedSetForCurrentUser()
        prefetchNext()
    }

    /// Called by the View when *any* page's image has finished rendering.
    /// The model arms playback only if the rendered item is the current one
    /// — adjacent pages signalling completion for their preview frame must
    /// not start the active item's timer. Routing the decision through the
    /// model with the item ID makes it work regardless of NukeUI capture
    /// staleness across body re-evaluations.
    func markItemReady(itemID: String) {
        guard itemID == currentItem.id else { return }
        guard readyItemID != itemID else { return }
        readyItemID = itemID
        // Retry path leaves `isCurrentItemFailed` true on purpose so the
        // footer doesn't flash visible during the refetch; success here is
        // what brings it back.
        isCurrentItemFailed = false
        playback.start()
        onItemDidStart()
    }

    func markCurrentItemReady() {
        markItemReady(itemID: currentItem.id)
    }

    func onItemDidStart() {
        let item = currentItem
        sessionSeenItemIDs.insert(item.id)
        Task { [stateStore] in await stateStore.markSeen(itemID: item.id) }
    }

    func markCurrentItemFailed() {
        isCurrentItemFailed = true
        playback.pause()
    }

    /// Called by the View on Retry. Does **not** clear `isCurrentItemFailed`
    /// — if it did the footer would briefly come back, then disappear again
    /// the moment the retry refails.
    func retryCurrentItem() {
        readyItemID = nil
        playback.reset()
    }

    // MARK: - Convenience accessors

    var currentUser: Story { users[currentUserIndex] }
    var currentItem: StoryItem { currentUser.items[currentItemIndex] }

    // MARK: - Navigation

    func nextItem() {
        if currentItemIndex + 1 < currentUser.items.count {
            currentItemIndex += 1
            restartForNewItem()
        } else if currentUserIndex + 1 < users.count {
            currentUserIndex += 1
            currentItemIndex = 0
            restartForNewUser()
        } else {
            advanceBeyondLoadedOrDismiss()
        }
    }

    func previousItem() {
        if currentItemIndex > 0 {
            currentItemIndex -= 1
            restartForNewItem()
        } else if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = max(0, users[currentUserIndex].items.count - 1)
            restartForNewUser()
        } else {
            playback.reset()
        }
    }

    func nextUser() {
        guard currentUserIndex + 1 < users.count else {
            advanceBeyondLoadedOrDismiss()
            return
        }
        currentUserIndex += 1
        currentItemIndex = 0
        restartForNewUser()
    }

    func previousUser() {
        if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = 0
            restartForNewUser()
        } else {
            currentItemIndex = 0
            playback.reset()
        }
    }

    func dismiss() {
        playback.stop()
        shouldDismiss = true
    }

    /// `isLoadingMoreUsers` is set synchronously before the await so a
    /// second tap-forward (or a re-entrant `onItemEnd`) cannot stack a
    /// second load attempt.
    private func advanceBeyondLoadedOrDismiss() {
        guard let loadMoreUsers else {
            dismiss()
            return
        }
        guard !isLoadingMoreUsers else { return }
        isLoadingMoreUsers = true
        playback.stop()
        Task { [weak self] in
            guard let self else { return }
            let appended = await loadMoreUsers()
            self.isLoadingMoreUsers = false
            guard !appended.isEmpty else {
                self.dismiss()
                return
            }
            let firstNewIndex = self.users.count
            self.users.append(contentsOf: appended)
            self.currentUserIndex = firstNewIndex
            self.currentItemIndex = 0
            self.restartForNewUser()
        }
    }

    /// Called from `.onDisappear` so the session's seen/like writes reach
    /// disk before the viewer is torn down — the 500 ms debounce window
    /// otherwise lets a fast dismiss outrun the next scheduled flush.
    func flushPendingPersistence() async {
        await stateStore.flushNow()
    }

    // Playback is stopped (not restarted): the new item's timer only starts
    // when its image finishes rendering via `markItemReady`. Otherwise the
    // bar shows residual fill from the previous item while the next image
    // fetches.
    private func restartForNewItem() {
        readyItemID = nil
        isCurrentItemFailed = false
        playback.stop()
        playback.reset()
        prefetchNext()
    }

    private func restartForNewUser() {
        likedItemIDsForCurrentUser.removeAll(keepingCapacity: true)
        readyItemID = nil
        isCurrentItemFailed = false
        playback.stop()
        playback.reset()
        prefetchNext()
        Task { await reloadLikedSetForCurrentUser() }
    }

    private func reloadLikedSetForCurrentUser() async {
        let user = currentUser
        var liked: Set<String> = []
        for item in user.items where await stateStore.isLiked(item.id) {
            liked.insert(item.id)
        }
        guard user.id == currentUser.id else { return }
        likedItemIDsForCurrentUser = liked
    }

    // MARK: - Like

    func toggleLike() {
        let id = currentItem.id
        if likedItemIDsForCurrentUser.contains(id) {
            likedItemIDsForCurrentUser.remove(id)
        } else {
            likedItemIDsForCurrentUser.insert(id)
        }
        Task { [stateStore] in
            _ = await stateStore.toggleLike(itemID: id)
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

    /// Upward translation is rubber-banded to 30% of input (matches design.md).
    func updateDrag(translationY: CGFloat, containerHeight: CGFloat) {
        if translationY != 0, !playback.isPaused, dragOffset == 0 {
            playback.pause()
        }
        let effective: CGFloat = translationY < 0 ? translationY * 0.3 : translationY
        dragOffset = effective
        let h = max(containerHeight, 1)
        dragProgress = min(1.0, max(0.0, Double(effective / h)))
    }

    /// On commit we reset `dragOffset`/`dragProgress` to zero *before*
    /// flipping `shouldDismiss`: the iOS 18 zoom-out reads the View's
    /// current frame as the dismiss start, and a non-zero residual offset
    /// would make the image continue sliding downwards *during* the zoom.
    func endDrag(translationY: CGFloat, velocityY: CGFloat, containerHeight: CGFloat) {
        if shouldCommitDismiss(
            translationY: translationY,
            velocityY: velocityY,
            containerHeight: containerHeight,
        ) {
            dragOffset = 0
            dragProgress = 0
            dismiss()
        } else {
            dragOffset = 0
            dragProgress = 0
            playback.resume()
        }
    }

    /// Commit when translation exceeds 30% of container height OR downward
    /// velocity exceeds 800pt/s (design.md).
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
        // Two items of headroom — one isn't enough when the user power-skims
        // (one fast tap-forward every ~150 ms outruns a single in-flight
        // request and exposes the placeholder during the swap).
        let lookahead = 2
        for offset in 1...lookahead {
            let idx = currentItemIndex + offset
            if idx < currentUser.items.count {
                urls.append(currentUser.items[idx].imageURL)
            }
        }
        if currentUserIndex + 1 < users.count {
            let nextUserItems = users[currentUserIndex + 1].items
            for item in nextUserItems.prefix(lookahead) {
                urls.append(item.imageURL)
            }
        }
        prefetcher.prefetch(urls)
    }
}
