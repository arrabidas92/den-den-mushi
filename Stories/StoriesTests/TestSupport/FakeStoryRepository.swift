import Foundation
@testable import Stories

/// Hand-written fake. Pre-programmed pages or deterministic stub stories,
/// optional injected error per page index for negative-path tests.
actor FakeStoryRepository: StoryRepository {

    enum Mode: Sendable {
        case pages([[Story]])
        case stub(count: Int, pageSize: Int)
    }

    private let mode: Mode
    private var errorByPage: [Int: StoryError] = [:]
    private(set) var loadCallCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func injectError(_ error: StoryError, forPage page: Int) {
        errorByPage[page] = error
    }

    func clearError(forPage page: Int) {
        errorByPage.removeValue(forKey: page)
    }

    func loadPage(_ pageIndex: Int) async throws -> [Story] {
        loadCallCount += 1
        if let err = errorByPage[pageIndex] { throw err }
        switch mode {
        case .pages(let pages):
            guard pages.indices.contains(pageIndex) else { throw StoryError.pageOutOfRange }
            return pages[pageIndex]
        case .stub(let count, let pageSize):
            guard pageIndex >= 0 else { throw StoryError.pageOutOfRange }
            return (0..<pageSize).map { i in
                let n = (pageIndex * pageSize + i) % max(count, 1)
                let user = User(
                    id: "u\(n)",
                    stableID: "u\(n)",
                    username: "user\(n)",
                    avatarURL: URL(string: "https://example.com/avatar/\(n).png")!
                )
                let item = StoryItem(
                    id: "u\(n)-1",
                    imageURL: URL(string: "https://example.com/story/\(n).png")!,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(n))
                )
                return Story(id: user.id, user: user, items: [item]).withPageSuffix(pageIndex)
            }
        }
    }
}
