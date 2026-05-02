import Foundation

/// A user's story (the author plus the ordered list of frames).
/// `withPageSuffix(_:)` returns a copy with rewritten IDs for recycling
/// across paginated reloads — image URLs are kept identical so the same
/// user always shows the same content (CLAUDE.md hard rule).
nonisolated struct Story: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let user: User
    let items: [StoryItem]

    init(id: String, user: User, items: [StoryItem]) {
        self.id = id
        self.user = user
        self.items = items
    }

    // The on-disk shape flattens the user fields next to `items` (one object
    // per story). We decode the user out of the same container, then read
    // `items` from the additional key. `id` mirrors `user.id` at decode time.

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let user = try User(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = user.id
        self.user = user
        self.items = try c.decode([StoryItem].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        try user.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
    }

    /// Returns a copy of this story whose IDs are suffixed with `-p{n}`
    /// (story id and every item id). Used by `LocalStoryRepository` to
    /// recycle the bundled JSON across paginated reloads while preserving
    /// per-item identity within the persisted seen/like sets.
    func withPageSuffix(_ pageIndex: Int) -> Story {
        guard pageIndex > 0 else { return self }
        let suffix = "-p\(pageIndex)"
        let suffixedItems = items.map { item in
            StoryItem(id: item.id + suffix, imageURL: item.imageURL, createdAt: item.createdAt)
        }
        return Story(id: id + suffix, user: user, items: suffixedItems)
    }
}
