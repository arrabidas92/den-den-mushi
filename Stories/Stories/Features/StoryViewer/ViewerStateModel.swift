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

    // MARK: - Transient gesture state

    private(set) var isImmersive = false
    private(set) var dragOffset: CGFloat = 0
    private(set) var dragProgress: Double = 0

    // MARK: - Collaborators

    let playback: PlaybackController
    let users: [Story]

    private let stateStore: any UserStateRepository
    private let clock: any Clock<Duration>
    private let prefetcher: ImagePrefetchHandle?

    // MARK: - Init

    init(
        users: [Story],
        startUserIndex: Int,
        startItemIndex: Int = 0,
        stateStore: any UserStateRepository,
        clock: any Clock<Duration> = ContinuousClock(),
        playback: PlaybackController? = nil,
        prefetcher: ImagePrefetchHandle? = nil,
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

        self.playback.onItemEnd = { [weak self] in self?.nextItem() }
    }

    // MARK: - Lifecycle

    /// Called by the View on appear. Resets playback for the start item,
    /// preloads the like-set for the current user, marks the current item
    /// as seen, and prefetches the next image.
    func onAppear() async {
        await reloadLikedSetForCurrentUser()
        playback.start()
        onItemDidStart()
        prefetchNext()
    }

    /// Marks the current item as seen the moment it becomes current.
    /// Called from `onAppear` and from every navigation transition.
    func onItemDidStart() {
        let item = currentItem
        sessionSeenItemIDs.insert(item.id)
        Task { [stateStore] in await stateStore.markSeen(itemID: item.id) }
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
            dismiss()
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
            // Already at the very first item — just rewind playback.
            playback.start()
            onItemDidStart()
        }
    }

    /// Horizontal swipe to the next user.
    func nextUser() {
        guard currentUserIndex + 1 < users.count else {
            dismiss()
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
            currentItemIndex = 0
            playback.start()
            onItemDidStart()
        }
    }

    func dismiss() {
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

    /// Same-user item change. The like-set for this user is already
    /// in memory, so `isLiked` resolves synchronously — no actor hop, no
    /// stale-then-correct flicker on the chrome heart.
    private func restartForNewItem() {
        playback.start()
        onItemDidStart()
        prefetchNext()
    }

    /// User change (cross-user navigation or swipe). Rebuilds the in-memory
    /// like-set for the new user before the chrome reads `isLiked`.
    /// Until the reload completes, `isLiked` resolves against the *previous*
    /// user's set — which is empty for the new user's items, so the heart
    /// reads as not-liked rather than incorrectly inheriting the previous
    /// user's state.
    private func restartForNewUser() {
        likedItemIDsForCurrentUser.removeAll(keepingCapacity: true)
        playback.start()
        onItemDidStart()
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
