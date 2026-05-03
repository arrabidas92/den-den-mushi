import Foundation

/// Loads `stories.json` from the bundle once at init, then serves
/// paginated views over the cached `baseStories` array. Pagination
/// recycles the local list (mod `n`) and rewrites IDs with a `-g{n}`
/// suffix where `n` is the cell's global position in the paginated
/// sequence — so every cell has a unique ID even when the JSON has
/// fewer users than the page size (otherwise the same base story would
/// recur within a single page and collide on `Identifiable`).
actor LocalStoryRepository: StoryRepository {

    private let baseStories: [Story]
    private let pageSize: Int

    init(bundle: Bundle = .main, resource: String = "stories", pageSize: Int = 10) throws {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw StoryError.bundleResourceMissing(name: "\(resource).json")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoryError.persistenceUnavailable(underlying: error)
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            self.baseStories = envelope.users
        } catch {
            throw StoryError.decodingFailed(underlying: error)
        }
        self.pageSize = pageSize
    }

    /// Convenience init for tests and fakes that want to bypass JSON entirely.
    init(stories: [Story], pageSize: Int = 10) {
        self.baseStories = stories
        self.pageSize = pageSize
    }

    func loadPage(_ pageIndex: Int) async throws -> [Story] {
        guard pageIndex >= 0 else { throw StoryError.pageOutOfRange }
        let n = baseStories.count
        guard n > 0 else { return [] }
        return (0..<pageSize).map { i in
            let globalIndex = pageIndex * pageSize + i
            let base = baseStories[globalIndex % n]
            return base.withGlobalIndex(globalIndex)
        }
    }

    private struct Envelope: Decodable {
        let users: [Story]
    }
}
