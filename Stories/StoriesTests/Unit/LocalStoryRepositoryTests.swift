import Foundation
import Testing
@testable import Stories

@Suite("LocalStoryRepository")
struct LocalStoryRepositoryTests {

    // MARK: - Helpers

    private static func makeStories(_ count: Int) -> [Story] {
        (0..<count).map { i in
            let user = User(
                id: "u\(i)",
                stableID: "u\(i)",
                username: "user\(i)",
                avatarURL: URL(string: "https://x/avatar/\(i)")!
            )
            let item = StoryItem(
                id: "u\(i)-1",
                imageURL: URL(string: "https://x/story/\(i)")!,
                createdAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
            return Story(id: user.id, user: user, items: [item])
        }
    }

    // MARK: - Bundle JSON

    @Test("loads the bundled stories.json without throwing")
    func loadsBundleJSON() async throws {
        let repo = try LocalStoryRepository(bundle: .main)
        let page = try await repo.loadPage(0)
        #expect(page.count == 10)
    }

    @Test("missing bundle resource throws bundleResourceMissing")
    func missingResourceThrows() async {
        let repo = try? LocalStoryRepository(bundle: .main, resource: "does-not-exist")
        #expect(repo == nil)
    }

    // MARK: - Pagination formula

    @Test("loadPage(0) returns 10 items when n >= 10")
    func pageZeroReturnsTen() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(15))
        let page = try await repo.loadPage(0)
        #expect(page.count == 10)
    }

    @Test("every story and item ID is unique across all pages — even with wrap")
    func cellIDsAreGloballyUnique() async throws {
        // 7 base users, pageSize 10 → page 0 wraps the last 3 indices, so
        // without per-cell suffixing the same base user would collide twice
        // *within* page 0. The global-index suffix prevents this everywhere.
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let p0 = try await repo.loadPage(0)
        let p1 = try await repo.loadPage(1)
        let p2 = try await repo.loadPage(2)
        let allStoryIDs = (p0 + p1 + p2).map(\.id)
        let allItemIDs = (p0 + p1 + p2).flatMap { $0.items.map(\.id) }
        #expect(Set(allStoryIDs).count == allStoryIDs.count)
        #expect(Set(allItemIDs).count == allItemIDs.count)
        // Sanity: every cell carries the global-index suffix.
        for (page, expectedRange) in [(p0, 0..<10), (p1, 10..<20), (p2, 20..<30)] {
            for (i, story) in page.enumerated() {
                let expected = "-g\(expectedRange.lowerBound + i)"
                #expect(story.id.hasSuffix(expected))
                for item in story.items { #expect(item.id.hasSuffix(expected)) }
            }
        }
    }

    @Test("output is deterministic across invocations")
    func deterministic() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let a = try await repo.loadPage(2)
        let b = try await repo.loadPage(2)
        #expect(a == b)
    }

    @Test("n == 0 returns an empty page (no crash, no loop)")
    func emptyBaseReturnsEmpty() async throws {
        let repo = LocalStoryRepository(stories: [])
        let page = try await repo.loadPage(0)
        #expect(page.isEmpty)
    }

    @Test("n < pageSize wraps the user list but every cell gets a unique ID")
    func nLessThanPageSizeWraps() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let p0 = try await repo.loadPage(0)
        // Indices 0..6, then 0,1,2 → expect 10 items total, with users 0/1/2
        // appearing twice — but each repeat must carry a distinct global-index
        // suffix so SwiftUI's ForEach can key them safely.
        #expect(p0.count == 10)
        let userIDs = p0.map(\.user.id)
        #expect(userIDs == ["u0", "u1", "u2", "u3", "u4", "u5", "u6", "u0", "u1", "u2"])
        let storyIDs = p0.map(\.id)
        #expect(Set(storyIDs).count == storyIDs.count)
        #expect(p0.first?.id == "u0-g0")
        #expect(p0[7].id == "u0-g7")
        #expect(p0.last?.id == "u2-g9")
    }

    @Test("negative pageIndex throws pageOutOfRange")
    func negativePageThrows() async {
        let repo = LocalStoryRepository(stories: Self.makeStories(5))
        await #expect(throws: StoryError.self) {
            _ = try await repo.loadPage(-1)
        }
    }

    @Test("image URLs are stable across page suffixes (CLAUDE.md hard rule)")
    func urlsAreStableAcrossPages() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let p0 = try await repo.loadPage(0)
        let p1 = try await repo.loadPage(1)
        // Same user at index 3 in both pages must have the same image URL.
        let p0u3 = p0.first { $0.user.id == "u3" }
        let p1u3 = p1.first { $0.user.id == "u3" }
        #expect(p0u3?.items.first?.imageURL == p1u3?.items.first?.imageURL)
        #expect(p0u3?.id != p1u3?.id) // but story ids differ
    }
}
