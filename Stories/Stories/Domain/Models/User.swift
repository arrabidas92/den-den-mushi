import Foundation

/// A story author. `stableID` is the value used by transitions and seeds —
/// `id` is reserved for collection-identity (paginated copies suffix it).
nonisolated struct User: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let stableID: String
    let username: String
    let avatarURL: URL
}
