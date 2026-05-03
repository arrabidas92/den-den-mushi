import Foundation

/// A user's story (the author plus the ordered list of frames).
nonisolated struct Story: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let user: User
    let items: [StoryItem]

    init(id: String, user: User, items: [StoryItem]) {
        self.id = id
        self.user = user
        self.items = items
    }

    // The on-disk shape flattens user fields next to `items` (one object per
    // story); decode user from the same container then read `items` separately.
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

    /// Returns a copy with IDs suffixed by `-g{globalIndex}` so paginated
    /// recycling of the bundled JSON keeps each cell's identity unique
    /// (image URLs unchanged — same user shows the same content per
    /// CLAUDE.md). The un-suffixed form is reserved for tests and previews.
    func withGlobalIndex(_ globalIndex: Int) -> Story {
        let suffix = "-g\(globalIndex)"
        let suffixedItems = items.map { item in
            StoryItem(id: item.id + suffix, imageURL: item.imageURL, createdAt: item.createdAt)
        }
        return Story(id: id + suffix, user: user, items: suffixedItems)
    }
}
