import Foundation

/// Implementations must return deterministic, stable IDs across calls so
/// the persisted seen/like sets remain meaningful between sessions.
protocol StoryRepository: Sendable {
    func loadPage(_ pageIndex: Int) async throws -> [Story]
}
