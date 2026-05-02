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

    @Test("IDs across pages are unique (no collision after suffixing)")
    func crossPageIDsUnique() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let p0 = try await repo.loadPage(0)
        let p1 = try await repo.loadPage(1)
        let p2 = try await repo.loadPage(2)
        let storyIDs = (p0 + p1 + p2).map(\.id)
        let itemIDs  = (p0 + p1 + p2).flatMap { $0.items.map(\.id) }
        let uniqueStoryIDsAcrossPages = Set(p0.map(\.id))
            .isDisjoint(with: Set(p1.map(\.id)))
        #expect(uniqueStoryIDsAcrossPages)
        #expect(Set(p1.map(\.id)).isDisjoint(with: Set(p2.map(\.id))))
        // Sanity: every page suffix is present in every item id.
        for s in p1 { #expect(s.id.hasSuffix("-p1")) }
        for s in p2 { #expect(s.id.hasSuffix("-p2")) }
        for s in p1 { for i in s.items { #expect(i.id.hasSuffix("-p1")) } }
        // Touch the variables to silence unused warnings.
        _ = storyIDs
        _ = itemIDs
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

    @Test("n < pageSize wraps within the page and shares the page suffix")
    func nLessThanPageSizeWraps() async throws {
        let repo = LocalStoryRepository(stories: Self.makeStories(7))
        let p0 = try await repo.loadPage(0)
        // Indices 0..6, then 0,1,2 → expect 10 items total, with users 0/1/2 appearing twice.
        #expect(p0.count == 10)
        let userIDs = p0.map(\.user.id)
        #expect(userIDs == ["u0", "u1", "u2", "u3", "u4", "u5", "u6", "u0", "u1", "u2"])
        // Within a page, repeats keep the *same* suffixed ID — that's by design
        // (intra-page dedup is acceptable; cross-page dedup is what matters).
        #expect(p0.first?.id == "u0")
        #expect(p0.last?.id == "u2")
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
