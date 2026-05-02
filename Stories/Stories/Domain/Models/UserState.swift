import Foundation

/// Per-user persistent state. Keyed by `StoryItem.id` (already includes
/// the page suffix when persisted from a recycled page).
nonisolated struct UserState: Sendable, Codable, Equatable {
    var seenItemIDs: Set<String>
    var likedItemIDs: Set<String>

    static let empty = UserState(seenItemIDs: [], likedItemIDs: [])

    init(seenItemIDs: Set<String> = [], likedItemIDs: Set<String> = []) {
        self.seenItemIDs = seenItemIDs
        self.likedItemIDs = likedItemIDs
    }
}
