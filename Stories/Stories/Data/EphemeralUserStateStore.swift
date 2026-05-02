import Foundation

/// In-memory `UserStateRepository` used as the production fallback when
/// `PersistedUserStateStore` cannot initialise (filesystem unavailable
/// during composition). State survives only for the app lifetime.
actor EphemeralUserStateStore: UserStateRepository {

    private var state: UserState

    init(initial: UserState = .empty) {
        self.state = initial
    }

    func markSeen(itemID: String) async {
        state.seenItemIDs.insert(itemID)
    }

    func toggleLike(itemID: String) async -> Bool {
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
        // No persistence layer — in-memory store has nothing to drain.
    }
}
