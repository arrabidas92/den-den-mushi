import Foundation

/// A single frame inside a `Story`. Identity is stable across sessions but
/// is suffixed (`alice-1-p2`) when the story is recycled by pagination.
nonisolated struct StoryItem: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let imageURL: URL
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case imageURL
        case createdAtISO = "createdAtISO"
    }

    init(id: String, imageURL: URL, createdAt: Date) {
        self.id = id
        self.imageURL = imageURL
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.imageURL = try c.decode(URL.self, forKey: .imageURL)
        let iso = try c.decode(String.self, forKey: .createdAtISO)
        do {
            self.createdAt = try Date(iso, strategy: .iso8601)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAtISO,
                in: c,
                debugDescription: "expected ISO8601, got \(iso)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(imageURL, forKey: .imageURL)
        try c.encode(createdAt.formatted(.iso8601), forKey: .createdAtISO)
    }
}
