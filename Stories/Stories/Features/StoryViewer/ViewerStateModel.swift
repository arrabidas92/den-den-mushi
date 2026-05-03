import Foundation
import CoreGraphics
import Observation

/// Owns the viewer's navigation, per-item like state, seen marking, and
/// transient gesture state (immersive, drag, heart pop). Drives a
/// `PlaybackController` and reacts to its `onItemEnd` to advance.
///
/// - **Optimistic state flips first, persistence follows.** `isLiked` is
///   updated synchronously before the `await` on the store completes, so
///   the UI never feels laggy on a tap. The store is the source of truth
///   on cold-start, not during a session.
/// - **Seen marking is immediate.** Each item is marked seen the moment
///   it becomes the current item — opening a story marks its first item
///   seen, advancing marks the next, etc.
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

    /// In-memory like state for *every item of the current user*, preloaded
    /// when the user becomes active. `isLiked` reads from this set
    /// synchronously, so a tap-forward to the next item updates the heart
    /// in the same frame the page changes — without the previous one-frame
    /// flicker where the chrome rendered with the stale value, then flipped
    /// to the correct value after the persistence actor returned.
    private var likedItemIDsForCurrentUser: Set<String> = []

    /// Synchronous like-state for the current item. Reads from
    /// `likedItemIDsForCurrentUser`, populated once per user.
    var isLiked: Bool { likedItemIDsForCurrentUser.contains(currentItem.id) }

    /// Items marked seen during this viewer session. Populated synchronously
    /// in `onItemDidStart`, before the persistence hop completes — so the
    /// list-side `refreshFullySeen` can reflect the new state instantly on
    /// dismiss without racing the debounced disk write.
    private(set) var sessionSeenItemIDs: Set<String> = []

    /// Item ID for which `markCurrentItemReady()` has already fired. Lets
    /// the View notify "image rendered" without us re-starting playback or
    /// re-marking seen on a re-entrant render (NukeUI completion can fire
    /// more than once per page lifetime — cache hit + later refresh).
    /// Reset on every navigation transition.
    private var readyItemID: String?

    /// True when the current item's image failed to load. The View hides
    /// the like footer in that case — Instagram's pattern: an item the
    /// reader has not actually seen cannot be acted on. Reset on every
    /// navigation transition (`restartForNewItem` / `restartForNewUser`)
    /// and on `retryLoad` via `clearCurrentItemFailure`.
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
    /// Optional async hook the viewer calls when navigation reaches the end
    /// of the currently loaded users. Returns the newly appended users (or
    /// an empty array if there are no more). Lets the viewer keep playing
    /// across tray-pagination boundaries without coupling to the list VM.
    private let loadMoreUsers: (@MainActor () async -> [Story])?
    /// True while `attemptLoadMoreUsers` is in flight. Prevents stacking
    /// concurrent load attempts when the user power-skims the right zone
    /// at the very end of the loaded users.
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

    /// Called by the View on appear. Preloads the like-set for the current
    /// user and prefetches the next image, but does **not** start playback
    /// or mark the current item seen — both wait for `markCurrentItemReady()`,
    /// which the View calls when the image actually renders. Offline / failed
    /// loads therefore never tick the timer and never flip the seen ring.
    func onAppear() async {
        await reloadLikedSetForCurrentUser()
        prefetchNext()
    }

    /// Called by the View when *any* page's image has finished rendering.
    /// The model arms playback only if the rendered item is the current
    /// one — adjacent pages signalling completion for their preview frame
    /// must not start the active item's timer.
    ///
    /// Why not gate this in the View via an `isActive` capture: NukeUI's
    /// `LazyImageView` retains the `onCompletion` closure from its first
    /// `onAppear`, and SwiftUI doesn't propagate updated closures to it
    /// across body re-evaluations. A page that was rendered as passive on
    /// first mount keeps the `isActive = false` capture forever, so its
    /// `markCurrentItemReady` calls would silently no-op even after the
    /// reader swipes to it. Routing the decision through the model with
    /// the item ID makes it work regardless of capture state.
    ///
    /// Idempotent per item — a second call for the same item is a no-op,
    /// so a re-entrant NukeUI completion (cache hit + later refresh) does
    /// not restart the 5s timer mid-watch.
    func markItemReady(itemID: String) {
        guard itemID == currentItem.id else { return }
        guard readyItemID != itemID else { return }
        readyItemID = itemID
        // A successful render also clears any prior failure flag — Retry
        // path leaves `isCurrentItemFailed` true on purpose so the footer
        // doesn't flash visible during the refetch; success here is what
        // brings it back.
        isCurrentItemFailed = false
        playback.start()
        onItemDidStart()
    }

    /// Backwards-compatible shim for tests that still use the old API.
    /// Delegates to `markItemReady(itemID:)` with the current item.
    func markCurrentItemReady() {
        markItemReady(itemID: currentItem.id)
    }

    /// Marks the current item as seen the moment its image is ready.
    /// Called from `markCurrentItemReady`. Kept as a separate seam so the
    /// in-session set is updated synchronously before the actor hop.
    func onItemDidStart() {
        let item = currentItem
        sessionSeenItemIDs.insert(item.id)
        Task { [stateStore] in await stateStore.markSeen(itemID: item.id) }
    }

    /// Called by the View when the current item's image failed to load.
    /// Hides the like footer (the reader hasn't actually seen the item) and
    /// pauses playback. Idempotent.
    func markCurrentItemFailed() {
        isCurrentItemFailed = true
        playback.pause()
    }

    /// Called by the View on Retry, before attempting to refetch the image.
    /// Resets the per-item ready latch and playback progress so a successful
    /// retry re-arms the 5s timer from 0.
    ///
    /// Crucially does **not** clear `isCurrentItemFailed` — if we did, the
    /// footer would briefly come back, then disappear again the moment the
    /// retry refails. The footer stays hidden until `markCurrentItemReady`
    /// confirms a successful render (the only honest "we have pixels"
    /// signal).
    func retryCurrentItem() {
        readyItemID = nil
        playback.reset()
    }

    // MARK: - Convenience accessors

    var currentUser: Story { users[currentUserIndex] }
    var currentItem: StoryItem { currentUser.items[currentItemIndex] }

    // MARK: - Navigation

    /// Tap-forward path. The next item becomes current; `onItemDidStart`
    /// marks it seen immediately.
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

    /// Tap-back path.
    func previousItem() {
        if currentItemIndex > 0 {
            currentItemIndex -= 1
            restartForNewItem()
        } else if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = max(0, users[currentUserIndex].items.count - 1)
            restartForNewUser()
        } else {
            // Already at the very first item — rewind the bar without
            // re-arming the seen marker. If the image had loaded, the
            // tick task is still running; resetting progress is enough.
            // If it hadn't (offline / failure), there is nothing to start.
            playback.reset()
        }
    }

    /// Horizontal swipe to the next user.
    func nextUser() {
        guard currentUserIndex + 1 < users.count else {
            advanceBeyondLoadedOrDismiss()
            return
        }
        currentUserIndex += 1
        currentItemIndex = 0
        restartForNewUser()
    }

    /// Horizontal swipe to the previous user. Falls back to a no-op
    /// rewind on the first user (matches Instagram's edge behaviour).
    func previousUser() {
        if currentUserIndex > 0 {
            currentUserIndex -= 1
            currentItemIndex = 0
            restartForNewUser()
        } else {
            // Boundary case mirrors `previousItem` at the very first item:
            // rewind the bar; do not re-mark seen and do not re-arm the
            // ready latch (the current image is already on screen).
            currentItemIndex = 0
            playback.reset()
        }
    }

    func dismiss() {
        playback.stop()
        shouldDismiss = true
    }

    /// End-of-loaded-list path. If a `loadMoreUsers` hook was provided,
    /// pause playback and try to fetch the next page; on success we append
    /// the new users and advance to the first of them. Without a hook, or
    /// when the hook returns no users, we dismiss — Instagram parity for
    /// the very last story.
    ///
    /// `isLoadingMoreUsers` is set synchronously before the await so a
    /// second tap-forward (or a re-entrant `onItemEnd` if the playback
    /// reset is racy) cannot stack a second load attempt.
    private func advanceBeyondLoadedOrDismiss() {
        guard let loadMoreUsers else {
            dismiss()
            return
        }
        guard !isLoadingMoreUsers else { return }
        isLoadingMoreUsers = true
        // Stop the playback while we wait — the timer is otherwise still
        // ticking on a fully-progressed bar and `onItemEnd` would fire
        // again as soon as the loop wakes.
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

    /// Forces the underlying state store to flush its debounce window
    /// to disk. Called from the View's `.onDisappear` so the session's
    /// seen/like writes reach disk before the viewer is torn down — a
    /// 500 ms debounce window otherwise lets a fast dismiss outrun the
    /// next scheduled flush.
    func flushPendingPersistence() async {
        await stateStore.flushNow()
    }

    /// Same-user item change. The like-set for this user is already
    /// in memory, so `isLiked` resolves synchronously — no actor hop, no
    /// stale-then-correct flicker on the chrome heart.
    ///
    /// Playback is **stopped**, not restarted: the new item's timer only
    /// starts when its image finishes rendering (`markCurrentItemReady`).
    /// Stopping cancels the previous item's tick loop and resets progress
    /// to 0 so the bar shows "this item hasn't started" rather than the
    /// previous item's residual fill while the next image fetches.
    private func restartForNewItem() {
        readyItemID = nil
        isCurrentItemFailed = false
        playback.stop()
        playback.reset()
        prefetchNext()
    }

    /// User change (cross-user navigation or swipe). Rebuilds the in-memory
    /// like-set for the new user before the chrome reads `isLiked`.
    /// Until the reload completes, `isLiked` resolves against the *previous*
    /// user's set — which is empty for the new user's items, so the heart
    /// reads as not-liked rather than incorrectly inheriting the previous
    /// user's state.
    ///
    /// Same playback gating as `restartForNewItem` — see its comment.
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

    /// Footer button tap. Optimistic flip, then persist. The flip is
    /// synchronous so the heart fills before the actor hop completes.
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
    ///
    /// On commit we *also* reset `dragOffset` and `dragProgress` to zero
    /// before flipping `shouldDismiss`: the iOS 18 zoom-out transition
    /// reads the View's current frame as the dismiss start, and a
    /// non-zero residual offset would make the image continue sliding
    /// downwards *during* the zoom — visually the image looks unpinned,
    /// drifting down while it should be collapsing onto the tray
    /// avatar. Resetting first hands a clean canvas to the matched
    /// transition.
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
        // Next *two* items in the current user — one item of headroom is
        // not enough when the user power-skims (one fast tap-forward
        // every ~150 ms on the right zone outruns a single in-flight
        // request, exposing the placeholder during the swap).
        let lookahead = 2
        for offset in 1...lookahead {
            let idx = currentItemIndex + offset
            if idx < currentUser.items.count {
                urls.append(currentUser.items[idx].imageURL)
            }
        }
        // First two items of the next user.
        if currentUserIndex + 1 < users.count {
            let nextUserItems = users[currentUserIndex + 1].items
            for item in nextUserItems.prefix(lookahead) {
                urls.append(item.imageURL)
            }
        }
        prefetcher.prefetch(urls)
    }
}
