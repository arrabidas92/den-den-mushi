import Foundation

/// Loads `stories.json` once and serves paginated views over the cached
/// `baseStories`. Pagination recycles the list (mod `n`) and rewrites IDs
/// with `-g{n}` suffixes so each cell has a unique ID even when the JSON
/// has fewer users than the page size.
actor LocalStoryRepository: StoryRepository {

    private let baseStories: [Story]
    private let pageSize: Int

    init(stories: [Story], pageSize: Int = 10) {
        self.baseStories = stories
        self.pageSize = pageSize
    }

    static func bundled(
        bundle: Bundle = .main,
        resource: String = "stories",
        pageSize: Int = 10,
    ) throws -> LocalStoryRepository {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw StoryError.bundleResourceMissing(name: "\(resource).json")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoryError.persistenceUnavailable(underlying: error)
        }
        let stories: [Story]
        do {
            stories = try JSONDecoder().decode(Envelope.self, from: data).users
        } catch {
            throw StoryError.decodingFailed(underlying: error)
        }
        return LocalStoryRepository(stories: stories, pageSize: pageSize)
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
