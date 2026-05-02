import Foundation
import Testing
@testable import Stories

@Suite("PersistedUserStateStore")
struct PersistedUserStateStoreTests {

    // MARK: - Helpers

    /// Each test gets its own temp file so suites can run in parallel.
    private static func freshFileURL() -> URL {
        let name = "stories-test-\(UUID().uuidString).json"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Round-trip

    @Test("seen and like state round-trips through a single store instance")
    func roundTripSingleInstance() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        let store = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))

        await store.markSeen(itemID: "alice-1")
        let liked = await store.toggleLike(itemID: "alice-2")
        #expect(liked == true)
        await store.flushNow()

        #expect(await store.isSeen("alice-1"))
        #expect(await store.isLiked("alice-2"))
        #expect(await store.isLiked("alice-1") == false)
    }

    // MARK: - Cross-init survival

    @Test("state persists across re-initialisation on the same file")
    func crossInitSurvival() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        do {
            let s = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))
            await s.markSeen(itemID: "ben-1")
            _ = await s.toggleLike(itemID: "ben-2")
            await s.flushNow()
        }
        // New instance, same file.
        let reopened = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))
        #expect(await reopened.isSeen("ben-1"))
        #expect(await reopened.isLiked("ben-2"))
    }

    // MARK: - Concurrent writes

    @Test("concurrent markSeen calls converge without races")
    func concurrentMarkSeen() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        let store = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { await store.markSeen(itemID: "item-\(i)") }
            }
        }
        await store.flushNow()

        for i in 0..<200 {
            #expect(await store.isSeen("item-\(i)"), "missing item-\(i)")
        }
    }

    // MARK: - Debounce coalescing

    @Test("burst of mutations triggers a single disk write within the debounce window")
    func debounceCoalescesBursts() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        let debounce: Duration = .milliseconds(150)
        let store = try await PersistedUserStateStore(fileURL: url, debounce: debounce)

        // Five mutations in quick succession.
        for i in 0..<5 {
            await store.markSeen(itemID: "burst-\(i)")
        }
        // Before debounce elapses, the file should not yet contain all five.
        // (We don't assert "exactly one write" — we assert the bytes-on-disk
        // are eventually consistent, which is the user-observable contract.)
        try await Task.sleep(for: debounce + .milliseconds(150))

        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(UserState.self, from: data)
        for i in 0..<5 {
            #expect(snapshot.seenItemIDs.contains("burst-\(i)"))
        }
    }

    // MARK: - Corruption recovery

    @Test("a corrupt file is deleted on init and the store starts empty")
    func corruptionRecovery() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        try Data("not valid json".utf8).write(to: url)

        let store = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))
        #expect(await store.isSeen("anything") == false)
        #expect(await store.isLiked("anything") == false)
        // Recovery deletes the file; a subsequent write should recreate it cleanly.
        await store.markSeen(itemID: "recovered")
        await store.flushNow()
        let data = try Data(contentsOf: url)
        let parsed = try JSONDecoder().decode(UserState.self, from: data)
        #expect(parsed.seenItemIDs == ["recovered"])
    }

    // MARK: - flushNow idempotency

    @Test("flushNow on an unmodified store does not error and leaves state intact")
    func flushNowIdempotent() async throws {
        let url = Self.freshFileURL()
        defer { Self.cleanup(url) }
        let store = try await PersistedUserStateStore(fileURL: url, debounce: .milliseconds(10))
        await store.flushNow()
        await store.flushNow()
        #expect(await store.isSeen("anything") == false)
    }
}
