import Foundation

/// Source of truth for the paginated story list. Implementations are
/// expected to return deterministic, stable IDs across calls so that
/// the persisted seen/like sets remain meaningful between sessions.
protocol StoryRepository: Sendable {
    func loadPage(_ pageIndex: Int) async throws -> [Story]
}
