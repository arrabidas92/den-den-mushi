import Foundation
@testable import Stories

/// Test-only fake. Mirrors `EphemeralUserStateStore` semantically but exposes
/// inspection hooks (`flushCallCount`, the underlying state) so tests can
/// assert collaborator behaviour without poking through production APIs.
actor InMemoryUserStateStore: UserStateRepository {

    private(set) var state: UserState
    private(set) var flushCallCount = 0
    private(set) var markSeenCallCount = 0
    private(set) var toggleLikeCallCount = 0

    init(initial: UserState = .empty) {
        self.state = initial
    }

    func markSeen(itemID: String) async {
        markSeenCallCount += 1
        state.seenItemIDs.insert(itemID)
    }

    func toggleLike(itemID: String) async -> Bool {
        toggleLikeCallCount += 1
        let now = !state.likedItemIDs.contains(itemID)
        if now {
            state.likedItemIDs.insert(itemID)
        } else {
            state.likedItemIDs.remove(itemID)
        }
        return now
    }

    func isSeen(_ id: String) async -> Bool {
        state.seenItemIDs.contains(id)
    }

    func isLiked(_ id: String) async -> Bool {
        state.likedItemIDs.contains(id)
    }

    func flushNow() async {
        flushCallCount += 1
    }
}
